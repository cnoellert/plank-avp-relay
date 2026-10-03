// SPDX-License-Identifier: GPL-3.0-or-later
//
// plank-drawing-handoff-v1+r3 conformance for the Setup app.
//
// Frozen harness and flags (contract §12.2, MANIFEST.json testFlags):
//     bash scripts/build-tablet-setup.sh macos
// which configures the Xcode generator, builds `--config Debug` and then runs
// `ctest --test-dir … -C Debug --output-on-failure`. `Debug` means `-Onone`,
// but every assertion below is a `precondition` or an explicit failure check,
// so the result does not depend on the configuration. Never a bare `assert`:
// Swift `assert` is removed by `-O`, which was measured.
//
// Vectors are LOADED from the shared fixtures, never retyped. The directory
// arrives in PLANK_HANDOFF_FIXTURES from apps/tablet-setup/CMakeLists.txt, and
// every file's SHA-256 is verified against MANIFEST.json, whose own SHA-256 is
// asserted against the literal in the fixtures' README, so a contract revision
// fails this test instead of quietly diverging.
import CryptoKit
import Foundation
@testable import RelaySetupKit

@main
enum DrawingHandoffTests {
    static let manifestSHA256 = "dd1125d8257f11431671fe116335c4e3c798c157207bdd576f3c44e724e95954"
    static let contractRevision = "plank-drawing-handoff-v1+r3"
    static let contractSHA256 = "1dce3dd079e26bc9d348d3fbea96e035c743e8ace390171862226c9a043545fc"

    nonisolated(unsafe) static var manifest: [String: Any] = [:]
    nonisolated(unsafe) static var files: [String: [String: Any]] = [:]

    // MARK: Harness

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static var directory: URL {
        guard let path = ProcessInfo.processInfo.environment["PLANK_HANDOFF_FIXTURES"], !path.isEmpty else {
            fail("PLANK_HANDOFF_FIXTURES is not set; the fixture directory comes from CMake")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Loads a fixture and verifies its SHA-256 and byte count from the
    /// manifest, so a corrupted or locally edited mirror fails loudly.
    static func load(_ name: String) -> Data {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            fail("fixture \(name) could not be read")
        }
        guard let entry = files[name], let expected = entry["sha256"] as? String,
              let bytes = entry["bytes"] as? Int else { fail("\(name) is not listed in MANIFEST.json") }
        check(digest(data) == expected, "\(name) does not match its MANIFEST.json SHA-256")
        check(data.count == bytes, "\(name) is \(data.count) bytes, MANIFEST.json says \(bytes)")
        return data
    }

    static func expectation(_ name: String) -> String {
        guard let value = files[name]?["expect"] as? String else { fail("\(name) has no expect in MANIFEST.json") }
        return value
    }

    static func names(prefix: String, suffix: String = "") -> [String] {
        files.keys.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted()
    }

    // MARK: Splicing

    /// Wraps a `drawingHandoff` value in an otherwise ordinary authenticated
    /// status response, byte for byte, so a fixture's deliberate formatting —
    /// insignificant white space, a duplicate member — survives into the bytes
    /// the decoder scans.
    static func statusResponse(drawingHandoff: Data?, headsetAuthorized: Bool = true,
                               relayKey: String? = nil) -> Data {
        var text = "{\"version\":1,\"id\":3,\"ok\":true,\"hostname\":\"studio-relay\",\"phase\":\"ready\""
        text += ",\"message\":\"Ready.\",\"canManage\":true,\"initialSetup\":false,\"attached\":true"
        text += ",\"secondsRemaining\":0,\"tablets\":[],\"candidates\":[],\"enrollmentVersion\":1"
        text += ",\"headsetAuthorized\":\(headsetAuthorized)"
        if let relayKey { text += ",\"relayKey\":\"\(relayKey)\"" }
        guard let drawingHandoff else { return Data((text + "}").utf8) }
        var data = Data((text + ",\"drawingHandoff\":").utf8)
        data.append(drawingHandoff)
        data.append(contentsOf: "}".utf8)
        return data
    }

    /// A ready wrapper around a descriptor assembled from raw fixture member
    /// bytes, used to exercise the shared field rules of §5.1, §5.2 and §5.3
    /// with link-entry-point vectors without retyping any of them.
    static func readyWrapper(identity: Data?, drawingProtocol: Data?, routes: Data?) -> Data {
        var data = Data("{\"supported\":true,\"state\":\"ready\",\"descriptor\":{\"version\":1".utf8)
        if let identity {
            data.append(contentsOf: ",\"drawingIdentity\":".utf8)
            data.append(identity)
        }
        if let drawingProtocol {
            data.append(contentsOf: ",\"drawingProtocol\":".utf8)
            data.append(drawingProtocol)
        }
        if let routes {
            data.append(contentsOf: ",\"routes\":".utf8)
            data.append(routes)
        }
        data.append(contentsOf: "}}".utf8)
        return data
    }

    /// Returns a top-level member's value exactly as stored in the fixture.
    static func rawMember(_ name: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        func skipWhitespace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0a || bytes[index] == 0x0d { index += 1 }
        }
        func skipString() {
            index += 1
            while index < bytes.count {
                if bytes[index] == 0x5c { index += 2; continue }
                if bytes[index] == 0x22 { index += 1; return }
                index += 1
            }
        }
        func skipValue() {
            skipWhitespace()
            guard index < bytes.count else { return }
            switch bytes[index] {
            case 0x22: skipString()
            case 0x7b, 0x5b:
                var open = 0
                while index < bytes.count {
                    let byte = bytes[index]
                    if byte == 0x22 { skipString(); continue }
                    if byte == 0x7b || byte == 0x5b { open += 1 }
                    if byte == 0x7d || byte == 0x5d {
                        open -= 1
                        index += 1
                        if open == 0 { return }
                        continue
                    }
                    index += 1
                }
            default:
                while index < bytes.count, bytes[index] != 0x2c, bytes[index] != 0x7d,
                      bytes[index] != 0x5d { index += 1 }
            }
        }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x7b else { return nil }
        index += 1
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { return nil }
            let start = index
            skipString()
            let key = String(bytes: bytes[(start + 1)..<(index - 1)], encoding: .utf8)
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3a else { return nil }
            index += 1
            skipWhitespace()
            let valueStart = index
            skipValue()
            if key == name { return Data(bytes[valueStart..<index]) }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x2c else { return nil }
            index += 1
        }
    }

    static func reported(_ state: DrawingHandoffState) -> String {
        switch state {
        case .absent: "absent"
        case .present(let status): status.descriptor != nil ? "accept" : (status.reason ?? "accept")
        case .rejected(let identifier): identifier
        }
    }

    // MARK: Groups

    /// Every `status/**` vector, at entry point 2, through the real decoder.
    static func statusFixtures() {
        var checked = 0
        for name in names(prefix: "status/", suffix: ".json") {
            let fixture = load(name)
            let state = DrawingHandoff.state(statusResponse: statusResponse(drawingHandoff: fixture))
            let expected = expectation(name)
            if expected == "accept" {
                switch state {
                case .present(let status):
                    check(status.supported, "\(name): a conforming relay reports supported")
                    if let reason = status.reason {
                        check(DrawingHandoffReason.unavailable.contains(reason)
                            || DrawingHandoffReason.unsupported.contains(reason),
                            "\(name): reason \(reason) is outside the frozen set")
                        check(status.descriptor == nil, "\(name): unavailable carries no descriptor")
                    } else {
                        guard let descriptor = status.descriptor else { fail("\(name): ready without a descriptor") }
                        check(descriptor.version == 1, "\(name): descriptor version")
                        check(descriptor.drawingIdentity.count == 64, "\(name): drawing identity length")
                        check(descriptor.drawingProtocol.linkType == 2, "\(name): drawing handoff is a TCP handoff")
                        check((1...8).contains(descriptor.routes.count), "\(name): route count")
                        for route in descriptor.routes {
                            // Wildcard and loopback are legal only in the raw
                            // listener metadata and never reach a descriptor.
                            check(route.address != "0.0.0.0", "\(name): a wildcard route escaped conversion")
                            check(!route.address.hasPrefix("127."), "\(name): a loopback route escaped conversion")
                        }
                    }
                default: fail("\(name) must be accepted, got \(reported(state))")
                }
            } else {
                check(reported(state) == expected,
                    "\(name) must fail at \(expected), got \(reported(state))")
            }
            checked += 1
        }
        check(checked == 24, "expected 24 status fixtures, walked \(checked)")
        print("  status/** vectors: \(checked)")
    }

    /// The three forbidden members, named one by one because requiring any of
    /// them was the r1 defect: it would make every honest status invalid.
    static func forbiddenStatusMembers() {
        for name in ["status/invalid/with-request-id.json", "status/invalid/with-display-name.json",
                     "status/invalid/with-management-identity.json"] {
            let state = DrawingHandoff.state(statusResponse: statusResponse(drawingHandoff: load(name)))
            check(reported(state) == "status.unknownMember", "\(name) must be status.unknownMember")
        }
        // The same descriptor without them is accepted, so the rejection above
        // is the forbidden member and not some other difference.
        let ready = DrawingHandoff.state(statusResponse: statusResponse(drawingHandoff: load("status/valid/ready.json")))
        check(reported(ready) == "accept", "the canonical ready descriptor must be accepted")
        // A non-object descriptor reports its own identifier, before anything
        // inside it could be examined.
        for name in ["status/invalid/descriptor-not-object.json", "status/invalid/descriptor-null.json",
                     "status/invalid/descriptor-array.json"] {
            let state = DrawingHandoff.state(statusResponse: statusResponse(drawingHandoff: load(name)))
            check(reported(state) == "status.descriptor.type", "\(name) must be status.descriptor.type")
        }
        print("  forbidden members and non-object descriptor: pinned")
    }

    /// Duplicate member names, found in the original response bytes. A tolerant
    /// envelope decode collapses them, so this can only work on the raw bytes.
    static func duplicateMembers() {
        for name in ["link/invalid/payload-duplicate-member.json",
                     "link/invalid/payload-duplicate-member-nested.json",
                     "link/invalid/payload-duplicate-member-escaped.json",
                     "link/invalid/payload-duplicate-member-escaped-nested.json"] {
            let fixture = load(name)
            check(expectation(name) == "payload.duplicateMember", "\(name) expectation changed")
            let state = DrawingHandoff.state(statusResponse: statusResponse(drawingHandoff: fixture))
            check(reported(state) == "payload.duplicateMember",
                "\(name) must be payload.duplicateMember, got \(reported(state))")
            // Proof that the collapse really happens, so the check above cannot
            // be satisfied by inspecting a decoded object.
            if let object = try? JSONSerialization.jsonObject(with: fixture) as? [String: Any] {
                check(object.keys.count == 7, "a tolerant decode of \(name) already collapsed the duplicate")
            }
        }
        // Acceptance control: the same member name in two sibling objects is
        // normal. It must reach the member-set check instead of the scan.
        let sibling = "link/valid/sibling-members-not-duplicate.json"
        let state = DrawingHandoff.state(statusResponse: statusResponse(drawingHandoff: load(sibling)))
        check(reported(state) == "status.unknownMember",
            "\(sibling) must pass the duplicate scan and fail the member set, got \(reported(state))")
        // The scan is scoped to the subtree: a duplicate elsewhere in the
        // tolerant envelope is not this subtree's rejection.
        var envelope = Data("{\"ok\":true,\"ok\":true,\"drawingHandoff\":".utf8)
        envelope.append(load("status/valid/ready.json"))
        envelope.append(contentsOf: "}".utf8)
        check(reported(DrawingHandoff.state(statusResponse: envelope)) == "accept",
            "a duplicate outside the drawingHandoff subtree must not reject the descriptor")
        print("  duplicate member scan over original bytes: pinned")
    }

    /// Shared field rules of §5.1, §5.2, §5.3 and §7.6, exercised with the
    /// link-entry-point vectors that carry them. Only the shared identifiers are
    /// selected, so no vector is judged under the wrong entry point.
    static func sharedFieldRules() {
        var checked = 0
        for name in names(prefix: "link/", suffix: ".json") {
            let expected = expectation(name)
            let shared = expected.hasPrefix("route.") || expected.hasPrefix("routes.")
                || expected.hasPrefix("drawingProtocol.")
                || ["drawingIdentity.missing", "drawingIdentity.type", "drawingIdentity.invalid"].contains(expected)
            guard shared || (expected == "accept" && name.hasPrefix("link/valid/")) else { continue }
            let fixture = load(name)
            let wrapper = readyWrapper(identity: rawMember("drawingIdentity", in: fixture),
                drawingProtocol: rawMember("drawingProtocol", in: fixture),
                routes: rawMember("routes", in: fixture))
            let state = DrawingHandoff.state(statusResponse: statusResponse(drawingHandoff: wrapper))
            check(reported(state) == expected,
                "\(name) under the shared field rules must be \(expected), got \(reported(state))")
            checked += 1
        }
        check(checked >= 60, "expected the shared rules to cover at least 60 vectors, covered \(checked)")
        print("  shared field rules from link vectors: \(checked)")
    }

    /// The three outcomes of §11, kept apart.
    static func outcomes() {
        let ready = load("status/valid/ready.json")
        guard case .handoffReady = DrawingHandoff.outcome(
            statusResponse: statusResponse(drawingHandoff: ready), headsetAuthorized: true) else {
            fail("the canonical ready descriptor must be handoffReady")
        }
        // A missing drawing service is never an authorization problem.
        for (name, reason) in [("status/valid/unavailable.json", "service.absent"),
                               ("status/valid/unavailable-peer-unverified.json", "service.peerUnverified"),
                               ("status/valid/unavailable-loopback-only.json", "listener.loopbackOnly")] {
            let outcome = DrawingHandoff.outcome(statusResponse: statusResponse(drawingHandoff: load(name)),
                headsetAuthorized: true)
            check(outcome == .drawingUnavailable(reason), "\(name) must be drawingUnavailable(\(reason))")
            check(outcome.descriptor == nil, "\(name) offers no descriptor")
        }
        // A squatter is never reported as a missing service, and the reverse.
        let absent = DrawingHandoff.outcome(statusResponse: statusResponse(
            drawingHandoff: load("status/valid/unavailable.json")), headsetAuthorized: true)
        let squatted = DrawingHandoff.outcome(statusResponse: statusResponse(
            drawingHandoff: load("status/valid/unavailable-peer-unverified.json")), headsetAuthorized: true)
        check(absent != squatted, "service.absent and service.peerUnverified must not be conflated")
        // A relay that does not report the member at all is too old, and an
        // unauthorized headset is never told to update its relay.
        check(DrawingHandoff.outcome(statusResponse: statusResponse(drawingHandoff: nil),
            headsetAuthorized: true) == .handoffUnsupported("relay.tooOld"), "absent member is relay.tooOld")
        for authorized in [false, nil] as [Bool?] {
            let outcome = DrawingHandoff.outcome(statusResponse: statusResponse(drawingHandoff: ready,
                headsetAuthorized: authorized ?? false), headsetAuthorized: authorized)
            check(outcome == .handoffUnsupported("authorization.required"),
                "an unauthorized headset is authorization.required, got \(String(describing: outcome.reason))")
            check(outcome.reason != "relay.tooOld", "authorization is never reported as an old relay")
        }
        // A descriptor that does not validate is a protocol error, not a
        // missing service and not an authorization failure.
        let broken = DrawingHandoff.outcome(statusResponse: statusResponse(
            drawingHandoff: load("status/invalid/route-wildcard.json")), headsetAuthorized: true)
        check(broken == .handoffUnsupported("protocol.error"), "an invalid descriptor is protocol.error")
        // Every frozen reason classifies into exactly one outcome.
        for reason in DrawingHandoffReason.unavailable {
            let wrapper = Data("{\"supported\":true,\"state\":\"unavailable\",\"reason\":\"\(reason)\"}".utf8)
            check(DrawingHandoff.outcome(statusResponse: statusResponse(drawingHandoff: wrapper),
                headsetAuthorized: true) == .drawingUnavailable(reason), "\(reason) is drawingUnavailable")
        }
        for reason in DrawingHandoffReason.unsupported {
            let wrapper = Data("{\"supported\":true,\"state\":\"unavailable\",\"reason\":\"\(reason)\"}".utf8)
            check(DrawingHandoff.outcome(statusResponse: statusResponse(drawingHandoff: wrapper),
                headsetAuthorized: true) == .handoffUnsupported(reason), "\(reason) is handoffUnsupported")
        }
        check(DrawingHandoffReason.unavailable.isDisjoint(with: DrawingHandoffReason.unsupported),
            "the two reason sets must stay disjoint")
        print("  three outcomes: pinned")
    }

    /// Entry point 3. The canonical link is reproduced exactly, and nothing
    /// outside the closed seven-member set can travel in it.
    static func appLink() {
        guard let link = manifest["appLink"] as? [String: Any],
              let example = link["canonicalExample"] as? [String: Any],
              let payloadBytes = example["decodedPayloadBytes"] as? Int,
              let encodedCharacters = example["encodedCharacters"] as? Int,
              let maxDecoded = link["maxDecodedBytes"] as? Int,
              let maxEncoded = link["maxEncodedCharacters"] as? Int,
              let maxURL = link["maxUrlBytes"] as? Int else { fail("MANIFEST.json appLink is missing") }
        check(link["scheme"] as? String == DrawingHandoff.scheme, "frozen scheme")
        check(link["host"] as? String == DrawingHandoff.host, "frozen host")
        check(link["path"] as? String == DrawingHandoff.path, "frozen path")
        check(link["parameter"] as? String == DrawingHandoff.parameter, "frozen query parameter")
        check(maxDecoded == DrawingHandoff.maxDecodedBytes, "frozen decoded limit")
        check(maxEncoded == DrawingHandoff.maxEncodedCharacters, "frozen encoded limit")
        check(maxURL == DrawingHandoff.maxURLBytes, "frozen URL limit")

        for (json, url) in [("link/valid/known-identity.json", "link/valid/known-identity.url"),
                            ("link/valid/minimal.json", "link/valid/minimal.url")] {
            let fixture = load(json)
            let wrapper = readyWrapper(identity: rawMember("drawingIdentity", in: fixture),
                drawingProtocol: rawMember("drawingProtocol", in: fixture),
                routes: rawMember("routes", in: fixture))
            guard case .present(let status) = DrawingHandoff.state(
                statusResponse: statusResponse(drawingHandoff: wrapper)),
                  let descriptor = status.descriptor else { fail("\(json) routes must validate") }
            guard let object = try? JSONSerialization.jsonObject(with: fixture) as? [String: Any],
                  let requestID = object["requestID"] as? String,
                  let displayName = object["displayName"] as? String,
                  let management = object["managementIdentity"] as? String else { fail("\(json) members") }
            guard let identity = hex(management) else { fail("\(json) managementIdentity") }
            guard let built = try? DrawingHandoff.link(descriptor: descriptor, displayName: displayName,
                managementIdentity: identity, requestID: requestID) else { fail("\(json) link") }
            // The .url and .json match semantically, not byte for byte: the
            // 4096-byte limit applies to the decoded compact payload.
            let expected = String(decoding: load(url), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            check(built.url.absoluteString == expected, "\(url) was not reproduced exactly")
            check(!built.url.absoluteString.contains("\r"), "no CR in an app link")
            if json.contains("known-identity") {
                check(built.payload.count == payloadBytes,
                    "canonical payload is \(payloadBytes) bytes, built \(built.payload.count)")
                check(expected.count == 28 + encodedCharacters, "canonical encoded length")
            }
            // Nothing outside the closed member set, in any encoding.
            guard let payload = try? JSONSerialization.jsonObject(with: built.payload) as? [String: Any] else {
                fail("built payload must be a JSON object")
            }
            check(Set(payload.keys) == ["version", "requestID", "displayName", "managementIdentity",
                                        "drawingIdentity", "drawingProtocol", "routes"],
                "the app link member set is closed")
            let text = String(decoding: built.payload, as: UTF8.self)
            for forbidden in ["relayKey", "privateKey", "clientKey", "password", "psk", "passphrase",
                              "pairingCode", "code", "token", "capture", "ssid", "bssid", "allowlist"] {
                check(!text.contains(forbidden), "an app link must never carry \(forbidden)")
            }
            check(built.payload.count <= DrawingHandoff.maxDecodedBytes, "decoded payload bound")
            let value = built.url.absoluteString.dropFirst("\(DrawingHandoff.scheme)://\(DrawingHandoff.host)\(DrawingHandoff.path)?\(DrawingHandoff.parameter)=".count)
            check(value.utf8.allSatisfy { ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a)
                || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d || $0 == 0x5f },
                "the d value is unpadded base64url with no percent escapes")
            check(value.count % 4 != 1, "no unpadded base64url length is 1 mod 4")
            check(DrawingHandoff.base64url(built.payload) == String(value), "canonical re-encoding")
        }

        // Setup mints a fresh requestID per tap. It is never copied out of a
        // relay response and it authorizes nothing.
        let fixture = load("link/valid/minimal.json")
        let wrapper = readyWrapper(identity: rawMember("drawingIdentity", in: fixture),
            drawingProtocol: rawMember("drawingProtocol", in: fixture),
            routes: rawMember("routes", in: fixture))
        guard case .present(let status) = DrawingHandoff.state(
            statusResponse: statusResponse(drawingHandoff: wrapper)),
              let descriptor = status.descriptor else { fail("minimal routes must validate") }
        guard let management = hex(String(repeating: "ab", count: 32)) else { fail("test identity") }
        guard let first = try? DrawingHandoff.link(descriptor: descriptor, displayName: "Relay",
                  managementIdentity: management),
              let second = try? DrawingHandoff.link(descriptor: descriptor, displayName: "Relay",
                  managementIdentity: management) else { fail("minted link") }
        check(first.requestID != second.requestID, "each tap mints a fresh requestID")
        check(DrawingHandoff.isRequestID(first.requestID), "a minted requestID is lowercase canonical")
        // Identities never substitute for one another.
        guard let collision = hex(descriptor.drawingIdentity) else { fail("hex") }
        do {
            _ = try DrawingHandoff.link(descriptor: descriptor, displayName: "Relay",
                managementIdentity: collision)
            fail("a management identity equal to the drawing identity must be refused")
        } catch let failure as DrawingHandoffReject {
            check(failure.identifier == "drawingIdentity.collidesWithManagement",
                "collision identifier, got \(failure.identifier)")
        } catch { fail("unexpected link error") }
        // Display name is display only, bounded, and never empty.
        check(DrawingHandoff.displayName("") == "Relay", "an empty hostname falls back")
        check(DrawingHandoff.displayName("   ") == "Relay", "a blank hostname falls back")
        check(DrawingHandoff.displayName("studio\u{7f}relay") == "studiorelay", "delete is stripped")
        check(DrawingHandoff.displayName(String(repeating: "r", count: 200)).utf8.count == 64, "bounded to 64 bytes")
        check(DrawingHandoff.isDisplayName(DrawingHandoff.displayName(String(repeating: "é", count: 200))),
            "multi-byte truncation stays valid")
        print("  app link construction: pinned")
    }

    static func hex(_ value: String) -> Data? {
        let characters = Array(value.utf8)
        guard characters.count == 64 else { return nil }
        var bytes = [UInt8]()
        for offset in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: characters[offset..<offset + 2], as: UTF8.self), radix: 16)
            else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    /// The action policy. Deliberately independent of RelayTestTransport: the
    /// bluetoothOnly selector is a management-side qualification control and is
    /// not, and must never be relabelled as, the PLANK drawing transport.
    static func actionPolicy() {
        let fixture = load("status/valid/ready.json")
        guard case .handoffReady(let descriptor) = DrawingHandoff.outcome(
            statusResponse: statusResponse(drawingHandoff: fixture), headsetAuthorized: true) else {
            fail("ready outcome")
        }
        let idle = DrawingHandoffAction(outcome: .handoffReady(descriptor), activity: .paired, busy: false)
        check(idle.available && idle.reason == nil, "a ready descriptor offers Use in PLANK")
        check(!idle.mustStopTabletTest, "nothing to stop when no test is running")
        check(idle.routes.count == descriptor.routes.count, "the offered routes are the descriptor's")
        check(idle.routes.allSatisfy { !$0.label.contains("Bluetooth") },
            "a drawing route is never labelled as the Bluetooth management rendezvous")
        for activity in [SetupActivity.observing, .stoppingObservation] {
            let testing = DrawingHandoffAction(outcome: .handoffReady(descriptor), activity: activity, busy: true)
            check(testing.mustStopTabletTest, "\(activity) must stop and release the tablet test first")
            check(testing.available, "the handoff stays offered while a test is being released")
        }
        let managing = DrawingHandoffAction(outcome: .handoffReady(descriptor),
            activity: .managingTablets, busy: true)
        check(!managing.available, "another relay operation blocks the handoff")
        for reason in DrawingHandoffReason.unavailable.union(DrawingHandoffReason.unsupported) {
            let outcome: DrawingHandoffOutcome = DrawingHandoffReason.unavailable.contains(reason)
                ? .drawingUnavailable(reason) : .handoffUnsupported(reason)
            let action = DrawingHandoffAction(outcome: outcome, activity: .paired, busy: false)
            check(!action.available, "\(reason) must not offer a handoff")
            check(action.reason == reason, "\(reason) is shown as itself")
            check(action.routes.isEmpty, "\(reason) offers no address for Setup to type on PLANK's behalf")
            check(action.message != DrawingHandoffReason.guidance("relay.tooOld")
                || reason == "relay.tooOld", "\(reason) has its own specific guidance")
            if DrawingHandoffReason.unavailable.contains(reason) {
                check(!action.message.lowercased().contains("authoriz"),
                    "\(reason) must never be reported as an authorization problem")
            }
        }
        let unknown = DrawingHandoffAction(outcome: nil, activity: .paired, busy: false)
        check(!unknown.available && unknown.reason == "authorization.required",
            "without a confirmed authorization there is no handoff")
        print("  action policy: pinned")
    }

    /// The release the handoff waits on. A running tablet test owns capture, so
    /// the relay stays reserved from the stop request until the observation task
    /// has finished tearing the transport down, and only then may a link open.
    static func releaseTransition() {
        let ready = load("status/valid/ready.json")
        guard case .handoffReady(let descriptor) = DrawingHandoff.outcome(
            statusResponse: statusResponse(drawingHandoff: ready), headsetAuthorized: true) else {
            fail("ready outcome")
        }
        func action(_ state: SetupState) -> DrawingHandoffAction {
            DrawingHandoffAction(outcome: .handoffReady(descriptor), activity: state.activity, busy: state.busy)
        }
        var state = SetupState()
        state.selectRelay(RelayAddress(bluetoothIdentifier: UUID(), name: "test-relay"), trusted: true)
        guard let checking = state.beginCheck() else { fail("a trusted relay can be checked") }
        state.updateTabletAvailability(true, operation: checking)
        state.cancel()
        guard let observation = state.beginObservation() else { fail("an available tablet can be observed") }
        check(state.activity == .observing && state.busy, "a running test reserves the relay")
        check(action(state).mustStopTabletTest, "a running test must be stopped first")
        check(action(state).available, "the handoff stays offered while the test is released")
        check(state.stopObservation(), "stopping keeps the reservation until teardown finishes")
        check(state.activity == .stoppingObservation && state.busy, "the relay stays reserved")
        check(action(state).mustStopTabletTest, "a stopping test is still being released")
        check(state.finishObservation(observation), "the observation task releases the reservation")
        check(!state.busy && state.activity == .paired, "release leaves the relay idle and trusted")
        check(!action(state).mustStopTabletTest && action(state).available,
            "only after release does the handoff open with nothing reserved")
        check(!state.connectionVerified, "a released test claims no verified connection")
        print("  tablet test release transition: pinned")
    }

    /// Coordinator behaviour: a failed PLANK launch retains no capture, resets
    /// no pairing and leaves the ready outcome standing.
    @MainActor static var opened: [URL] = []

    @MainActor static func coordinator() async {
        guard let identities = manifest["syntheticIdentities"] as? [String: Any],
              let values = identities["values"] as? [String: Any],
              let management = values["management"] as? [String: Any],
              let managementHex = management["sha256"] as? String else { fail("MANIFEST.json identities") }
        guard let managementKey = hex(managementHex) else { fail("management identity") }
        let response = statusResponse(drawingHandoff: load("status/valid/ready.json"),
            headsetAuthorized: true, relayKey: managementHex)
        guard let status = try? TabletSetupStatus.decode(response, request: 3) else {
            fail("the spliced status must decode through the tolerant envelope")
        }
        check(status.enrollmentIdentity == managementKey, "enrollment identity")
        guard case .handoffReady(let descriptor) = status.drawingHandoff else {
            fail("a decoded status carries its own validated handoff outcome")
        }
        let setup = SetupCoordinator()
        check(!setup.handoffAction.available, "a fresh coordinator offers nothing")
        // Without the saved relay key the management identity is unconfirmed.
        setup.acceptTabletStatus(status, relayKey: nil)
        check(!setup.handoffAction.available, "an unconfirmed management identity offers no handoff")
        check(setup.handoffAction.reason == "authorization.required", "unconfirmed reason")
        setup.acceptTabletStatus(status, relayKey: managementKey)
        check(setup.handoffAction.available, "a confirmed ready status offers Use in PLANK")

        let trusted = setup.state.hasTrust
        opened = []
        await setup.useInPLANK { url in
            Self.opened.append(url)
            return false
        }
        check(opened.count == 1, "exactly one launch attempt")
        check(opened[0].absoluteString.hasPrefix(
            "\(DrawingHandoff.scheme)://\(DrawingHandoff.host)\(DrawingHandoff.path)?\(DrawingHandoff.parameter)="),
            "the launch used the registered app link")
        guard let fallback = setup.handoffFallback else { fail("a failed launch must explain itself") }
        // Relays are added to PLANK only through Use in PLANK, so a failed
        // launch never invites manual address entry in PLANK.
        for route in descriptor.routes {
            check(!fallback.contains(route.endpoint), "the fallback offers no manual address")
        }
        check(fallback.contains("Use in PLANK"), "the fallback names the retry action")
        check(!fallback.contains(managementHex), "a fallback never shows an identity")
        guard case .handoffReady = setup.tabletStatus?.drawingHandoff else {
            fail("a failed launch leaves handoffReady unchanged")
        }
        check(setup.handoffAction.available, "the user can simply try again")
        check(setup.state.hasTrust == trusted, "a failed launch resets no pairing")
        check(setup.state.activity == .idle && !setup.state.busy, "a failed launch reserves nothing")
        check(setup.tabletTest.count == 0 && setup.tabletTest.latest == nil,
            "a failed launch retains no capture")

        await setup.useInPLANK { _ in true }
        check(setup.handoffFallback == nil, "a successful launch clears the fallback")
        check(setup.message.contains("PLANK"), "a successful launch says what happened")
        // A later status without a confirmed identity withdraws the offer, and
        // clearing the status withdraws it too.
        setup.clearTabletStatus()
        check(!setup.handoffAction.available && setup.handoffFallback == nil, "cleared status offers nothing")
        print("  coordinator launch and release path: pinned")
    }

    // MARK: Entry

    @MainActor static func main() async throws {
        let manifestData = manifestBytes()
        check(digest(manifestData) == manifestSHA256,
            "MANIFEST.json SHA-256 is \(digest(manifestData)); the contract revision changed")
        guard let object = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            fail("MANIFEST.json must be a JSON object")
        }
        manifest = object
        guard let listed = object["files"] as? [String: [String: Any]] else { fail("MANIFEST.json files") }
        files = listed
        check(object["revision"] as? String == contractRevision, "contract revision changed")
        guard let contract = object["contract"] as? [String: Any] else { fail("MANIFEST.json contract") }
        check(contract["sha256"] as? String == contractSHA256, "contract SHA-256 changed")
        print("plank-drawing-handoff-v1 fixtures: \(contractRevision), \(files.count) files")

        statusFixtures()
        forbiddenStatusMembers()
        duplicateMembers()
        sharedFieldRules()
        outcomes()
        appLink()
        actionPolicy()
        releaseTransition()
        await coordinator()
        print("PASS: status descriptor entry point, three outcomes, app link and Use in PLANK gating")
    }

    static func manifestBytes() -> Data {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("MANIFEST.json")) else {
            fail("MANIFEST.json could not be read from \(directory.path)")
        }
        return data
    }
}
