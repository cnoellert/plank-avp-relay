// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelaySetupKit

@main
enum RelayNetworkSettingsTests {
    static func main() throws {
        let request = UUID().uuidString.lowercased()
        let fields: [String: Any] = ["version": 1, "id": 1, "ok": true, "supported": true,
            "mode": "bridge", "targetMode": "router", "phase": "applying", "requestID": request,
            "message": "Changing mode", "ethernet": "connected", "usb": "disconnected", "addresses": []]
        func decode(_ changes: [String: Any]) throws -> RelayNetworkStatus {
            try RelayNetworkStatus.decode(JSONSerialization.data(withJSONObject: fields.merging(changes) { _, b in b }), request: 1)
        }
        let applying = try decode([:])
        precondition(applying.applying && !applying.canChange)
        precondition(applying.ethernetLabel == "Connected" && applying.usbLabel == "No USB connection")
        precondition(!applying.confirms(request, mode: .router))
        let done = try decode(["mode": "router", "phase": "idle"])
        precondition(done.confirms(request, mode: .router))
        precondition(!done.confirms(UUID().uuidString, mode: .router))
        precondition(!done.confirms(request, mode: .bridge))
        let unavailable = try decode(["supported": false, "phase": "unavailable", "usb": "unavailable"])
        precondition(!unavailable.canChange)
        for fields: [String: Any] in [["phase": "bogus"], ["usb": "active"], ["ethernet": "Internet"],
                                      ["mode": "wifi"], ["requestID": "bogus"], ["id": 2],
                                      ["ok": false, "error": "Authorized headset required"]] {
            do { _ = try decode(fields); fatalError("Invalid or rejected network status accepted") } catch {}
        }
        var state = SetupState()
        let address = RelayAddress(bluetoothIdentifier: UUID(), name: "relay")
        precondition(state.selectRelay(address))
        precondition(state.beginNetworkSettings() == nil)
        state.back()
        precondition(state.selectRelay(address, trusted: true))
        let operation = state.beginNetworkSettings()!
        precondition(state.activity == .managingNetwork && state.beginObservation() == nil)
        state.cancel()
        precondition(!state.succeed(operation) && state.hasTrust)
        print("PASS: network mode authorization, stale reply binding, actual USB status and recovery confirmation")
    }
}
