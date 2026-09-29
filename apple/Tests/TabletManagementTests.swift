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
        print("PASS: setup response binding, identity validation, retained ownership after removal and offline state")
    }
}
