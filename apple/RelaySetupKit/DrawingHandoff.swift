// SPDX-License-Identifier: GPL-3.0-or-later
//
// plank-drawing-handoff-v1+r3.
// Contract: docs/relay-drawing-handoff-contract.md in cnoellert/plank-tablet-relay,
// SHA-256 1dce3dd079e26bc9d348d3fbea96e035c743e8ace390171862226c9a043545fc.
// Fixtures: tests/fixtures/plank-drawing-handoff-v1, MANIFEST.json SHA-256
// dd1125d8257f11431671fe116335c4e3c798c157207bdd576f3c44e724e95954.
//
// Two entry points live here.
//
// Entry point 2 (contract §4, §7.3): the optional `drawingHandoff` subtree
// inside the authenticated tablet-setup status. This subtree is STRICT even
// though the surrounding TabletSetupStatus decoder is deliberately tolerant
// (§7.8): member-name sets are compared against the frozen sets and any
// unknown member is a rejection, so it is NOT a plain `Decodable`. A status
// descriptor neither requires nor accepts `requestID`, `displayName` or
// `managementIdentity`; `version` is resolved fully — missing, then type, then
// value — before the member-set check; and duplicate member names are found by
// scanning the ORIGINAL response bytes, because a tolerant dictionary decode
// collapses duplicates before anything can observe them.
//
// Entry point 3 (contract §6): the app link Setup hands to PLANK. Public
// metadata only. No private key, pairing code, Wi-Fi password or Host
// credential may ever appear in it (§10.8); the closed seven-member set is what
// makes that checkable.
//
// Nothing here is a drawing transport and nothing here is enrollment authority.
// A route is a hint PLANK must prove with its own handshake against its own
// saved pin (§10.2, §10.4).
import Foundation
import Network

/// The first failing ordered check, named with the contract's identifier.
struct DrawingHandoffReject: Error, Equatable, Sendable {
    let identifier: String
}

private func reject(_ identifier: String) -> DrawingHandoffReject {
    DrawingHandoffReject(identifier: identifier)
}

/// Advisory, display-only interface metadata (contract §7.7). It MUST NOT
/// influence acceptance, ordering, preference, retry policy, trust or storage.
public struct DrawingRoute: Equatable, Sendable {
    public let address: String
    public let port: UInt16
    public let interface: String?
    public let kind: String?

    public var endpoint: String { "\(address) port \(port)" }

    /// Never infers Wi-Fi from the fact that the headset itself uses Wi-Fi.
    public var label: String {
        switch (interface, kind) {
        case let (name?, kind?): "\(name) · \(Self.title(kind))"
        case let (name?, nil): name
        case let (nil, kind?): Self.title(kind)
        default: "Network"
        }
    }

    private static func title(_ kind: String) -> String {
        switch kind {
        case "wired": "Wired"
        case "wireless": "Wireless"
        default: "Other"
        }
    }
}

/// Every member is frozen by contract §5.2. `linkType` is 2 (TCP); 1 is
/// Bluetooth LE and is refused, because version 1 adds no Bluetooth drawing
/// transport and the link type is bound into the Noise prologue.
public struct DrawingProtocolDescriptor: Equatable, Sendable {
    public static let name = "pltr-raw-hid"
    public static let version = 1
    public static let rawHID = 1
    public static let linkType = 2

    public let name: String
    public let version: Int
    public let rawHID: Int
    public let linkType: Int
}

/// Exactly the four members a managed status descriptor carries (contract §4).
public struct DrawingDescriptor: Equatable, Sendable {
    public let version: Int
    public let drawingIdentity: String
    public let drawingProtocol: DrawingProtocolDescriptor
    public let routes: [DrawingRoute]
}

public struct DrawingHandoffStatus: Equatable, Sendable {
    public let supported: Bool
    public let descriptor: DrawingDescriptor?
    public let reason: String?
}

/// What the `drawingHandoff` subtree itself said, before it is classified.
public enum DrawingHandoffState: Equatable, Sendable {
    /// The relay did not report the member at all.
    case absent
    case present(DrawingHandoffStatus)
    /// First failing ordered check of contract §7.3.
    case rejected(String)
}

/// The three distinguishable outcomes of contract §11. They are kept apart so
/// a missing drawing service is never reported as an authorization problem,
/// and an authorization problem is never reported as a missing service.
public enum DrawingHandoffOutcome: Equatable, Sendable {
    case handoffReady(DrawingDescriptor)
    case drawingUnavailable(String)
    case handoffUnsupported(String)

    public var reason: String? {
        switch self {
        case .handoffReady: nil
        case let .drawingUnavailable(reason), let .handoffUnsupported(reason): reason
        }
    }

    public var descriptor: DrawingDescriptor? {
        guard case let .handoffReady(descriptor) = self else { return nil }
        return descriptor
    }
}

public enum DrawingHandoffReason {
    /// The relay answered, but the drawing service is missing or not ready.
    public static let unavailable: Set<String> = ["service.absent", "service.busy", "service.invalid",
        "service.peerUnverified", "listener.loopbackOnly", "listener.noUsableAddress", "response.tooLarge"]
    /// Authorization or protocol error, or a relay too old to report the field.
    public static let unsupported: Set<String> = ["relay.tooOld", "authorization.required",
        "authorization.failed", "protocol.error"]

    public static func guidance(_ reason: String) -> String {
        switch reason {
        case "service.absent":
            "The relay is not running its drawing service. Update or restart the relay package, then check again."
        case "service.busy":
            "The relay’s drawing service is busy answering another request. Check again in a moment."
        case "service.invalid":
            "The relay’s drawing service returned an answer this app will not use. Restart the relay package, then check again."
        case "service.peerUnverified":
            "Something other than the relay’s drawing service answered on the relay. Nothing was handed off. Check the relay before trying again."
        case "listener.loopbackOnly":
            "The relay’s drawing service is listening only on the relay itself. Give it the relay’s network address, then check again."
        case "listener.noUsableAddress":
            "The relay has no usable network address for drawing yet. Connect the relay to your network, then check again."
        case "response.tooLarge":
            "The relay’s drawing answer was too large to accept. Update the relay package."
        case "relay.tooOld":
            "This relay does not report a drawing endpoint yet. Update the relay package to hand off to PLANK."
        case "authorization.required":
            "Finish tablet setup so the relay authorizes this headset, then hand off to PLANK."
        case "authorization.failed":
            "The relay did not accept this headset’s authorization. Check headset authorization, then try again."
        case "protocol.error":
            "The relay’s drawing answer could not be validated, so nothing was handed off. Update the relay package, then check again."
        default:
            "The relay cannot hand off a drawing connection right now."
        }
    }
}

/// What Setup may offer, derived only from the status outcome and the current
/// activity. Deliberately independent of RelayTestTransport: that selector is a
/// management-side qualification control, not the PLANK drawing transport.
public struct DrawingHandoffAction: Equatable, Sendable {
    public static let title = "Use in PLANK"

    public let available: Bool
    public let reason: String?
    public let message: String
    /// A running tablet test owns capture. Stop and release it before offering
    /// the handoff; never hand off while readings are open.
    public let mustStopTabletTest: Bool
    public let routes: [DrawingRoute]

    public init(outcome: DrawingHandoffOutcome?, activity: SetupActivity, busy: Bool) {
        let testing = activity == .observing || activity == .stoppingObservation
        mustStopTabletTest = testing
        switch outcome {
        case let .handoffReady(descriptor):
            available = !busy || testing
            reason = nil
            routes = descriptor.routes
            message = available
                ? "PLANK will open already knowing this relay. Its drawing connection is proved separately in PLANK."
                : "Stop the current relay operation to hand this relay off to PLANK."
        case let .drawingUnavailable(value), let .handoffUnsupported(value):
            available = false
            reason = value
            routes = []
            message = DrawingHandoffReason.guidance(value)
        case nil:
            available = false
            reason = "authorization.required"
            routes = []
            message = DrawingHandoffReason.guidance("authorization.required")
        }
    }
}

/// The app link, built to contract §6 and ready to open.
public struct DrawingHandoffLink: Equatable, Sendable {
    public let url: URL
    public let requestID: String
    /// Compact UTF-8 JSON, 2 to 4096 bytes.
    public let payload: Data
}

public enum DrawingHandoff {
    public static let scheme = "plank-vision"
    public static let host = "handoff"
    public static let path = "/v1"
    public static let parameter = "d"
    static let maxDecodedBytes = 4096
    static let maxEncodedCharacters = 5462
    static let maxURLBytes = 5490

    // MARK: Entry point 2

    /// Validates the `drawingHandoff` subtree of an authenticated status in the
    /// ordered checks of contract §7.3, reporting the FIRST failing identifier.
    ///
    /// `statusResponse` must be the ORIGINAL response bytes. The duplicate
    /// member scan is impossible after a tolerant envelope decode, which
    /// collapses duplicate names before anything can observe them.
    public static func state(statusResponse data: Data) -> DrawingHandoffState {
        var scanner = HandoffScanner(data)
        let subtree: HandoffJSON?
        do { subtree = try scanner.locateDrawingHandoff() } catch { return .rejected("payload.json") }
        guard let subtree else { return .absent }
        do { return .present(try wrapper(subtree, duplicate: scanner.duplicate)) }
        catch let failure as DrawingHandoffReject { return .rejected(failure.identifier) }
        catch { return .rejected("protocol.error") }
    }

    /// Classifies a status into the three outcomes of contract §11.
    ///
    /// Authorization is resolved before the member's presence: an unauthorized
    /// headset cannot be told the relay is too old, and a relay that simply
    /// does not report the member is never called an authorization failure.
    public static func outcome(statusResponse data: Data, headsetAuthorized: Bool?) -> DrawingHandoffOutcome {
        guard headsetAuthorized == true else { return .handoffUnsupported("authorization.required") }
        switch state(statusResponse: data) {
        case .absent: return .handoffUnsupported("relay.tooOld")
        case .rejected: return .handoffUnsupported("protocol.error")
        case let .present(status):
            if let reason = status.reason {
                return DrawingHandoffReason.unavailable.contains(reason)
                    ? .drawingUnavailable(reason) : .handoffUnsupported(reason)
            }
            guard status.supported, let descriptor = status.descriptor else {
                return .handoffUnsupported("relay.tooOld")
            }
            return .handoffReady(descriptor)
        }
    }

    private static func wrapper(_ value: HandoffJSON, duplicate: Bool) throws -> DrawingHandoffStatus {
        // 1. The subtree is an object, before anything inside it is examined.
        guard case let .object(members) = value else { throw reject("payload.notObject") }
        // 2. Duplicate member names, found in the original bytes.
        guard !duplicate else { throw reject("payload.duplicateMember") }
        // 3. The wrapper member set is frozen.
        let allowed = ["supported", "state", "descriptor", "reason"]
        for (name, _) in members where !allowed.contains(name) { throw reject("status.unknownMember") }
        // 4. supported.
        guard let supportedValue = member("supported", members) else { throw reject("status.supported.missing") }
        guard case let .bool(supported) = supportedValue else { throw reject("status.supported.type") }
        // 5. state.
        guard let stateValue = member("state", members) else { throw reject("status.state.missing") }
        guard case let .string(state) = stateValue, state == "ready" || state == "unavailable" else {
            throw reject("status.state")
        }
        // 6. Exactly one of descriptor and reason, matching state.
        let descriptorValue = member("descriptor", members)
        let reasonValue = member("reason", members)
        if state == "ready" {
            guard descriptorValue != nil else { throw reject("status.descriptor.missing") }
            guard reasonValue == nil else { throw reject("status.reason.unexpected") }
        } else {
            guard descriptorValue == nil else { throw reject("status.descriptor.unexpected") }
            guard reasonValue != nil else { throw reject("status.reason.missing") }
        }
        // 7. An unavailable status carries a frozen reason and stops here.
        if state == "unavailable" {
            guard case let .string(reason)? = reasonValue,
                  DrawingHandoffReason.unavailable.contains(reason)
                      || DrawingHandoffReason.unsupported.contains(reason) else { throw reject("status.reason") }
            return DrawingHandoffStatus(supported: supported, descriptor: nil, reason: reason)
        }
        return DrawingHandoffStatus(supported: supported,
            descriptor: try descriptor(descriptorValue!), reason: nil)
    }

    private static func descriptor(_ value: HandoffJSON) throws -> DrawingDescriptor {
        // 8. descriptor is an object, checked before any member-level reason.
        guard case let .object(members) = value else { throw reject("status.descriptor.type") }
        // 9. version is privileged: presence, then type, then value.
        try version(members)
        // 10. The descriptor member set is exactly four names. requestID,
        // displayName and managementIdentity are forbidden here, and are never
        // required of a status descriptor.
        let allowed = ["version", "drawingIdentity", "drawingProtocol", "routes"]
        for (name, _) in members where !allowed.contains(name) { throw reject("status.unknownMember") }
        // 11. Required members, in table order.
        guard let identityValue = member("drawingIdentity", members) else { throw reject("drawingIdentity.missing") }
        guard let protocolValue = member("drawingProtocol", members) else { throw reject("drawingProtocol.missing") }
        guard let routesValue = member("routes", members) else { throw reject("routes.missing") }
        // 12. Field checks, in table order.
        return DrawingDescriptor(version: DrawingProtocolDescriptor.version,
            drawingIdentity: try identity(identityValue, member: "drawingIdentity"),
            drawingProtocol: try protocolDescriptor(protocolValue),
            routes: try routes(routesValue))
    }

    private static func version(_ members: [(String, HandoffJSON)]) throws {
        guard let value = member("version", members) else { throw reject("version.missing") }
        guard let number = integer(value) else { throw reject("version.type") }
        guard number == DrawingProtocolDescriptor.version else { throw reject("version.unsupported") }
    }

    /// Contract §5.1: exactly 64 lowercase hexadecimal characters.
    static func identity(_ value: HandoffJSON, member name: String) throws -> String {
        guard case let .string(text) = value else { throw reject("\(name).type") }
        let utf8 = Array(text.utf8)
        guard utf8.count == 64, utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
        else { throw reject("\(name).invalid") }
        return text
    }

    /// Contract §5.2.
    static func protocolDescriptor(_ value: HandoffJSON) throws -> DrawingProtocolDescriptor {
        guard case let .object(members) = value else { throw reject("drawingProtocol.type") }
        let allowed = ["name", "version", "rawHID", "linkType"]
        for (name, _) in members where !allowed.contains(name) { throw reject("drawingProtocol.unknownMember") }
        for name in allowed where member(name, members) == nil { throw reject("drawingProtocol.\(name).missing") }
        guard case let .string(name)? = member("name", members),
              name == DrawingProtocolDescriptor.name else { throw reject("drawingProtocol.name") }
        guard integer(member("version", members)) == DrawingProtocolDescriptor.version else {
            throw reject("drawingProtocol.version")
        }
        guard integer(member("rawHID", members)) == DrawingProtocolDescriptor.rawHID else {
            throw reject("drawingProtocol.rawHID")
        }
        guard integer(member("linkType", members)) == DrawingProtocolDescriptor.linkType else {
            throw reject("drawingProtocol.linkType")
        }
        return DrawingProtocolDescriptor(name: name, version: DrawingProtocolDescriptor.version,
            rawHID: DrawingProtocolDescriptor.rawHID, linkType: DrawingProtocolDescriptor.linkType)
    }

    /// Contract §5.3 and §7.6. A route that fails validation rejects the whole
    /// descriptor; it is never silently dropped.
    static func routes(_ value: HandoffJSON) throws -> [DrawingRoute] {
        guard case let .array(elements) = value else { throw reject("routes.type") }
        // Element count is checked before contents.
        guard (1...8).contains(elements.count) else { throw reject("routes.count") }
        var validated: [DrawingRoute] = []
        for element in elements { validated.append(try route(element)) }
        // Identical address and port deduplicate after every per-route check.
        var unique: [DrawingRoute] = []
        for candidate in validated
        where !unique.contains(where: { $0.address == candidate.address && $0.port == candidate.port }) {
            unique.append(candidate)
        }
        guard !unique.isEmpty else { throw reject("routes.count") }
        return unique
    }

    private static func route(_ value: HandoffJSON) throws -> DrawingRoute {
        guard case let .object(members) = value else { throw reject("route.type") }
        let allowed = ["address", "port", "interface", "kind"]
        for (name, _) in members where !allowed.contains(name) { throw reject("route.unknownMember") }
        // Absence is expressed by absence; JSON null is never an optional value.
        for (name, item) in members where name == "interface" || name == "kind" {
            if case .null = item { throw reject("route.nullMember") }
        }
        guard let addressValue = member("address", members) else { throw reject("route.address.missing") }
        let address = try routeAddress(addressValue)
        guard let portValue = member("port", members) else { throw reject("route.port.missing") }
        guard let port = integer(portValue), (1...65535).contains(port) else { throw reject("route.port") }
        var interface: String?
        if let item = member("interface", members) {
            guard case let .string(text) = item, (1...15).contains(text.utf8.count),
                  text.utf8.allSatisfy(Self.interfaceByte) else { throw reject("route.interface") }
            interface = text
        }
        var kind: String?
        if let item = member("kind", members) {
            guard case let .string(text) = item,
                  ["wired", "wireless", "other"].contains(text) else { throw reject("route.kind") }
            kind = text
        }
        return DrawingRoute(address: address, port: UInt16(port), interface: interface, kind: kind)
    }

    private static func interfaceByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
            || (byte >= 0x30 && byte <= 0x39) || byte == 0x2e || byte == 0x5f || byte == 0x2d
    }

    private static func routeAddress(_ value: HandoffJSON) throws -> String {
        guard case let .string(text) = value else { throw reject("route.address.type") }
        guard text.utf8.count <= 64 else { throw reject("route.address.tooLong") }
        guard !text.contains("%") else { throw reject("route.address.scoped") }
        switch try literal(text, prefix: "route.address") {
        case let .v4(octets):
            // Wildcard and loopback are legal only in the raw listener
            // metadata of entry point 1. They can never reach a descriptor.
            if octets[0] == 0 { throw reject("route.address.unspecified") }
            if octets[0] == 127 { throw reject("route.address.loopback") }
            if octets[0] == 169 && octets[1] == 254 { throw reject("route.address.linkLocal") }
            if (224...239).contains(octets[0]) { throw reject("route.address.multicast") }
            if octets[0] >= 240 { throw reject("route.address.broadcast") }
            return text
        case let .v6(bytes):
            if bytes.allSatisfy({ $0 == 0 }) { throw reject("route.address.unspecified") }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { throw reject("route.address.loopback") }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { throw reject("route.address.linkLocal") }
            if bytes[0] == 0xff { throw reject("route.address.multicast") }
            // Version 1 has no IPv6 listener to connect to. The class refusals
            // run first so every refused class has one unambiguous reason.
            throw reject("route.address.familyUnsupported")
        }
    }

    private enum Literal { case v4([UInt8]); case v6([UInt8]) }

    /// Contract §7.4a. These checks are deterministic on the raw text and raw
    /// bytes, around the platform parser, because Python and Swift disagree on
    /// leading-zero IPv4 and on IPv4-mapped IPv6 rendering.
    private static func literal(_ text: String, prefix: String) throws -> Literal {
        let utf8 = Array(text.utf8)
        if !utf8.isEmpty && utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e }) {
            let groups = text.split(separator: ".", omittingEmptySubsequences: false)
            guard groups.count == 4 else { throw reject("\(prefix).notLiteral") }
            for group in groups {
                guard (1...3).contains(group.count), let value = Int(group), value <= 255 else {
                    throw reject("\(prefix).notLiteral")
                }
            }
            for group in groups where group.count > 1 && group.first == "0" {
                throw reject("\(prefix).nonCanonical")
            }
            // A text that passes this grammar is canonical by construction.
            return .v4(groups.map { UInt8(Int($0)!) })
        }
        guard text.contains(":") else { throw reject("\(prefix).notLiteral") }
        // A pure string test, so uppercase fails identically everywhere.
        guard !text.contains(where: { $0.isASCII && $0.isUppercase }) else {
            throw reject("\(prefix).nonCanonical")
        }
        guard let parsed = IPv6Address(text) else { throw reject("\(prefix).notLiteral") }
        let bytes = Array(parsed.rawValue)
        guard bytes.count == 16 else { throw reject("\(prefix).notLiteral") }
        // Byte tests, identical in every implementation, before the round trip:
        // a mapped address is refused whatever its textual form.
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            throw reject("\(prefix).mapped")
        }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            let tail = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            if tail > 1 { throw reject("\(prefix).mapped") }
        }
        guard parsed.debugDescription == text else { throw reject("\(prefix).nonCanonical") }
        return .v6(bytes)
    }

    private static func member(_ name: String, _ members: [(String, HandoffJSON)]) -> HandoffJSON? {
        members.first { $0.0 == name }?.1
    }

    private static func integer(_ value: HandoffJSON?) -> Int? {
        guard case let .number(text)? = value else { return nil }
        var digits = Substring(text)
        var negative = false
        if digits.first == "-" { negative = true; digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let magnitude = Int(digits) else { return nil }
        return negative ? -magnitude : magnitude
    }

    // MARK: Entry point 3

    /// Display only. Never used for trust, matching or a storage key.
    public static func displayName(_ hostname: String?) -> String {
        var text = ""
        for scalar in (hostname ?? "").unicodeScalars {
            guard scalar.value >= 0x20, scalar.value != 0x7f else { continue }
            let candidate = text + String(scalar)
            guard candidate.utf8.count <= 64 else { break }
            text = candidate
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Relay" : trimmed
    }

    /// Builds the app link of contract §6 from public metadata only.
    ///
    /// Setup mints `requestID` here, at the moment of the tap; it is never
    /// copied out of a relay response and is not an authorization token.
    /// `managementIdentity` is the identity Setup already holds as the relay's
    /// enrollment identity, and it never substitutes for a drawing identity.
    public static func link(descriptor: DrawingDescriptor, displayName name: String,
                            managementIdentity: Data,
                            requestID: String = UUID().uuidString.lowercased()) throws -> DrawingHandoffLink {
        guard isRequestID(requestID) else { throw reject("requestID.invalid") }
        guard isDisplayName(name) else { throw reject("displayName.invalid") }
        guard managementIdentity.count == 32 else { throw reject("managementIdentity.invalid") }
        let management = managementIdentity.map { String(format: "%02x", $0) }.joined()
        guard management != descriptor.drawingIdentity else {
            throw reject("drawingIdentity.collidesWithManagement")
        }
        var json = "{\"version\":\(DrawingProtocolDescriptor.version)"
        json += ",\"requestID\":\"\(requestID)\""
        json += ",\"displayName\":\(quoted(name))"
        json += ",\"managementIdentity\":\"\(management)\""
        json += ",\"drawingIdentity\":\"\(descriptor.drawingIdentity)\""
        json += ",\"drawingProtocol\":{\"name\":\"\(descriptor.drawingProtocol.name)\""
        json += ",\"version\":\(descriptor.drawingProtocol.version)"
        json += ",\"rawHID\":\(descriptor.drawingProtocol.rawHID)"
        json += ",\"linkType\":\(descriptor.drawingProtocol.linkType)}"
        json += ",\"routes\":["
        for (offset, route) in descriptor.routes.enumerated() {
            if offset > 0 { json += "," }
            json += "{\"address\":\"\(route.address)\",\"port\":\(route.port)"
            if let interface = route.interface { json += ",\"interface\":\(quoted(interface))" }
            if let kind = route.kind { json += ",\"kind\":\"\(kind)\"" }
            json += "}"
        }
        json += "]}"
        let payload = Data(json.utf8)
        guard (2...maxDecodedBytes).contains(payload.count) else { throw reject("payload.length") }
        let encoded = base64url(payload)
        guard (1...maxEncodedCharacters).contains(encoded.count),
              encoded.count % 4 != 1 else { throw reject("encoding.length") }
        let text = "\(scheme)://\(host)\(path)?\(parameter)=\(encoded)"
        guard text.utf8.count <= maxURLBytes else { throw reject("url.length") }
        guard let url = URL(string: text) else { throw reject("protocol.error") }
        return DrawingHandoffLink(url: url, requestID: requestID, payload: payload)
    }

    static func isRequestID(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { group in
            group.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
        }
    }

    static func isDisplayName(_ value: String) -> Bool {
        let utf8 = value.utf8.count
        guard (1...64).contains(utf8) else { return false }
        guard value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Canonical unpadded base64url by construction: the bytes are encoded
    /// here, never decoded from a caller's string, so no pad bits survive.
    static func base64url(_ data: Data) -> String {
        var text = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    private static func quoted(_ value: String) -> String {
        var text = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            default:
                if scalar.value < 0x20 {
                    text += String(format: "\\u%04x", scalar.value)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        return text + "\""
    }
}

// MARK: - Raw-byte JSON scan

/// A member-ordered JSON value. Members are kept as an ordered list, never a
/// dictionary, so duplicate names survive to be reported.
enum HandoffJSON {
    case object([(String, HandoffJSON)])
    case array([HandoffJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

struct HandoffScanError: Error {}

/// Scans the original response bytes. Duplicate member names are detected here,
/// at every depth inside the `drawingHandoff` subtree and after unescaping,
/// because `JSONSerialization` and `Decodable` both collapse them silently.
/// Members outside that subtree are skipped without duplicate tracking, so a
/// duplicate elsewhere in the tolerant status envelope is not this subtree's
/// rejection.
struct HandoffScanner {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private(set) var duplicate = false

    private static let maxDepth = 24

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func locateDrawingHandoff() throws -> HandoffJSON? {
        skipWhitespace()
        guard match(0x7b) else { throw HandoffScanError() }
        skipWhitespace()
        if match(0x7d) { return nil }
        var found: HandoffJSON?
        var count = 0
        while true {
            skipWhitespace()
            let name = try parseString()
            skipWhitespace()
            guard match(0x3a) else { throw HandoffScanError() }
            if name == "drawingHandoff" {
                count += 1
                found = try parseValue()
            } else {
                try skipValue()
            }
            skipWhitespace()
            if match(0x2c) { continue }
            guard match(0x7d) else { throw HandoffScanError() }
            break
        }
        if count > 1 { duplicate = true }
        return found
    }

    private mutating func parseValue() throws -> HandoffJSON {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw HandoffScanError() }
        skipWhitespace()
        guard index < bytes.count else { throw HandoffScanError() }
        switch bytes[index] {
        case 0x7b:
            index += 1
            var members: [(String, HandoffJSON)] = []
            var names = Set<String>()
            skipWhitespace()
            if match(0x7d) { return .object(members) }
            while true {
                skipWhitespace()
                let name = try parseString()
                if !names.insert(name).inserted { duplicate = true }
                skipWhitespace()
                guard match(0x3a) else { throw HandoffScanError() }
                members.append((name, try parseValue()))
                skipWhitespace()
                if match(0x2c) { continue }
                guard match(0x7d) else { throw HandoffScanError() }
                return .object(members)
            }
        case 0x5b:
            index += 1
            var elements: [HandoffJSON] = []
            skipWhitespace()
            if match(0x5d) { return .array(elements) }
            while true {
                elements.append(try parseValue())
                skipWhitespace()
                if match(0x2c) { continue }
                guard match(0x5d) else { throw HandoffScanError() }
                return .array(elements)
            }
        case 0x22: return .string(try parseString())
        case 0x74: try expect("true"); return .bool(true)
        case 0x66: try expect("false"); return .bool(false)
        case 0x6e: try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func skipValue() throws {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw HandoffScanError() }
        skipWhitespace()
        guard index < bytes.count else { throw HandoffScanError() }
        switch bytes[index] {
        case 0x7b, 0x5b:
            let object = bytes[index] == 0x7b
            let close: UInt8 = object ? 0x7d : 0x5d
            index += 1
            skipWhitespace()
            if match(close) { return }
            while true {
                if object {
                    skipWhitespace()
                    _ = try parseString()
                    skipWhitespace()
                    guard match(0x3a) else { throw HandoffScanError() }
                }
                try skipValue()
                skipWhitespace()
                if match(0x2c) { continue }
                guard match(close) else { throw HandoffScanError() }
                return
            }
        case 0x22: _ = try parseString()
        case 0x74: try expect("true")
        case 0x66: try expect("false")
        case 0x6e: try expect("null")
        default: _ = try parseNumber()
        }
    }

    private mutating func parseString() throws -> String {
        guard match(0x22) else { throw HandoffScanError() }
        var utf8: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 {
                guard let text = String(bytes: utf8, encoding: .utf8) else { throw HandoffScanError() }
                return text
            }
            guard byte == 0x5c else { utf8.append(byte); continue }
            guard index < bytes.count else { throw HandoffScanError() }
            let escape = bytes[index]
            index += 1
            switch escape {
            case 0x22, 0x5c, 0x2f: utf8.append(escape)
            case 0x62: utf8.append(0x08)
            case 0x66: utf8.append(0x0c)
            case 0x6e: utf8.append(0x0a)
            case 0x72: utf8.append(0x0d)
            case 0x74: utf8.append(0x09)
            case 0x75:
                var value = try hex4()
                if (0xd800...0xdbff).contains(value) {
                    guard index + 1 < bytes.count, bytes[index] == 0x5c, bytes[index + 1] == 0x75 else {
                        throw HandoffScanError()
                    }
                    index += 2
                    let low = try hex4()
                    guard (0xdc00...0xdfff).contains(low) else { throw HandoffScanError() }
                    value = 0x10000 + ((value - 0xd800) << 10) + (low - 0xdc00)
                } else if (0xdc00...0xdfff).contains(value) {
                    throw HandoffScanError()
                }
                guard let scalar = Unicode.Scalar(UInt32(value)) else { throw HandoffScanError() }
                utf8.append(contentsOf: Array(String(scalar).utf8))
            default: throw HandoffScanError()
            }
        }
        throw HandoffScanError()
    }

    private mutating func hex4() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            guard index < bytes.count, let digit = Self.hexDigit(bytes[index]) else { throw HandoffScanError() }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private static func hexDigit(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: Int(byte) - 0x30
        case 0x61...0x66: Int(byte) - 0x61 + 10
        case 0x41...0x46: Int(byte) - 0x41 + 10
        default: nil
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        while index < bytes.count, Self.numberByte(bytes[index]) { index += 1 }
        guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw HandoffScanError()
        }
        return text
    }

    private static func numberByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || byte == 0x2b || byte == 0x2d || byte == 0x2e
            || byte == 0x45 || byte == 0x65
    }

    private mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw HandoffScanError() }
            index += 1
        }
    }

    private mutating func match(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
            || bytes[index] == 0x0a || bytes[index] == 0x0d {
            index += 1
        }
    }
}
