// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

// Identical source in Setup and Client. Public receipts only: the protected
// access group authenticates the app-to-app approval, which an app URL cannot.
// Private identity keys keep their original, app-local Keychain services.
@MainActor
public enum DrawingRegistrationReceipt {
    private static let service = "la.instinctual.PLANK.DrawingRegistration"
    struct Record: Codable {
        let version: Int
        let requestID: String, clientIdentity: String, handoff: String
        let expires: Date
        var approved: Bool
        func matches(_ request: DrawingRegistrationRequest, approved expected: Bool, now: Date = Date()) -> Bool {
            version == 1 && requestID == request.requestID && clientIdentity == request.clientIdentity &&
                handoff == request.handoff && approved == expected && expires > now && expires <= now.addingTimeInterval(125)
        }
    }
    private static func query(_ request: DrawingRegistrationRequest) throws -> [String:Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PLANKRegistrationAccessGroup") as? String,
              group.hasSuffix(".la.instinctual.PLANK.DrawingRegistration"), !group.contains("$") else {
            throw DrawingRegistrationError.invalidRequest
        }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccessGroup as String: group, kSecAttrAccount as String: request.requestID]
    }
    private static func read(_ request: DrawingRegistrationRequest, approved: Bool) throws -> Record {
        var q = try query(request); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count <= 8192,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.matches(request, approved: approved) else {
            throw DrawingRegistrationError.expired
        }
        return record
    }
    public static func create(_ request: DrawingRegistrationRequest) throws {
        let record = Record(version: 1, requestID: request.requestID, clientIdentity: request.clientIdentity,
            handoff: request.handoff, expires: Date().addingTimeInterval(120), approved: false)
        var q = try query(request)
        q[kSecValueData as String] = try JSONEncoder().encode(record)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
            throw DrawingRegistrationError.invalidRequest
        }
    }
    public static func requirePending(_ request: DrawingRegistrationRequest) throws {
        _ = try read(request, approved: false)
    }
    public static func approve(_ request: DrawingRegistrationRequest) throws {
        var record = try read(request, approved: false)
        record.approved = true
        let update = [kSecValueData as String: try JSONEncoder().encode(record)]
        guard SecItemUpdate(try query(request) as CFDictionary, update as CFDictionary) == errSecSuccess else {
            throw DrawingRegistrationError.expired
        }
    }
    public static func requireApproved(_ request: DrawingRegistrationRequest) throws {
        _ = try read(request, approved: true)
    }
    public static func remove(_ request: DrawingRegistrationRequest) {
        if let query = try? query(request) { SecItemDelete(query as CFDictionary) }
    }
}
