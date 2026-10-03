// SPDX-License-Identifier: GPL-3.0-or-later
// Regression coverage for Bluetooth-only route selection in management probes
// and tablet readings. Readings use RelayTabletTest directly, without an extra
// preliminary connection. Remembered routes must obey the captured preference
// in either operation, even when a successful TCP route would be ordered first.
//
// Build/run: this target is registered in apps/tablet-setup/CMakeLists.txt and
// runs under `scripts/build-tablet-setup.sh macos` (Xcode Debug, so -Onone).
// Assertions use `precondition`, which survives optimization.
import Foundation
@testable import RelaySetupKit

@main
enum RelayTransportScopeTests {
    static func main() throws {
        let key = Data(repeating: 7, count: 32)
        let bluetooth = RelayAddress(bluetoothIdentifier: UUID(), name: "Relay")
        let bonjour = RelayAddress(service: "Relay", domain: "local.", name: "Relay", key: key)
        let learned = RelayAddress(wifiHost: "192.0.2.10", port: 28991, name: "Relay", key: key)
        let stale = RelayAddress(wifiHost: "198.51.100.20", port: 28991, name: "Relay", key: key)

        func isTCP(_ address: RelayAddress) -> Bool { address.networkHost != nil || address.networkService != nil }

        // A remembered successful TCP route and a failed Bluetooth attempt are
        // the worst case: ordering puts TCP first, so only the filter protects
        // the restriction.
        var routes = RelayControlRoutes()
        routes.succeeded(learned)
        routes.failed(bluetooth)

        // Management probe candidates. The selected relay alone is
        // the nothing-learned-yet shape. It carries no TCP route, so it proves
        // only that the Bluetooth route survives -- never that TCP is excluded.
        let probeSelectedOnly = routes.ordered([bluetooth], preferBluetooth: false)
        // The management case that can actually catch a broken filter: a
        // remembered successful TCP route is already known and orders first, so
        // the probe would reach it unless the restriction is applied here too.
        let probeOrdered = routes.ordered([bluetooth, learned], preferBluetooth: false)
        // Live-reading selection with previously learned routes.
        let readingOrdered = routes.ordered([bonjour, bluetooth, learned, stale], preferBluetooth: false)
        for (stage, ordered) in [("probe", probeOrdered), ("reading", readingOrdered)] {
            precondition(ordered.contains(where: isTCP), "\(stage) fixture must contain a TCP route to exclude")
            precondition(isTCP(ordered[0]), "\(stage) fixture must order the remembered TCP route first")
        }
        precondition(!probeSelectedOnly.contains(where: isTCP), "Selected-only probe shape carries no TCP route")

        if RelayTestTransport.isAvailable {
            for (stage, ordered) in [("probe-selected-only", probeSelectedOnly),
                                     ("probe", probeOrdered), ("reading", readingOrdered)] {
                let allowed = try RelayTestTransport.bluetoothOnly.candidates(ordered)
                precondition(!allowed.isEmpty, "\(stage): Bluetooth route must survive")
                precondition(!allowed.contains(where: isTCP), "\(stage): Bluetooth-only must exclude every TCP route")
                precondition(allowed == [bluetooth], "\(stage): only the Bluetooth route may remain")
                // Every retry in the attempt loop stays restricted.
                for attempt in 0..<4 { precondition(!isTCP(allowed[attempt % allowed.count])) }
            }
            // With no Bluetooth route, Bluetooth-only must fail closed rather
            // than probe a reachable TCP route.
            for ordered in [[learned], [bonjour, learned, stale]] {
                do {
                    _ = try RelayTestTransport.bluetoothOnly.candidates(routes.ordered(ordered, preferBluetooth: false))
                    fatalError("Bluetooth-only must not fall back to TCP")
                } catch RelaySetupError.network(let message) {
                    precondition(message.contains("Bluetooth"))
                }
            }
        } else {
            let unrestricted = try RelayTestTransport.bluetoothOnly.candidates(readingOrdered)
            precondition(unrestricted == readingOrdered,
                         "Removing the test feature restores normal routing")
        }

        // Automatic mode must keep every route so authenticated route learning
        // still reaches the TCP endpoints it exists to discover.
        let automatic = try RelayTestTransport.automatic.candidates(readingOrdered)
        precondition(automatic == readingOrdered)
        precondition(automatic.contains(where: isTCP), "Automatic must retain TCP routes for route learning")
        precondition(automatic.contains(learned) && automatic.contains(bluetooth))
        let automaticProbe = try RelayTestTransport.automatic.candidates(probeOrdered)
        precondition(automaticProbe == probeOrdered)
        precondition(automaticProbe.contains(where: isTCP),
                     "Automatic must retain the remembered TCP route during management probing")
        precondition(automaticProbe.contains(learned) && automaticProbe.contains(bluetooth))

        print("PASS: Bluetooth-only excludes TCP in probe and reading stages; automatic retains route learning")
    }
}
