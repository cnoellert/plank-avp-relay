// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
@preconcurrency import CoreBluetooth
import Foundation
import OSLog

private let relayService = CBUUID(string: "462F3A10-7A31-4AB3-9E7F-C36AF495ECF0")
private let relayPSM = CBUUID(string: "462F3A17-7A31-4AB3-9E7F-C36AF495ECF0")

enum RelayBLEChannel { case relay, echo, setup }

extension RelayBLEConnection {
    convenience init(identifier: UUID, channel: RelayBLEChannel = .relay,
                     requireTabletSetup: Bool = false, onProgress: ((String) -> Void)? = nil) {
        self.init(makeAttempt: {
            RelayBLEAttempt(identifier: identifier, channel: channel,
                requireTabletSetup: requireTabletSetup, onProgress: onProgress)
        }, onProgress: onProgress)
    }
}

@MainActor
public final class RelayBLEScanner: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published public private(set) var relays: [BluetoothRelay] = []
    @Published public private(set) var message = "Scan for a nearby tablet relay."
    @Published public private(set) var scanning = false
    private var central: CBCentralManager?
    private var expiryTask: Task<Void, Never>?
    private var discovery = RelayDiscovery()

    public func start() {
        stop()
        scanning = true
        message = "Looking for nearby tablet relays…"
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { centralManagerDidUpdateState(central!) }
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.scanning else { return }
                self.discovery.expire(now: ProcessInfo.processInfo.systemUptime)
                self.publishDiscovery()
            }
        }
    }

    public func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        if central?.state == .poweredOn { central?.stopScan() }
        scanning = false
        discovery = RelayDiscovery()
        relays = []
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard scanning else { return }
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [relayService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if central.state != .unknown && central.state != .resetting {
            message = bluetoothStateMessage(central.state)
            stop()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        discovery.observe(id: peripheral.identifier,
            advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            signal: RSSI.intValue, connectable: connectable, now: ProcessInfo.processInfo.systemUptime)
        publishDiscovery()
    }

    private func publishDiscovery() {
        if relays != discovery.relays { relays = discovery.relays }
        message = relays.isEmpty ? "Looking for nearby tablet relays…" : "Choose an available relay."
    }
}

private func bluetoothStateMessage(_ state: CBManagerState) -> String {
    switch state {
    case .unauthorized: "Allow Bluetooth access for PLANK AVP Relay Setup in Settings."
    case .poweredOff: "Turn on Bluetooth in Settings, then try again."
    case .unsupported: "Bluetooth LE is unavailable on this device. Use a physical headset for this test."
    default: "Bluetooth is not ready. Try again shortly."
    }
}

/// One stream owns one central/peripheral and all continuations. Every callback
/// is delivered on the main queue; cancellation resumes all pending operations.
@MainActor
final class RelayBLEAttempt: NSObject, RelayBLEAttemptConnection,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let identifier: UUID
    private let channel: RelayBLEChannel
    private var diagnostic: Bool { channel == .echo }
    private let onProgress: ((String) -> Void)?
    private let logger = Logger(subsystem: "la.instinctual.PLANK.TabletSetup", category: "Bluetooth")
    private var phase = "waiting for Bluetooth"
    private var signal: Int?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var stream: RelayL2CAPStream?
    private var l2capChannel: CBL2CAPChannel?
    private var streamTask: Task<Void, Never>?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var failure: (any Error)?
    private var started = false
    private var connectDeadline: Task<Void, Never>?
    private var disconnectWaiter: CheckedContinuation<Void, Never>?
    private var disconnected = false

    func finishDisconnect() async {
        fail(CancellationError())
        guard peripheral != nil, !disconnected else { return }
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.completeDisconnect()
        }
        defer { timer.cancel() }
        await withCheckedContinuation { disconnectWaiter = $0 }
    }

    private func completeDisconnect() {
        disconnected = true
        let waiter = disconnectWaiter
        disconnectWaiter = nil
        waiter?.resume()
    }

    init(identifier: UUID, channel: RelayBLEChannel = .relay, requireTabletSetup: Bool = false,
         onProgress: ((String) -> Void)? = nil) {
        self.identifier = identifier
        self.channel = channel
        self.onProgress = onProgress
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        progress("waiting for Bluetooth", "Waiting for Bluetooth to become ready…")
        try await withCheckedThrowingContinuation { continuation in
            connectWaiter = continuation
            connectDeadline = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard let self else { return }
                let strength = self.signal.map { " Last signal: \($0) dBm." } ?? ""
                self.fail(RelaySetupError.network("Timed out while \(self.phase).\(strength) Tap Pair to retry."))
            }
            beginConnect()
        }
    }

    private func beginConnect() {
        guard connectWaiter != nil, failure == nil else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                fail(RelaySetupError.network(bluetoothStateMessage(central.state)))
            }
            return
        }
        guard !started else { return }
        started = true
        // Discover with the same manager that will own the connection. This
        // also confirms the selected relay is advertising now, instead of
        // waiting on a peripheral returned from the system's saved cache.
        progress("finding the selected relay", "Looking for the selected relay nearby…")
        central.scanForPeripherals(withServices: [relayService])
    }

    private func progress(_ phase: String, _ message: String) {
        self.phase = phase
        logger.notice("Connection stage: \(phase, privacy: .public)")
        onProgress?(message)
    }

    private func attach(_ device: CBPeripheral) {
        central.stopScan()
        peripheral = device
        device.delegate = self
        let strength = signal.map { " Signal: \($0) dBm." } ?? ""
        progress("establishing the Bluetooth link", "Relay found. Connecting…\(strength)")
        central.connect(device)
    }

    func send(_ data: Data) async throws {
        if let failure { throw failure }
        guard let stream else { throw RelaySetupError.invalidState }
        try await stream.send(data)
    }

    func receive() async throws -> Data {
        if let failure { throw failure }
        guard let stream else { throw RelaySetupError.invalidState }
        return try await stream.receive()
    }

    nonisolated func cancel() {
        Task { @MainActor in self.fail(CancellationError()) }
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        // Stage only: no device identifier, keys, records or tablet input.
        logger.notice("Connection ended during: \(self.phase, privacy: .public)")
        failure = error
        connectDeadline?.cancel(); connectDeadline = nil
        streamTask?.cancel(); streamTask = nil
        stream?.close(error); stream = nil; l2capChannel = nil
        if central.state == .poweredOn { central.stopScan() }
        let connecting = connectWaiter
        connectWaiter = nil
        connecting?.resume(throwing: error)
        if let peripheral, central.state == .poweredOn { central.cancelPeripheralConnection(peripheral) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if started && central.state != .poweredOn {
            fail(RelaySetupError.network(bluetoothStateMessage(central.state)))
        } else { beginConnect() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard failure == nil, connectWaiter != nil, self.peripheral == nil,
              peripheral.identifier == identifier else { return }
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber,
           !connectable.boolValue {
            fail(RelaySetupError.network("The selected relay is advertising but is not accepting connections."))
            return
        }
        signal = RSSI.intValue == 127 ? nil : RSSI.intValue
        attach(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard failure == nil, peripheral.identifier == identifier else { return }
        progress("opening the relay service", "Bluetooth connected. Opening the relay service…")
        peripheral.discoverServices([relayService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        completeDisconnect()
        fail(RelaySetupError.network(error?.localizedDescription ?? "Bluetooth connection failed."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        completeDisconnect()
        let reason = error?.localizedDescription ?? "The relay disconnected. Saved trust is retained."
        if connectWaiter != nil {
            fail(RelayBLEStartupDisconnect(reason: reason))
        } else {
            fail(RelaySetupError.network(reason))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard failure == nil else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == relayService }) else {
            fail(RelaySetupError.network("The selected relay does not expose the input test service.")); return
        }
        progress("reading the Bluetooth channel", "Relay service found. Opening Bluetooth L2CAP…")
        peripheral.discoverCharacteristics([relayPSM], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard failure == nil else { return }
        guard error == nil, let endpoint = service.characteristics?.first(where: { $0.uuid == relayPSM }),
              endpoint.properties.contains(.read) else {
            fail(RelaySetupError.network("Update the Linux relay package to use Bluetooth L2CAP with this app."))
            return
        }
        peripheral.readValue(for: endpoint)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard failure == nil, characteristic.uuid == relayPSM else { return }
        guard error == nil, let data = characteristic.value, data.count == 3, data[0] == 1 else {
            fail(RelaySetupError.protocolError); return
        }
        let psm = UInt16(data[1]) | UInt16(data[2]) << 8
        guard (0x80...0xff).contains(psm) else { fail(RelaySetupError.protocolError); return }
        progress("opening Bluetooth L2CAP", "Opening the relay's Bluetooth stream…")
        peripheral.openL2CAPChannel(psm)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard failure == nil else { return }
        guard error == nil, let channel else {
            fail(RelaySetupError.network(error?.localizedDescription ?? "Could not open Bluetooth L2CAP."))
            return
        }
        guard stream == nil else { fail(RelaySetupError.protocolError); return }
        l2capChannel = channel
        let stream = RelayL2CAPStream(input: channel.inputStream, output: channel.outputStream) { [weak self] error in
            self?.fail(error)
        }
        self.stream = stream
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await stream.open()
                try await stream.send(Data("PLTRLEC1".utf8) + [self.channel == .setup ? 1 : self.diagnostic ? 2 : 0])
                guard self.failure == nil else { return }
                let waiter = self.connectWaiter
                self.connectWaiter = nil
                self.connectDeadline?.cancel(); self.connectDeadline = nil
                self.progress(self.diagnostic ? "starting the byte test" : "starting authorization",
                              self.diagnostic ? "Bluetooth L2CAP connected. Starting the byte test…"
                                              : "Bluetooth L2CAP connected. Starting authorization…")
                waiter?.resume()
            } catch { self.fail(error) }
        }
    }
}
