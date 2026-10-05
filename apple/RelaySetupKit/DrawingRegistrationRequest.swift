// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Shared byte-for-byte with PLANK Client. These app links contain only public
// keys, a request identifier and the unchanged v1 handoff. No URL grants trust.
public struct DrawingRegistrationRequest: Equatable, Sendable {
    public let requestID: String
    public let clientIdentity: String
    public let handoff: String

    public init(requestID: String, clientIdentity: String, handoff: String) throws {
        guard Self.hex(requestID, count: 32), Self.hex(clientIdentity, count: 64),
              !requestID.allSatisfy({ $0 == "0" }), !clientIdentity.allSatisfy({ $0 == "0" }),
              !handoff.isEmpty, handoff.utf8.count <= 5462,
              handoff.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }), handoff.count % 4 != 1 else {
            throw DrawingRegistrationError.invalidRequest
        }
        self.requestID = requestID; self.clientIdentity = clientIdentity; self.handoff = handoff
    }
    public static func parse(_ url: URL, reply: Bool = false) throws -> Self {
        let text = url.absoluteString
        let prefix = reply ? "plank-vision://enrollment/v1?" : "plank-relay-setup://enroll/v1?"
        guard text.utf8.count <= 6000, text.hasPrefix(prefix) else { throw DrawingRegistrationError.invalidRequest }
        let fields = text.dropFirst(prefix.count).split(separator: "&", omittingEmptySubsequences: false)
        guard fields.count == 3 else { throw DrawingRegistrationError.invalidRequest }
        var values: [String:String] = [:]
        for field in fields {
            let pair = field.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, values[String(pair[0])] == nil else { throw DrawingRegistrationError.invalidRequest }
            values[String(pair[0])] = String(pair[1])
        }
        guard let id = values["requestID"], let identity = values["clientIdentity"],
              let handoff = values["handoff"] else { throw DrawingRegistrationError.invalidRequest }
        return try Self(requestID: id, clientIdentity: identity, handoff: handoff)
    }
    public var handoffURL: URL {
        var text = handoff.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        let object = Data(base64Encoded: text).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let version = (object?["version"] as? Int) == 2 ? 2 : 1
        // This only selects a URL path; the original bytes still undergo strict
        // version, duplicate-member, identity and route validation afterwards.
        return URL(string: "plank-vision://handoff/v\(version)?d=\(handoff)")!
    }
    public func url(reply: Bool = false) -> URL {
        let prefix = reply ? "plank-vision://enrollment/v1" : "plank-relay-setup://enroll/v1"
        return URL(string: "\(prefix)?requestID=\(requestID)&clientIdentity=\(clientIdentity)&handoff=\(handoff)")!
    }
    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
public enum DrawingRegistrationError: Error, LocalizedError {
    case invalidRequest, wrongRelay, expired
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The PLANK registration request is invalid. Nothing was approved."
        case .wrongRelay: "Select and authorize the requested Relay in Setup before registering it with PLANK."
        case .expired: "Registration expired or was canceled. Start again from Use in PLANK."
        }
    }
}
