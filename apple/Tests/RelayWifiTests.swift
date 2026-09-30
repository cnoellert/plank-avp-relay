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
        let key = Data(repeating: 7, count: 32)
        let wifi = try status(["phase": "idle", "connection": "connected", "tcpPort": 31000,
                              "addresses": ["192.0.2.18", "fd12::18"]])
        let routes = wifi.routes(name: "Studio", relayKey: key)
        precondition(routes.count == 2 && routes.map(\.networkHost) == ["192.0.2.18", "fd12::18"])
        precondition(routes.allSatisfy { $0.linkType == 2 && $0.networkPort == 31000 && $0.advertisedKey == key })
        let bonjour = RelayAddress(service: "Studio", domain: "local.", name: "Studio", key: key)
        precondition(routes[0].keychainAccount == bonjour.keychainAccount, "Address changes retain the pinned identity")
        for changes: [String: Any] in [["enabled": false], ["supported": false], ["connection": "disconnected"],
                                       ["tcpPort": NSNull()]] {
            let status = try status(["connection": "connected", "tcpPort": 31000, "addresses": ["192.0.2.18"]]
                .merging(changes) { _, new in new })
            precondition(status.routes(name: "Studio", relayKey: key).isEmpty)
        }
        for host in ["relay.local", "127.0.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "::", "::1", "::ffff:127.0.0.1", "fe80::1", "fe80::1%en0", "ff02::1"] {
            let status = try status(["connection": "connected", "tcpPort": 31000, "addresses": [host]])
            precondition(status.routes(name: "Studio", relayKey: key).isEmpty)
        }
        var preference = RelayControlRoutes()
        let ble = RelayAddress(bluetoothIdentifier: UUID(), name: "Studio")
        preference.succeeded(bonjour)
        preference.failed(bonjour)
        precondition(preference.ordered([bonjour, ble] + routes, preferBluetooth: false).first == routes[0],
                     "A lost Ethernet address must fall back to authenticated Wi-Fi before Bluetooth")
        preference.succeeded(routes[0])
        precondition(preference.ordered([bonjour, ble] + routes, preferBluetooth: false).first == routes[0])
        for changes: [String: Any] in [["id": 2], ["phase": "done"], ["connection": "Internet"],
            ["tcpPort": 0], ["tcpPort": 65536], ["tcpPort": -1],
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
        for enabled in [true, false] {
            let command = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WifiCommand.action(.enable(enabled), request: receipt))) as! [String: Any]
            precondition(Set(command.keys) == Set(["version", "id", "op", "requestID", "enabled"]))
            precondition(command["op"] as? String == "wifi-enable" && command["enabled"] as? Bool == enabled)
        }
        let scan = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WifiCommand.action(.scan, request: receipt))) as! [String: Any]
        precondition(Set(scan.keys) == Set(["version", "id", "op", "requestID"]))
        print("PASS: Wi-Fi receipts, stale replies, bounded pages, security flags and strict command encoding")
    }
}
