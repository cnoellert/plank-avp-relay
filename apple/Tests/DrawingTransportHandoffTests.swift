// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

@main enum DrawingTransportHandoffTests {
    static func main() throws {
        let identity = "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
        let management = Data(repeating: 0x42, count: 32)
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let status: [String: Any] = ["drawingHandoff": ["supported": true, "state": "ready", "descriptor": [
            "version": 2, "drawingIdentity": identity,
            "drawingProtocol": ["name": "pltr-raw-hid", "version": 1, "rawHID": 1, "linkType": 2],
            "routes": [], "bluetooth": ["linkType": 1]]]]
        let bytes = try JSONSerialization.data(withJSONObject: status)
        guard case var .handoffReady(descriptor) = DrawingHandoff.outcome(statusResponse: bytes, headsetAuthorized: true, allowV2: true) else {
            preconditionFailure("Bluetooth-only descriptor accepted")
        }
        precondition(descriptor.bluetoothAvailable && descriptor.routes.isEmpty)
        do {
            _ = try DrawingHandoff.link(descriptor: descriptor, displayName: "Studio Relay", managementIdentity: management)
            preconditionFailure("No unverified peripheral is handed off")
        } catch {}
        descriptor.bluetoothIdentifier = uuid
        let link = try DrawingHandoff.link(descriptor: descriptor, displayName: "Studio Relay", managementIdentity: management)
        precondition(link.url.path == "/v2")
        let encoded = link.url.query!.dropFirst(2)
        let request = try DrawingRegistrationRequest(requestID: String(repeating: "1", count: 32),
            clientIdentity: String(repeating: "2", count: 64), handoff: String(encoded))
        precondition(request.handoffURL == link.url)
        let target = try DrawingHandoff.registrationTarget(request)
        precondition(target.descriptor.bluetoothIdentifier == uuid && target.descriptor.routes.isEmpty)
        precondition(DrawingHandoffAction(outcome: .handoffReady(descriptor), activity: .idle, busy: false).bluetoothAvailable)
        let duplicate = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"linkType\":1", with: "\"linkType\":1,\"linkType\":2")
        if case .rejected = DrawingHandoff.state(statusResponse: Data(duplicate.utf8), allowV2: true) {} else { preconditionFailure("duplicate refused") }
        if case .rejected("version.unsupported") = DrawingHandoff.state(statusResponse: bytes) {} else { preconditionFailure("V1 remains frozen") }
        if let path = ProcessInfo.processInfo.environment["PLANK_V2_HANDOFF_OUTPUT"] {
            try link.url.absoluteString.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("DrawingTransportHandoffTests: passed")
    }
}
