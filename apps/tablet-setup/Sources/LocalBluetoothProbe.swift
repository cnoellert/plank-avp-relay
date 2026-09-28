// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
@preconcurrency import CoreBluetooth
import Foundation

struct LocalBluetoothDevice: Identifiable {
    let id: UUID
    let name: String
    let detail: String
}

struct LocalBluetoothChannel: Identifiable {
    let id: UUID
    let service: String
    let characteristic: String
    let canNotify: Bool
}

/// Bounded, user-selected GATT inspection. No characteristic reads, control writes,
/// automatic subscriptions, pairing-key management or model-specific assumptions.
@MainActor
final class LocalBluetoothProbe: NSObject, ObservableObject,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var devices: [LocalBluetoothDevice] = []
    @Published private(set) var channels: [LocalBluetoothChannel] = []
    @Published private(set) var status = "Scan to check for app-accessible Bluetooth services."
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var packets = 0
    @Published private(set) var bytes = 0
    @Published private(set) var listening: UUID?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [UUID: CBCharacteristic] = [:]
    private var selected: CBPeripheral?
    private var scanning = false
    private var pendingServices = Set<ObjectIdentifier>()
    private var discoveryErrors = 0
    private var deadline: Task<Void, Never>?

    func scan() {
        stop()
        devices = []; channels = []; peripherals = [:]; characteristics = [:]
        packets = 0; bytes = 0
        scanning = true; busy = true
        status = "Scanning for 15 seconds…"
        central = CBCentralManager(delegate: self, queue: .main)
        setDeadline(seconds: 15) { probe in
            probe.central?.stopScan(); probe.scanning = false; probe.busy = false
            probe.status = probe.devices.isEmpty
                ? "No app-accessible device found. System pairing alone does not expose Bluetooth services."
                : "Choose the tablet to inspect its services. Other nearby devices may appear."
        }
    }

    func stop() {
        deadline?.cancel(); deadline = nil
        scanning = false; busy = false; connected = false; listening = nil
        central?.stopScan()
        if let selected {
            selected.delegate = nil
            central?.cancelPeripheralConnection(selected)
        }
        selected = nil
        central?.delegate = nil; central = nil
        peripherals = [:]; characteristics = [:]; channels = []; devices = []
        pendingServices = []
        status = "Bluetooth test stopped. Scan to try again."
    }

    func inspect(_ id: UUID) {
        guard let central, central.state == .poweredOn,
              let peripheral = peripherals[id], selected == nil else { return }
        deadline?.cancel(); central.stopScan(); scanning = false
        selected = peripheral; peripheral.delegate = self
        channels = []; characteristics = [:]; discoveryErrors = 0
        busy = true; status = "Connecting to \(peripheral.name ?? "selected device")…"
        central.connect(peripheral)
        setDeadline(seconds: 20) { probe in
            probe.stop()
            probe.status = "Connection or service discovery timed out. Scan to retry."
        }
    }

    func listen(_ id: UUID) {
        guard let selected, connected, !busy, listening == nil,
              let characteristic = characteristics[id],
              characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else { return }
        packets = 0; bytes = 0; listening = id; busy = true
        status = "Requesting updates from \(characteristic.uuid.uuidString)…"
        selected.setNotifyValue(true, for: characteristic)
        setDeadline(seconds: 10) { probe in
            probe.stop(); probe.status = "Notification subscription timed out. Scan to retry."
        }
    }

    private func setDeadline(seconds: Int, action: @escaping @MainActor (LocalBluetoothProbe) -> Void) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self else { return }
            action(self)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        guard central.state == .poweredOn else {
            if central.state == .unknown || central.state == .resetting { return }
            let reason = central.state == .unauthorized ? "Allow Bluetooth for this app in Settings."
                : central.state == .poweredOff ? "Turn on Bluetooth in Settings." : "Bluetooth is unavailable."
            stop(); status = reason; return
        }
        guard scanning else { return }
        // This is not a list of all OS-paired devices. These standard services
        // allow already-connected peripherals to appear if CoreBluetooth exposes them.
        for peripheral in central.retrieveConnectedPeripherals(withServices:
            [CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A")]) {
            add(peripheral, name: peripheral.name, detail: "Connected device with a visible standard service")
        }
        central.scanForPeripherals(withServices: nil)
    }

    private func add(_ peripheral: CBPeripheral, name: String?, detail: String) {
        guard peripherals[peripheral.identifier] != nil || devices.count < 64 else { return }
        peripherals[peripheral.identifier] = peripheral
        let device = LocalBluetoothDevice(id: peripheral.identifier,
            name: String((name ?? "Unnamed Bluetooth device").prefix(80)), detail: detail)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, scanning else { return }
        add(peripheral, name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            detail: "Advertised signal \(RSSI.intValue) dBm")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === selected else { return }
        status = "Discovering services…"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === selected else { return }
        stop(); status = "Connection failed: \(error?.localizedDescription ?? "no connection")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === selected else { return }
        stop(); status = "Device disconnected. \(error?.localizedDescription ?? "Scan to retry.")"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === selected else { return }
        if let error { stop(); status = "Service discovery failed: \(error.localizedDescription)"; return }
        let services = Array((peripheral.services ?? []).prefix(64))
        pendingServices = Set(services.map(ObjectIdentifier.init))
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        finishDiscoveryIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === selected, pendingServices.remove(ObjectIdentifier(service)) != nil else { return }
        if error != nil { discoveryErrors += 1 }
        for characteristic in (service.characteristics ?? []).prefix(max(0, 128 - channels.count)) {
            let id = UUID()
            characteristics[id] = characteristic
            channels.append(LocalBluetoothChannel(id: id, service: service.uuid.uuidString,
                characteristic: characteristic.uuid.uuidString,
                canNotify: characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)))
        }
        finishDiscoveryIfReady()
    }

    private func finishDiscoveryIfReady() {
        guard pendingServices.isEmpty else { return }
        deadline?.cancel(); deadline = nil; busy = false; connected = true
        status = "Found \(channels.count) characteristics\(discoveryErrors > 0 ? "; some services could not be inspected" : ""). " +
            (channels.contains { $0.canNotify } ? "Choose Listen on one channel, then move the pen and press a tablet button."
                : "No notification channel is exposed to this app.")
        setDeadline(seconds: 120) { probe in
            probe.stop(); probe.status = "Inspection ended after two minutes. Scan to try again."
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, let listening, characteristics[listening] === characteristic else { return }
        if let error { stop(); status = "Updates unavailable: \(error.localizedDescription)"; return }
        guard characteristic.isNotifying else { stop(); status = "The device did not enable updates."; return }
        busy = false; status = "Listening for 60 seconds. Packet counts alone do not confirm tablet input."
        setDeadline(seconds: 60) { probe in
            let count = probe.packets
            probe.stop(); probe.status = "Finished: \(count) notifications. \(count == 0 ? "No data received." : "Report decoding is not yet implemented.")"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, let listening, characteristics[listening] === characteristic else { return }
        if let error { stop(); status = "Update failed: \(error.localizedDescription)"; return }
        packets += 1; bytes += characteristic.value?.count ?? 0
        // Raw reports deliberately stay out of disk logs and retained app state.
    }
}
