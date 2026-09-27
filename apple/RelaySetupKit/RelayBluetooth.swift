// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
@preconcurrency import CoreBluetooth
import Foundation

private let relayService = CBUUID(string: "462F3A10-7A31-4AB3-9E7F-C36AF495ECF0")
private let relayRX = CBUUID(string: "462F3A11-7A31-4AB3-9E7F-C36AF495ECF0")
private let relayTX = CBUUID(string: "462F3A12-7A31-4AB3-9E7F-C36AF495ECF0")

public struct BluetoothRelay: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let signal: Int
}

@MainActor
public final class RelayBLEScanner: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published public private(set) var relays: [BluetoothRelay] = []
    @Published public private(set) var message = "Scan for a nearby tablet relay."
    @Published public private(set) var scanning = false
    private var central: CBCentralManager?
    private var deadline: Task<Void, Never>?

    public func start() {
        stop()
        relays = []
        scanning = true
        message = "Looking for nearby tablet relays…"
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { centralManagerDidUpdateState(central!) }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self else { return }
            self.stop()
            self.message = self.relays.isEmpty ? "No relay found. Check that it is advertising, then scan again." : "Choose your relay."
        }
    }

    public func stop() {
        deadline?.cancel()
        deadline = nil
        if central?.state == .poweredOn { central?.stopScan() }
        scanning = false
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard scanning else { return }
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [relayService])
        } else if central.state != .unknown && central.state != .resetting {
            message = bluetoothStateMessage(central.state)
            stop()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Tablet relay"
        let candidate = BluetoothRelay(id: peripheral.identifier, name: String(name.prefix(64)), signal: RSSI.intValue)
        if let index = relays.firstIndex(where: { $0.id == candidate.id }) { relays[index] = candidate }
        else if relays.count < 32 { relays.append(candidate) }
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

    init(identifier: UUID) {
        self.identifier = identifier
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { continuation in
            connectWaiter = continuation
            connectDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.fail(RelaySetupError.timedOut)
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
        if let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            attach(known)
        } else { central.scanForPeripherals(withServices: [relayService]) }
    }

    private func attach(_ device: CBPeripheral) {
        central.stopScan()
        peripheral = device
        device.delegate = self
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
        if failure == nil && self.peripheral == nil && peripheral.identifier == identifier { attach(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard failure == nil, peripheral.identifier == identifier else { return }
        peripheral.discoverServices([relayService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(RelaySetupError.network(error?.localizedDescription ?? "Bluetooth connection failed."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        fail(RelaySetupError.network(error?.localizedDescription ?? "The relay disconnected. Saved trust is retained."))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard failure == nil else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == relayService }) else {
            fail(RelaySetupError.network("The selected relay does not expose the input test service.")); return
        }
        peripheral.discoverCharacteristics([relayRX, relayTX], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard failure == nil else { return }
        rx = service.characteristics?.first { $0.uuid == relayRX }
        tx = service.characteristics?.first { $0.uuid == relayTX }
        guard error == nil, let rx, let tx, rx.properties.contains(.write), tx.properties.contains(.indicate) else {
            fail(RelaySetupError.network("The relay's Bluetooth service is incomplete.")); return
        }
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard failure == nil, characteristic.uuid == relayTX else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(RelaySetupError.network("Could not subscribe to the relay.")); return
        }
        let waiter = connectWaiter
        connectWaiter = nil
        connectDeadline?.cancel(); connectDeadline = nil
        waiter?.resume()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard failure == nil, characteristic.uuid == relayRX else { return }
        if let error { fail(RelaySetupError.network(error.localizedDescription)); return }
        let waiter = writeWaiter
        writeWaiter = nil
        writeDeadline?.cancel(); writeDeadline = nil
        waiter?.resume()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard failure == nil, characteristic.uuid == relayTX else { return }
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
