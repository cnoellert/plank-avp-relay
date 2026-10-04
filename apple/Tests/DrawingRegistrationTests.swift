// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(RelaySetupKit)
@testable import RelaySetupKit
#endif

@main
@MainActor
enum DrawingRegistrationTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
    static func refused(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(message) }
        catch { checks += 1 }
    }
    static func main() throws {
        let request = try DrawingRegistrationRequest(requestID: String(repeating: "1", count: 32),
            clientIdentity: String(repeating: "2", count: 64), handoff: "e30")
        check(try DrawingRegistrationRequest.parse(request.url()) == request, "Setup URL round-trip")
        check(try DrawingRegistrationRequest.parse(request.url(reply: true), reply: true) == request, "reply round-trip")
        refused("reply cannot be a request") { _ = try DrawingRegistrationRequest.parse(request.url(reply: true)) }
        for suffix in ["&extra=1", "&requestID=" + request.requestID, "#fragment", "&", "=value"] {
            refused("URL fields remain exact") { _ = try DrawingRegistrationRequest.parse(URL(string: request.url().absoluteString + suffix)!) }
        }
        for id in ["", String(repeating: "0", count: 32), String(repeating: "A", count: 32), "../request"] {
            refused("invalid request id") { _ = try DrawingRegistrationRequest(requestID: id, clientIdentity: request.clientIdentity, handoff: request.handoff) }
        }
        for handoff in ["", "a", "e30=", "e%33%30", String(repeating: "x", count: 5463)] {
            refused("bounded canonical handoff envelope") { _ = try DrawingRegistrationRequest(requestID: request.requestID, clientIdentity: request.clientIdentity, handoff: handoff) }
        }
        let now = Date(timeIntervalSince1970: 1_000)
        func record(approved: Bool, expiry: TimeInterval = 120, id: String? = nil,
                    client: String? = nil, handoff: String? = nil, version: Int = 1) -> DrawingRegistrationReceipt.Record {
            .init(version: version, requestID: id ?? request.requestID, clientIdentity: client ?? request.clientIdentity,
                handoff: handoff ?? request.handoff, expires: now.addingTimeInterval(expiry), approved: approved)
        }
        check(record(approved: false).matches(request, approved: false, now: now), "pending request recognized")
        check(!record(approved: false).matches(request, approved: true, now: now), "a callback alone cannot approve a pending receipt")
        check(record(approved: true).matches(request, approved: true, now: now), "exact approved receipt accepted")
        check(!record(approved: true).matches(request, approved: false, now: now), "approved receipt cannot approve again")
        for invalid in [record(approved: true, expiry: 0), record(approved: true, expiry: -1),
                        record(approved: true, expiry: 126), record(approved: true, id: String(repeating: "3", count: 32)),
                        record(approved: true, client: String(repeating: "4", count: 64)),
                        record(approved: true, handoff: "W10"), record(approved: true, version: 2)] {
            check(!invalid.matches(request, approved: true, now: now), "expired or substituted receipt rejected")
        }
#if canImport(RelaySetupKit)
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PLANK_HANDOFF_FIXTURES"]!)
            .appendingPathComponent("link/valid/minimal.json")
        let data = try Data(contentsOf: fixture)
        func target(_ bytes: Data) throws -> DrawingRegistrationTarget {
            let payload = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return try DrawingHandoff.registrationTarget(.init(requestID: request.requestID,
                clientIdentity: request.clientIdentity, handoff: payload))
        }
        let parsed = try target(data)
        check(parsed.displayName == "Relay" && parsed.descriptor.routes.count == 1, "real handoff parsed")
        let text = String(decoding: data, as: UTF8.self)
        refused("duplicate handoff member") { _ = try target(Data(text.replacingOccurrences(of: "\"displayName\": \"Relay\"", with: "\"displayName\":\"Relay\",\"displayName\":\"Other\"").utf8)) }
        refused("trailing JSON") { _ = try target(data + Data("{}".utf8)) }
        refused("not a handoff") { _ = try target(Data("{}".utf8)) }
        refused("Client cannot approve its own drawing identity") {
            let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            _ = try DrawingHandoff.registrationTarget(.init(requestID: request.requestID,
                clientIdentity: parsed.descriptor.drawingIdentity, handoff: payload))
        }
#endif
        print("DrawingRegistrationTests: \(checks) checks passed")
    }
}
