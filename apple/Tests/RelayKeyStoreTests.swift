// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

@main
enum RelayKeyStoreTests {
    @MainActor static func main() {
        precondition(RelayKeyStore(bundleIdentifier: "la.instinctual.PLANK.TabletSetup").service ==
            "la.instinctual.PLANK.TabletSetup.pairing.v1", "Original app must read its existing saved approval")
        precondition(RelayKeyStore(bundleIdentifier: "la.instinctual.PLANK.AVPrelay").service ==
            "la.instinctual.PLANK.AVPrelay.pairing.v1", "Renamed app retains its own pairing namespace")
        precondition(RelayKeyStore().service == RelayKeyStore(bundleIdentifier: Bundle.main.bundleIdentifier).service,
            "Production initializer must select the installed app's namespace")
        let bluetooth = RelayAddress(bluetoothIdentifier: UUID(), name: "Reinstalled relay")
        let otherBluetooth = RelayAddress(bluetoothIdentifier: UUID(), name: "Another relay")
        let oldKey = Data(repeating: 1, count: 32), otherKey = Data(repeating: 2, count: 32)
        let canonical = "relay-key-v2:" + String(repeating: "01", count: 32)
        let network = RelayAddress(service: "Relay", domain: "local.", name: "Relay", key: oldKey)
        let records = [(bluetooth.keychainAccount, oldKey), (bluetooth.keychainAccount + ":setup", oldKey),
            (canonical, oldKey), (network.keychainAccount, oldKey),
            (otherBluetooth.keychainAccount, otherKey), ("client-private-v1", oldKey)]
        let forgotten = RelayKeyStore.accountsToForget(records, addresses: [bluetooth])
        precondition(forgotten == Set([bluetooth.keychainAccount, bluetooth.keychainAccount + ":setup",
            canonical, network.keychainAccount]))
        precondition(!forgotten.contains("client-private-v1") && !forgotten.contains(otherBluetooth.keychainAccount))
        // Newer network records may exist only under the canonical key.
        let canonicalOnly = RelayKeyStore.accountsToForget([(canonical, oldKey)], addresses: [network])
        precondition(canonicalOnly.contains(canonical))
        let pending = RelayKeyStore.accountsToForget([(bluetooth.keychainAccount + ":setup", oldKey)], addresses: [bluetooth])
        precondition(pending.contains(bluetooth.keychainAccount + ":setup"))
        // Advertising a different public key does not forget an unrelated pin.
        let replacement = RelayAddress(service: "Relay", domain: "local.", name: "Relay", key: otherKey)
        precondition(!RelayKeyStore.accountsToForget([(canonical, oldKey)], addresses: [replacement]).contains(canonical))
        print("PASS: relay replacement clears canonical, pending and transport aliases while retaining other relays and the headset key")
    }
}
