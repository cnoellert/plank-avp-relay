// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
@preconcurrency import CoreBluetooth
import Foundation
import OSLog

private let relayService = CBUUID(string: "462F3A10-7A31-4AB3-9E7F-C36AF495ECF0")
private let relayRX = CBUUID(string: "462F3A11-7A31-4AB3-9E7F-C36AF495ECF0")
private let relayTX = CBUUID(string: "462F3A12-7A31-4AB3-9E7F-C36AF495ECF0")
private let echoRX = CBUUID(string: "462F3A13-7A31-4AB3-9E7F-C36AF495ECF0")
private let echoTX = CBUUID(string: "462F3A14-7A31-4AB3-9E7F-C36AF495ECF0")

private let setupRX = CBUUID(string: "462F3A15-7A31-4AB3-9E7F-C36AF495ECF0")
private let setupTX = CBUUID(string: "462F3A16-7A31-4AB3-9E7F-C36AF495ECF0")

enum RelayBLEChannel { case relay, echo, setup }

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
    case .unauthorized: "Allow Bluetooth access for PLANK Tablet Setup in Settings."
    case .poweredOff: "Turn on Bluetooth in Settings, then try again."
    case .unsupported: "Bluetooth LE is unavailable on this device. Use a physical headset for this test."
    default: "Bluetooth is not ready. Try again shortly."
    }
}

/// One stream owns one central/peripheral and all continuations. Every callback
/// is delivered on the main queue; cancellation resumes all pending operations.
@MainActor
final class RelayBLEConnection: NSObject, RelayByteConnection,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let identifier: UUID
    private let channel: RelayBLEChannel
    private let requireTabletSetup: Bool
    private var diagnostic: Bool { channel == .echo }
    private var rxUUID: CBUUID { channel == .setup ? setupRX : diagnostic ? echoRX : relayRX }
    private var txUUID: CBUUID { channel == .setup ? setupTX : diagnostic ? echoTX : relayTX }
    private let onProgress: ((String) -> Void)?
    private let logger = Logger(subsystem: "la.instinctual.PLANK.TabletSetup", category: "Bluetooth")
    private var phase = "waiting for Bluetooth"
    private var signal: Int?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var readWaiter: CheckedContinuation<Data, Error>?
    private var input: [Data] = []
    private var inputBytes = 0
    private var failure: (any Error)?
    private var started = false
    private var connectDeadline: Task<Void, Never>?
    private var writeDeadline: Task<Void, Never>?
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
        self.requireTabletSetup = requireTabletSetup
        self.onProgress = onProgress
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        progress("waiting for Bluetooth", "Waiting for Bluetooth to become ready…")
        try await withCheckedThrowingContinuation { continuation in
            connectWaiter = continuation
            connectDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
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
        logger.info("Connection stage: \(phase, privacy: .public)")
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
        try Task.checkCancellation()
        if let failure { throw failure }
        guard let peripheral, let rx, tx?.isNotifying == true, writeWaiter == nil else {
            throw RelaySetupError.invalidState
        }
        let maximum = min(512, peripheral.maximumWriteValueLength(for: .withResponse))
        guard maximum > 0 else { throw RelaySetupError.protocolError }
        for offset in stride(from: 0, to: data.count, by: maximum) {
            try Task.checkCancellation()
            if let failure { throw failure }
            let fragment = data.subdata(in: offset..<min(offset + maximum, data.count))
            try await withCheckedThrowingContinuation { continuation in
                writeWaiter = continuation
                writeDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self?.fail(RelaySetupError.timedOut)
                }
                peripheral.writeValue(fragment, for: rx, type: .withResponse)
            }
        }
    }

    func receive() async throws -> Data {
        try Task.checkCancellation()
        if let failure { throw failure }
        if !input.isEmpty {
            let data = input.removeFirst()
            inputBytes -= data.count
            return data
        }
        guard readWaiter == nil else { throw RelaySetupError.invalidState }
        return try await withCheckedThrowingContinuation { readWaiter = $0 }
    }

    nonisolated func cancel() {
        Task { @MainActor in self.fail(CancellationError()) }
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        // Stage only: no device identifier, keys, records or tablet input.
        logger.info("Connection ended during: \(self.phase, privacy: .public)")
        failure = error
        connectDeadline?.cancel(); connectDeadline = nil
        writeDeadline?.cancel(); writeDeadline = nil
        if central.state == .poweredOn { central.stopScan() }
        let connecting = connectWaiter, writing = writeWaiter, reading = readWaiter
        connectWaiter = nil; writeWaiter = nil; readWaiter = nil
        input.removeAll(); inputBytes = 0
        connecting?.resume(throwing: error)
        writing?.resume(throwing: error)
        reading?.resume(throwing: error)
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
        fail(RelaySetupError.network(error?.localizedDescription ?? "Bluetooth connection failed."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        completeDisconnect()
        fail(RelaySetupError.network(error?.localizedDescription ?? "The relay disconnected. Saved trust is retained."))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard failure == nil else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == relayService }) else {
            fail(RelaySetupError.network("The selected relay does not expose the input test service.")); return
        }
        progress("opening the relay data channels", "Relay service found. Opening its data channels…")
        peripheral.discoverCharacteristics(requireTabletSetup ? [rxUUID, txUUID, setupRX, setupTX] : [rxUUID, txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if requireTabletSetup && !(service.characteristics?.contains(where: { $0.uuid == setupRX }) == true &&
                                    service.characteristics?.contains(where: { $0.uuid == setupTX }) == true) {
            fail(RelaySetupError.network("Update the Linux relay package to use tablet setup from this app."))
            return
        }
        guard failure == nil else { return }
        rx = service.characteristics?.first { $0.uuid == rxUUID }
        tx = service.characteristics?.first { $0.uuid == txUUID }
        guard error == nil, let rx, let tx, rx.properties.contains(.write), tx.properties.contains(.indicate) else {
            fail(RelaySetupError.network(channel == .setup
                ? "Update the Linux relay package to use tablet setup from this app." : diagnostic
                ? "This relay does not expose the Bluetooth test. Update the relay lab first."
                : "The relay's pairing service is unavailable. It may be running the transport-only test.")); return
        }
        progress("enabling relay replies", "Relay channels found. Enabling replies…")
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard failure == nil, characteristic.uuid == txUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(RelaySetupError.network("Could not subscribe to the relay.")); return
        }
        let waiter = connectWaiter
        connectWaiter = nil
        connectDeadline?.cancel(); connectDeadline = nil
        progress(diagnostic ? "starting the byte test" : "starting authorization",
                 diagnostic ? "Relay connected. Starting the byte test…" : "Relay connected. Starting authorization…")
        waiter?.resume()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard failure == nil, characteristic.uuid == rxUUID else { return }
        if let error { fail(RelaySetupError.network(error.localizedDescription)); return }
        let waiter = writeWaiter
        writeWaiter = nil
        writeDeadline?.cancel(); writeDeadline = nil
        waiter?.resume()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard failure == nil, characteristic.uuid == txUUID else { return }
        guard error == nil, let data = characteristic.value, !data.isEmpty, data.count <= 512 else {
            fail(RelaySetupError.protocolError); return
        }
        if let waiter = readWaiter {
            readWaiter = nil
            waiter.resume(returning: data)
        } else {
            guard inputBytes + data.count <= 16384 else { fail(RelaySetupError.protocolError); return }
            input.append(data)
            inputBytes += data.count
        }
    }
}
