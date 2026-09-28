// SPDX-License-Identifier: GPL-3.0-or-later
// Independent radio diagnostic: no RelaySetupKit, tablet, pairing or saved keys.
import AppKit
@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class EchoProbe: NSObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    private let serviceID = CBUUID(string: "462F3A10-7A31-4AB3-9E7F-C36AF495ECF0")
    private let rxID = CBUUID(string: "462F3A13-7A31-4AB3-9E7F-C36AF495ECF0")
    private let txID = CBUUID(string: "462F3A14-7A31-4AB3-9E7F-C36AF495ECF0")
    private let sizes = [64, 512, 1024]
    private let status: NSTextField
    private var central: CBCentralManager!
    private var device: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var deadline: Task<Void, Never>?
    private var finished = false
    private var scanning = false
    private var round = 0
    private var expected = Data()
    private var received = Data()
    private var written = 0
    private var pendingWrite = false

    init(status: NSTextField) {
        self.status = status
        super.init()
        stage("Waiting for Bluetooth permission and power", seconds: 60)
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func log(_ message: String) {
        status.stringValue = message
        FileHandle.standardOutput.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + message + "\n").utf8))
    }

    private func stage(_ message: String, seconds: Double = 15) {
        log(message)
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.finish(false, "Timed out: " + message)
        }
    }

    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        log((success ? "PASS: " : "FAIL: ") + message)
        if central.state == .poweredOn {
            central.stopScan()
            if let device { central.cancelPeripheralConnection(device) }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            NSApplication.shared.terminate(nil)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !finished else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                finish(false, "Bluetooth state \(central.state.rawValue); check permission and power.")
            }
            return
        }
        guard !scanning && device == nil else { return }
        scanning = true
        stage("Scanning for PLANK Relay Lab", seconds: 20)
        central.scanForPeripherals(withServices: [serviceID])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !finished && device == nil else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard name == "PLANK Relay Lab" else { return }
        log("Discovered relay; RSSI \(RSSI.intValue) dBm")
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber,
           !connectable.boolValue {
            finish(false, "Advertisement is not connectable")
            return
        }
        central.stopScan()
        device = peripheral
        peripheral.delegate = self
        stage("Connecting to relay", seconds: 30)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !finished else { return }
        stage("Connected; discovering echo service")
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(false, "Connection rejected: " + (error?.localizedDescription ?? "unknown error"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finish(false, "Disconnected: " + (error?.localizedDescription ?? "link closed"))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !finished else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            finish(false, "Echo service discovery failed")
            return
        }
        stage("Discovering echo channels")
        peripheral.discoverCharacteristics([rxID, txID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !finished else { return }
        rx = service.characteristics?.first { $0.uuid == rxID }
        tx = service.characteristics?.first { $0.uuid == txID }
        guard error == nil, let rx, let tx, rx.properties.contains(.write), tx.properties.contains(.indicate) else {
            finish(false, "Expected echo write/indication channels are missing")
            return
        }
        stage("Subscribing to echo replies")
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !finished, characteristic.uuid == txID else { return }
        guard error == nil && characteristic.isNotifying else {
            finish(false, "Reply subscription failed")
            return
        }
        nextRound()
    }

    private func nextRound() {
        if round == sizes.count {
            finish(true, "3 verified round trips; 1600 bytes in each direction")
            return
        }
        expected = Data((0..<sizes[round]).map { _ in UInt8.random(in: .min ... .max) })
        received = Data()
        written = 0
        pendingWrite = false
        stage("Round \(round + 1): exchanging \(expected.count) bytes", seconds: 10)
        sendNext()
    }

    private func sendNext() {
        guard !finished, !pendingWrite, let device, let rx else { return }
        if written < expected.count {
            let size = min(512, device.maximumWriteValueLength(for: .withResponse))
            guard size > 0 else { finish(false, "Invalid write size"); return }
            let end = min(written + size, expected.count)
            let fragment = expected.subdata(in: written..<end)
            written = end
            pendingWrite = true
            device.writeValue(fragment, for: rx, type: .withResponse)
        } else if received.count == expected.count {
            guard received == expected else { finish(false, "Echo bytes differ"); return }
            log("Round \(round + 1) verified")
            round += 1
            nextRound()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !finished, characteristic.uuid == rxID, pendingWrite else { return }
        guard error == nil else { finish(false, "Write rejected"); return }
        pendingWrite = false
        sendNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !finished, characteristic.uuid == txID else { return }
        guard error == nil, let bytes = characteristic.value, !bytes.isEmpty,
              !expected.isEmpty, received.count + bytes.count <= expected.count else {
            finish(false, "Invalid or excessive reply")
            return
        }
        received.append(bytes)
        sendNext()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "PLANK Bluetooth Probe"
let label = NSTextField(wrappingLabelWithString: "Starting independent Bluetooth test…")
label.frame = NSRect(x: 24, y: 30, width: 512, height: 100)
window.contentView?.addSubview(label)
window.center()
window.makeKeyAndOrderFront(nil)
app.activate()
let probe = EchoProbe(status: label)
app.run()
