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
        print("PASS: tablet setup response binding, offline state and validation")
    }
}
