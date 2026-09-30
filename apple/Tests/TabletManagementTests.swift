// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelaySetupKit

@main
enum TabletManagementTests {
    static func main() throws {
        let fields: [String: Any] = ["version": 1, "id": 3, "ok": true,
            "hostname": "studio-relay", "phase": "idle", "message": "Wake the saved tablet.",
            "canManage": false, "initialSetup": false, "attached": false, "secondsRemaining": 0,
            "tablets": [["id": "AA:BB:CC:DD:EE:01", "name": "Tablet", "paired": true, "connected": false]],
            "candidates": []]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let status = try TabletSetupStatus.decode(data, request: 3)
        precondition(status.tablets.count == 1 && !status.tablets[0].connected)
        precondition(!status.initialSetup && !status.canManage && status.hostname == "studio-relay")
        precondition(status.enrollmentIdentity == nil && status.headsetAuthorized != true)
        precondition(status.captureActive == nil && status.captureBusy == nil)
        precondition(!status.canStartReadings) // Saved rows need a selected tablet.
        let selected = fields.merging(["selected": "AA:BB:CC:DD:EE:01"]) { _, new in new }
        let sleepingTablet = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: selected), request: 3)
        precondition(sleepingTablet.canStartReadings)
        for changes: [String: Any] in [["selected": "AA:BB:CC:DD:EE:02"],
            ["selected": "AA:BB:CC:DD:EE:01", "phase": "pairing"],
            ["selected": "AA:BB:CC:DD:EE:01", "tablets": [["id": "AA:BB:CC:DD:EE:01", "name": "Tablet", "paired": false, "connected": true]]]] {
            let decoded = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: fields.merging(changes) { _, new in new }), request: 3)
            precondition(!decoded.canStartReadings)
        }
        let usb = fields.merging(["tablets": [], "attached": true]) { _, new in new }
        let usbTablet = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: usb), request: 3)
        precondition(usbTablet.canStartReadings)
        let wired = usb.merging(["bluetoothAvailable": false, "usbTablets": [[
            "id": "usb:0123456789abcdef", "name": "Wacom USB", "serial": "serial", "port": "1-2", "active": true]]]) { _, new in new }
        let wiredTablet = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: wired), request: 3)
        precondition(wiredTablet.canStartReadings && wiredTablet.bluetoothAvailable == false)
        precondition(wiredTablet.activeUSBTablet?.serial == "serial")
        let available = wired.merging(["canManage": true, "captureActive": false, "captureBusy": false]) { _, new in new }
        let availableTablet = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: available), request: 3)
        precondition(availableTablet.canStartReadings && availableTablet.canChangeTablet)
        let managed = available.merging(["captureActive": true]) { _, new in new }
        let managedTablet = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: managed), request: 3)
        precondition(managedTablet.captureActive == true && managedTablet.canStartReadings)
        let busy = available.merging(["captureBusy": true]) { _, new in new }
        let busyTablet = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: busy), request: 3)
        precondition(busyTablet.captureBusy == true && busyTablet.attached && busyTablet.activeUSBTablet != nil)
        precondition(!busyTablet.canStartReadings && !busyTablet.canChangeTablet)
        let busyBluetooth = selected.merging(["canManage": true, "captureBusy": true]) { _, new in new }
        let busyBluetoothTablet = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: busyBluetooth), request: 3)
        precondition(!busyBluetoothTablet.canStartReadings && !busyBluetoothTablet.canChangeTablet)
        let noRadio = selected.merging(["bluetoothAvailable": false]) { _, new in new }
        let noRadioStatus = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: noRadio), request: 3)
        precondition(!noRadioStatus.canStartReadings)
        let unplugged = wired.merging(["attached": false, "usbTablets": []]) { _, new in new }
        let unpluggedTablet = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: unplugged), request: 3)
        precondition(!unpluggedTablet.canStartReadings && unpluggedTablet.activeUSBTablet == nil)
        let identity = String(repeating: "12", count: 32)
        for (key, version, valid) in [(identity, 1, true), ("bad", 1, false),
                                     (String(repeating: "zz", count: 32), 1, false), (identity, 2, false)] {
            let updated = fields.merging(["relayKey": key, "enrollmentVersion": version]) { _, new in new }
            let parsed = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: updated), request: 3)
            precondition((parsed.enrollmentIdentity != nil) == valid)
            precondition(parsed.headsetAuthorized != true) // Public identity is not approval.
        }
        let removed = fields.merging(["tablets": [], "canManage": true, "headsetAuthorized": true]) { _, new in new }
        let afterRemoval = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject: removed), request: 3)
        precondition(afterRemoval.tablets.isEmpty && afterRemoval.canManage && afterRemoval.headsetAuthorized == true)
        precondition(!afterRemoval.needsHeadsetRecovery)
        precondition(!afterRemoval.canStartReadings)
        do {
            _ = try TabletSetupStatus.decode(data, request: 4)
            fatalError("A stale response must not complete a new request")
        } catch {}
        for changes: [String: Any] in [["version": 2], ["phase": "unknown"], ["secondsRemaining": 99],
                                       ["ok": false, "error": "Approved headset required"]] {
            let invalid = try JSONSerialization.data(withJSONObject: fields.merging(changes) { _, new in new })
            do {
                _ = try TabletSetupStatus.decode(invalid, request: 3)
                fatalError("Invalid or rejected setup status accepted")
            } catch {}
        }
        print("PASS: setup response binding, capture ownership, identity validation, retained ownership and offline state")
    }
}
