// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

@main
enum RelayWifiTests {
    static func main() throws {
        let receipt = UUID().uuidString.lowercased()
        let fields: [String: Any] = ["version": 1, "id": 1, "ok": true, "supported": true,
            "enabled": true, "phase": "applying", "connection": "address", "requestID": receipt,
            "message": "Obtaining address", "network": String(repeating: "a", count: 32), "name": "Studio", "addresses": []]
        func status(_ changes: [String: Any]) throws -> RelayWifiStatus {
            try RelayWifiStatus.decode(JSONSerialization.data(withJSONObject: fields.merging(changes) { _, value in value }), request: 1)
        }
        let waiting = try status([:])
        precondition(waiting.applying && !waiting.canChange && !waiting.confirms(receipt))
        precondition(waiting.connectionLabel == "Obtaining address")
        let ready = try status(["phase": "idle", "connection": "connected"])
        precondition(ready.canChange && ready.confirms(receipt) && !ready.confirms(UUID().uuidString))
        for changes: [String: Any] in [["id": 2], ["phase": "done"], ["connection": "Internet"],
            ["network": "a"], ["requestID": "invalid"], ["addresses": Array(repeating: "192.0.2.1", count: 9)],
            ["ok": false, "error": "Authorized headset required"]] {
            do { _ = try status(changes); fatalError("Invalid Wi-Fi receipt accepted") } catch {}
        }
        let row: [String: Any] = ["id": String(repeating: "b", count: 32), "name": "Studio", "secured": true,
                                  "supported": true, "signal": 85, "saved": true, "hidden": false]
        let page: [String: Any] = ["version": 1, "id": 2, "ok": true, "networks": [row], "generation": receipt, "next": 8]
        func list(_ changes: [String: Any]) throws -> RelayWifiPage {
            try RelayWifiPage.decode(JSONSerialization.data(withJSONObject: page.merging(changes) { _, value in value }), request: 2)
        }
        let decoded = try list([:])
        precondition(decoded.networks[0].secured && decoded.networks[0].saved && decoded.next == 8)
        let open = try list(["networks": [row.merging(["secured": false]) { _, b in b }]])
        precondition(!open.networks[0].secured)
        for changes: [String: Any] in [["networks": [row, row]], ["next": 256], ["generation": "old"],
            ["networks": [row.merging(["signal": 101]) { _, b in b }]], ["id": 1]] {
            do { _ = try list(changes); fatalError("Invalid Wi-Fi list accepted") } catch {}
        }
        let command = WifiCommand.action(.join(network: nil, ssid: "Hidden", security: "personal", password: "test password"), request: receipt)
        let serialized = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
        precondition(serialized["network"] is NSNull && serialized["ssid"] as? String == "Hidden")
        precondition(serialized["password"] as? String == "test password")
        let scan = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WifiCommand.action(.scan, request: receipt))) as! [String: Any]
        precondition(Set(scan.keys) == Set(["version", "id", "op", "requestID"]))
        print("PASS: Wi-Fi receipts, stale replies, bounded pages, security flags and strict command encoding")
    }
}
