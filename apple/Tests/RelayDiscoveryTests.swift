// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main
enum RelayDiscoveryTests {
    static func main() {
        let first = UUID(), second = UUID()
        var scan = RelayDiscovery()
        precondition(scan.relays.isEmpty)
        let unnamedAdvertisements: [String?] = [nil, "", " \n\t"]
        for name in unnamedAdvertisements {
            scan.observe(id: first, advertisedName: name, signal: -50, connectable: true, now: 9)
            precondition(scan.relays.isEmpty) // No placeholder before the name arrives.
        }
        scan.observe(id: first, advertisedName: "studio-relay", signal: -50, connectable: true, now: 10)
        precondition(scan.relays.count == 1) // Visible as soon as named; no startup wait.
        precondition(scan.relays.first?.name == "studio-relay")
        scan.observe(id: second, advertisedName: "second-relay", signal: -60, connectable: true, now: 11)
        precondition(scan.relays.count == 2)
        scan.observe(id: first, advertisedName: nil, signal: -51, connectable: true, now: 14)
        precondition(scan.relays.first?.name == "studio-relay")
        precondition(scan.relays.first?.signal == -51)
        scan.expire(now: 16)
        precondition(scan.relays.map(\.id) == [first]) // Other relay stopped advertising.
        scan.observe(id: first, advertisedName: "  renamed-relay\n", signal: -50, connectable: true, now: 18)
        precondition(scan.relays.first?.name == "renamed-relay")
        scan.observe(id: first, advertisedName: " \t", signal: -50, connectable: true, now: 18)
        precondition(scan.relays.first?.name == "renamed-relay")
        scan.expire(now: 22.9)
        precondition(scan.relays.count == 1)
        scan.expire(now: 23)
        precondition(scan.relays.isEmpty)
        scan.observe(id: first, advertisedName: nil, signal: -50, connectable: true, now: 23.5)
        precondition(scan.relays.isEmpty) // Expired names are not reused either.
        scan.observe(id: first, advertisedName: "studio-relay", signal: -50, connectable: true, now: 24)
        scan.observe(id: first, advertisedName: "studio-relay", signal: -50, connectable: false, now: 25)
        precondition(scan.relays.isEmpty) // Present, but cannot accept a connection.
        for _ in 0..<40 {
            scan.observe(id: UUID(), advertisedName: "nearby-relay", signal: -50, connectable: true, now: 30)
        }
        precondition(scan.relays.count == 32)
        scan.observe(id: second, advertisedName: "new-relay", signal: -50, connectable: true, now: 35)
        precondition(scan.relays.map(\.id) == [second]) // Expired entries cannot fill capacity.
        scan = RelayDiscovery()
        precondition(scan.relays.isEmpty) // Stopping/restarting cannot display old results.
        scan.observe(id: second, advertisedName: nil, signal: -50, connectable: true, now: 36)
        precondition(scan.relays.isEmpty) // Names must be learned again in the new scan.
        print("PASS: named discovery, no placeholders, refreshed presence, expiry, rename and scan reset")
    }
}
