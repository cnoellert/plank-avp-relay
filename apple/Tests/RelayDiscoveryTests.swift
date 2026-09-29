// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main
enum RelayDiscoveryTests {
    static func main() {
        let first = UUID(), second = UUID()
        var scan = RelayDiscovery()
        precondition(scan.relays.isEmpty)
        scan.observe(id: first, advertisedName: "studio-relay", signal: -50, connectable: true, now: 10)
        precondition(scan.relays.count == 1) // Visible immediately; no startup wait.
        scan.observe(id: second, advertisedName: nil, signal: -60, connectable: true, now: 11)
        scan.observe(id: first, advertisedName: nil, signal: -51, connectable: true, now: 14)
        precondition(scan.relays.first?.name == "studio-relay")
        scan.expire(now: 16)
        precondition(scan.relays.map(\.id) == [first]) // Other relay stopped advertising.
        scan.observe(id: first, advertisedName: "renamed-relay", signal: -50, connectable: true, now: 18)
        precondition(scan.relays.first?.name == "renamed-relay")
        scan.expire(now: 22.9)
        precondition(scan.relays.count == 1)
        scan.expire(now: 23)
        precondition(scan.relays.isEmpty)
        scan.observe(id: first, advertisedName: "studio-relay", signal: -50, connectable: true, now: 24)
        scan.observe(id: first, advertisedName: "studio-relay", signal: -50, connectable: false, now: 25)
        precondition(scan.relays.isEmpty) // Present, but cannot accept a connection.
        for _ in 0..<40 {
            scan.observe(id: UUID(), advertisedName: nil, signal: -50, connectable: true, now: 30)
        }
        precondition(scan.relays.count == 32)
        scan.observe(id: second, advertisedName: "new-relay", signal: -50, connectable: true, now: 35)
        precondition(scan.relays.map(\.id) == [second]) // Expired entries cannot fill capacity.
        scan = RelayDiscovery()
        precondition(scan.relays.isEmpty) // Stopping/restarting cannot display old results.
        print("PASS: immediate discovery, refreshed presence, expiry, rename and scan reset")
    }
}
