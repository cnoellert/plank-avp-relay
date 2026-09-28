// SPDX-License-Identifier: GPL-3.0-or-later
// Alternate radio endpoint for the existing tablet-free test; no tablet access.
import AppKit
@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class EchoPeripheral: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    private let serviceID = CBUUID(string: "462F3A10-7A31-4AB3-9E7F-C36AF495ECF0")
    private let rx = CBMutableCharacteristic(type: CBUUID(string: "462F3A13-7A31-4AB3-9E7F-C36AF495ECF0"),
        properties: [.write], value: nil, permissions: [.writeable])
    private let tx = CBMutableCharacteristic(type: CBUUID(string: "462F3A14-7A31-4AB3-9E7F-C36AF495ECF0"),
        properties: [.indicate], value: nil, permissions: [])
    private let status: NSTextField
    private var manager: CBPeripheralManager!
    private var peer: CBCentral?
    private var pending: [Data] = []
    private var total = 0
    private var registered = false
    private var stopping = false
    private var timeout: Task<Void, Never>?

    init(status: NSTextField) {
        self.status = status
        super.init()
        log("Starting Mac echo peripheral; generated test bytes only")
        manager = CBPeripheralManager(delegate: self, queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            self?.stop("Ten-minute diagnostic window ended")
        }
    }

    private func log(_ message: String) {
        status.stringValue = message
        FileHandle.standardOutput.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + message + "\n").utf8))
    }

    private func stop(_ message: String) {
        guard !stopping else { return }
        stopping = true
        log(message)
        timeout?.cancel()
        manager.stopAdvertising()
        manager.removeAllServices()
        pending.removeAll()
        peer = nil
        Task {
            try? await Task.sleep(for: .seconds(2))
            NSApplication.shared.terminate(nil)
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard !stopping else { return }
        guard peripheral.state == .poweredOn else {
            if peripheral.state != .unknown && peripheral.state != .resetting {
                stop("Bluetooth unavailable; state \(peripheral.state.rawValue)")
            }
            return
        }
        guard !registered else { return }
        registered = true
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [rx, tx]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard !stopping else { return }
        guard error == nil else { stop("Echo service registration failed"); return }
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: "PLANK Mac Echo",
            CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard !stopping else { return }
        if let error { stop("Advertising failed: " + error.localizedDescription) }
        else { log("Advertising PLANK Mac Echo. Select it in Test Setup and run Test Bluetooth connection.") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic) {
        guard !stopping, characteristic.uuid == tx.uuid else { return }
        guard peer == nil || peer?.identifier == central.identifier else {
            stop("Multiple subscribers; diagnostic stopped")
            return
        }
        peer = central
        total = 0
        pending.removeAll()
        log("Reply subscription received")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard !stopping, characteristic.uuid == tx.uuid,
              peer?.identifier == central.identifier else { return }
        log("Test link closed; echoed \(total) bytes")
        peer = nil
        pending.removeAll()
        total = 0
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard !stopping, let peer else {
            peripheral.respond(to: first, withResult: .unlikelyError)
            return
        }
        var input: [Data] = []
        for request in requests {
            guard request.central.identifier == peer.identifier,
                  request.characteristic.uuid == rx.uuid, request.offset == 0,
                  let value = request.value, !value.isEmpty, value.count <= 512 else {
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                return
            }
            input.append(value)
        }
        let count = input.reduce(0) { $0 + $1.count }
        guard total + count <= 4096 else {
            peripheral.respond(to: first, withResult: .insufficientResources)
            stop("Diagnostic byte limit reached")
            return
        }
        let maximum = min(512, peer.maximumUpdateValueLength)
        guard maximum > 0 else {
            peripheral.respond(to: first, withResult: .unlikelyError)
            stop("Invalid indication size")
            return
        }
        for value in input {
            for offset in stride(from: 0, to: value.count, by: maximum) {
                pending.append(value.subdata(in: offset..<min(offset + maximum, value.count)))
            }
        }
        total += count
        peripheral.respond(to: first, withResult: .success)
        flush()
    }

    private func flush() {
        guard !stopping, let peer else { return }
        while let value = pending.first {
            guard manager.updateValue(value, for: tx, onSubscribedCentrals: [peer]) else { return }
            pending.removeFirst()
        }
        log("Echoed \(total) generated test bytes")
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flush() }
}
