// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

@main
enum RelayTestTransportTests {
    static func main() throws {
        let key = Data(repeating: 1, count: 32)
        let bluetooth = RelayAddress(bluetoothIdentifier: UUID(), name: "Relay")
        let bonjour = RelayAddress(service: "Relay", domain: "local.", name: "Relay", key: key)
        let wifi = RelayAddress(wifiHost: "192.0.2.1", port: 28991, name: "Relay", key: key)
        var routes = RelayControlRoutes()
        routes.succeeded(wifi)
        routes.failed(bluetooth)
        let automatic = routes.ordered([bonjour, bluetooth, wifi], preferBluetooth: false)
        precondition(automatic.first == wifi)
        let unrestricted = try RelayTestTransport.automatic.candidates(automatic)
        precondition(unrestricted == automatic)
        let strict = try RelayTestTransport.bluetoothOnly.candidates(automatic)
        if RelayTestTransport.isAvailable {
            // Even a successful remembered Wi-Fi route and a failed Bluetooth
            // attempt must leave every retry restricted to Bluetooth.
            precondition(strict == [bluetooth])
            for attempt in 0..<4 { precondition(strict[attempt % strict.count] == bluetooth) }
            do {
                _ = try RelayTestTransport.bluetoothOnly.candidates([bonjour, wifi])
                fatalError("Bluetooth-only must fail rather than fall back to a working network")
            } catch RelaySetupError.network(let message) {
                precondition(message.contains("Bluetooth"))
            }
        } else {
            precondition(strict == automatic, "Removing the test feature restores normal routing")
        }
        let suite = "relay-transport-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(RelayTestTransport.load(from: defaults) == .automatic)
        RelayTestTransport.bluetoothOnly.save(to: defaults)
        precondition(RelayTestTransport.load(from: defaults) == (RelayTestTransport.isAvailable ? .bluetoothOnly : .automatic))
        // Include a preference left by a previous build with the feature on.
        defaults.set("bluetoothOnly", forKey: "temporary.relayTestTransport")
        precondition(RelayTestTransport.load(from: defaults) == (RelayTestTransport.isAvailable ? .bluetoothOnly : .automatic))
        RelayTestTransport.automatic.save(to: defaults)
        precondition(RelayTestTransport.load(from: defaults) == .automatic)
        defaults.set("unknown", forKey: "temporary.relayTestTransport")
        precondition(RelayTestTransport.load(from: defaults) == .automatic)
        print("PASS: strict test routes, unavailable Bluetooth, persistence and feature removal")
    }
}
