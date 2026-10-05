// SPDX-License-Identifier: GPL-3.0-or-later
// Uses the same C CPace/Noise implementation as the relay. The session framing
// and Keychain approach follow cnoellert's Vision Pro prototype; see NOTICE.md.
import Foundation
import Security
@preconcurrency import Network
import CRelayProtocol

public struct ButtonApproval: Equatable, Sendable {
    public let tabletReady: Bool
    public let presses: Int
    public let secondsRemaining: Int
    public init(tabletReady: Bool, presses: Int, secondsRemaining: Int) {
        self.tabletReady = tabletReady
        self.presses = presses
        self.secondsRemaining = secondsRemaining
    }
}

public enum RelaySetupError: LocalizedError, Sendable {
    case invalidState, storage(OSStatus), invalidStoredKey, random, protocolError
    case network(String), timedOut, identityChanged, unexpectedMessage
    case approvalFailed, rejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidState: "Choose an available relay first."
        case .storage: "The app could not access its pairing keys in Keychain."
        case .invalidStoredKey: "The saved identity is invalid. It was not replaced."
        case .random: "The system could not generate secure random data."
        case .protocolError: "The relay exchange could not be verified. Try connecting again."
        case let .network(message): "Relay connection failed: \(message)"
        case let .rejected(message): message
        case .timedOut: "The relay did not complete the operation in time. You can try again."
        case .identityChanged: "This relay differs from the saved pairing. If you reinstalled or replaced it, choose Forget saved relay to set it up again."
        case .unexpectedMessage: "The relay sent an unsupported message. The connection closed; saved trust is retained."
        case .approvalFailed: "Tablet approval expired or could not be verified. Tap Pair to try again."
        }
    }
}

/// Separate namespace: test-app pairing never replaces the full Client's trust.
@MainActor
public final class RelayKeyStore {
    let service: String
    public convenience init() {
        self.init(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    // Updating the original app must keep both its access group and service.
    // The renamed release app remains a separate identity; do not search or
    // copy another app's keys when its own namespace has no saved approval.
    init(bundleIdentifier: String?) {
        service = bundleIdentifier == "la.instinctual.PLANK.TabletSetup"
            ? "la.instinctual.PLANK.TabletSetup.pairing.v1"
            : "la.instinctual.PLANK.AVPrelay.pairing.v1"
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RelaySetupError.storage(status) }
        guard let data = item as? Data, data.count == 32 else {
            throw RelaySetupError.invalidStoredKey
        }
        return data
    }

    private func add(_ data: Data, account: String) throws {
        guard data.count == 32 else { throw RelaySetupError.invalidStoredKey }
        var request = query(account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw RelaySetupError.storage(status) }
    }

    public func relayKey(_ address: RelayAddress) throws -> Data? {
        if let key = try read(address.keychainAccount) { return key }
        if let hint = address.advertisedKey, try trustedKeys().contains(hint) { return hint }
        return nil
    }

    // Includes existing BLE accounts so a TCP connection can verify the same
    // approved relay without enrolling the headset again. Pending pins excluded.
    func trustedKeys() throws -> Set<Data> {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw RelaySetupError.storage(status) }
        let items = result as? [[String: Any]] ?? []
        return Set(items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("relay-"), !account.hasSuffix(":setup"),
                  let key = item[kSecValueData as String] as? Data, key.count == 32 else { return nil }
            return key
        })
    }

    public func setupRelayKey(_ address: RelayAddress) throws -> Data? {
        try relayKey(address) ?? read(address.keychainAccount + ":setup")
    }

    public func rememberSetupRelay(_ key: Data, address: RelayAddress) throws {
        if let advertised = address.advertisedKey, advertised != key { throw RelaySetupError.identityChanged }
        if let existing = try setupRelayKey(address) {
            guard existing == key else { throw RelaySetupError.identityChanged }
        } else {
            try add(key, account: address.keychainAccount + ":setup")
        }
    }

    public func clientKey() throws -> Data {
        if let existing = try read("client-private-v1") { return existing }
        let key = try Self.randomBytes(count: 32)
        try add(key, account: "client-private-v1")
        return key
    }

    public func saveRelay(_ key: Data, address: RelayAddress) throws {
        if let advertised = address.advertisedKey, advertised != key { throw RelaySetupError.identityChanged }
        if let existing = try setupRelayKey(address), existing != key { throw RelaySetupError.identityChanged }
        let canonical = "relay-key-v2:" + key.map { String(format: "%02x", $0) }.joined()
        if try read(canonical) == nil { try add(key, account: canonical) }
        if let existing = try relayKey(address) {
            guard existing == key else { throw RelaySetupError.identityChanged }
            return
        }
        try add(key, account: address.keychainAccount)
    }

    public func forgetRelay(_ address: RelayAddress) throws {
        try forgetRelay([address])
    }

    public func forgetRelay(_ addresses: [RelayAddress]) throws {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelaySetupError.storage(status) }
        let records = (result as? [[String: Any]] ?? []).compactMap { item -> (String, Data)? in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return (account, data)
        }
        for account in Self.accountsToForget(records, addresses: addresses) {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw RelaySetupError.storage(status) }
        }
    }

    static func accountsToForget(_ records: [(String, Data)], addresses: [RelayAddress]) -> Set<String> {
        let selected = Set(addresses.flatMap { [$0.keychainAccount, $0.keychainAccount + ":setup"] })
        var keys = Set(records.compactMap { selected.contains($0.0) ? $0.1 : nil })
        for address in addresses {
            if let key = address.advertisedKey,
               records.contains(where: { $0.0.hasPrefix("relay-") && $0.1 == key }) { keys.insert(key) }
        }
        // Remove pending pins, canonical records and aliases of this relay.
        // Never delete the headset private key or another relay's identity.
        return selected.union(records.compactMap { account, key in
            account.hasPrefix("relay-") && keys.contains(key) ? account : nil
        })
    }

    public static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw RelaySetupError.random
        }
        return Data(bytes)
    }

}

@MainActor
protocol RelayByteConnection: AnyObject, Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    nonisolated func cancel()
    func finishDisconnect() async
}

@MainActor
public final class RelayPairingClient {
    var managementConnection: RelayManagementConnection?
    var managementScope = false
    var makeDiagnosticConnection: ((RelayAddress, @escaping (String) -> Void) -> any RelayByteConnection)?
    public init() {}

    func connection(_ address: RelayAddress, channel: RelayBLEChannel = .relay,
                    onProgress: ((String) -> Void)? = nil) -> any RelayByteConnection {
        if let host = address.networkHost, let port = address.networkPort {
            onProgress?("Connecting to your relay over Wi-Fi…")
            return RelayTCPConnection(endpoint: .hostPort(host: .init(host), port: .init(rawValue: port)!),
                channel: channel == .setup ? 1 : channel == .echo ? 2 : 0)
        }
        if let service = address.networkService, let domain = address.networkDomain {
            onProgress?("Connecting to your relay over the local network…")
            return RelayTCPConnection(endpoint: .service(name: service, type: "_plank-avp-relay._tcp", domain: domain, interface: nil),
                channel: channel == .setup ? 1 : channel == .echo ? 2 : 0)
        }
        return RelayBLEConnection(identifier: address.bluetoothIdentifier, channel: channel, onProgress: onProgress)
    }

    /// Tests only byte delivery over dedicated, unauthenticated echo channels.
    /// No pairing codec, Keychain access or tablet input is used or authorized.
    public func testConnection(address: RelayAddress, onProgress: @escaping (String) -> Void) async throws -> String {
        let socket = makeDiagnosticConnection?(address, onProgress)
            ?? connection(address, channel: .echo, onProgress: onProgress)
        let result = try await bounded(socket: socket, seconds: 40) {
            try await socket.connect()
            var total = 0
            for (index, size) in [64, 512, 1024].enumerated() {
                var bytes = [UInt8](repeating: 0, count: size)
                guard SecRandomCopyBytes(kSecRandomDefault, size, &bytes) == errSecSuccess else {
                    throw RelaySetupError.random
                }
                let sent = Data(bytes)
                onProgress("\(address.transportName) test \(index + 1) of 3: sending \(size) bytes to the relay…")
                try await socket.send(sent)
                var received = Data()
                while received.count < sent.count {
                    let fragment = try await self.receiveWithDeadline(socket)
                    guard received.count + fragment.count <= sent.count else {
                        throw RelaySetupError.network("Connection test returned more bytes than were sent.")
                    }
                    received.append(fragment)
                }
                guard received == sent else {
                    throw RelaySetupError.network("Connection test returned different bytes. The test did not pass.")
                }
                total += size
                onProgress("\(address.transportName) test \(index + 1) of 3 verified in both directions.")
            }
            return "3 round trips verified; \(total) bytes sent and \(total) matching bytes returned."
        }
        await socket.finishDisconnect()
        return result
    }

    /// Route selection for a byte test uses the echo itself. A preliminary
    /// status connection creates an unnecessary BLE channel/PSM handoff.
    func testConnection(addresses: [RelayAddress],
                        onProgress: @escaping (RelayAddress, String) -> Void) async throws -> (RelayAddress, String) {
        guard !addresses.isEmpty else { throw RelaySetupError.invalidState }
        var failure: any Error = RelaySetupError.timedOut
        for address in addresses {
            try Task.checkCancellation()
            do {
                onProgress(address, "Testing relay communication over \(address.transportName)…")
                let result = try await testConnection(address: address) { onProgress(address, $0) }
                return (address, result)
            } catch {
                try Task.checkCancellation()
                guard let transportError = error as? RelaySetupError else { throw error }
                switch transportError {
                case .network, .timedOut: failure = error
                default: throw error
                }
            }
        }
        throw failure
    }

    /// Returns a verified key, but does not persist it. The caller checks its
    /// current operation token before committing trust, preventing stale success.
    public func pairByButton(address: RelayAddress, privateKey: Data,
                             onProgress: ((String) -> Void)? = nil,
                             onApproval: @escaping (ButtonApproval) -> Void) async throws -> Data {
        guard privateKey.count == 32 else { throw RelaySetupError.invalidState }
        let name = Array("PLANK AVP Relay Setup".utf8)
        let codec = privateKey.withUnsafeBytes { key in
            name.withUnsafeBufferPointer { label in
                pltr_client_pair_create_button(key.bindMemory(to: UInt8.self).baseAddress,
                    label.baseAddress, label.count)
            }
        }
        guard let codec else { throw RelaySetupError.protocolError }
        defer { pltr_client_pair_destroy(codec) }
        let socket = connection(address, onProgress: onProgress)
        let result = try await bounded(socket: socket, seconds: 85) {
            try await socket.connect()
            var output = [UInt8](repeating: 0, count: 512)
            var written = 0
            guard pltr_client_pair_start(codec, &output, output.count, &written) == 0 else {
                throw RelaySetupError.protocolError
            }
            try await socket.send(Data(output.prefix(written)))
            onProgress?("Authorization requested. Waiting for the relay’s tablet status…")
            while true {
                let data = try await socket.receive()
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    var consumed = 0, replySize = 0
                    var relayKey = [UInt8](repeating: 0, count: 32)
                    let result = data.withUnsafeBytes { bytes in
                        pltr_client_pair_receive(codec,
                            bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset),
                            data.count - offset, &consumed, &output, output.count, &replySize, &relayKey)
                    }
                    if result < 0 { throw RelaySetupError.approvalFailed }
                    guard result >= 0, consumed > 0, consumed <= data.count - offset,
                          replySize <= output.count else { throw RelaySetupError.protocolError }
                    offset += consumed
                    if replySize > 0 { try await socket.send(Data(output.prefix(replySize))) }
                    if result == 3 {
                        var status = [UInt8](repeating: 0, count: 8)
                        guard pltr_client_pair_approval_status(codec, &status) == 0 else {
                            throw RelaySetupError.protocolError
                        }
                        onApproval(ButtonApproval(tabletReady: status[1] == 1,
                            presses: Int(status[2]), secondsRemaining: Int(status[4]) | Int(status[5]) << 8))
                    }
                    if result == 2 {
                        try Task.checkCancellation()
                        return Data(relayKey)
                    }
                }
            }
        }
        await socket.finishDisconnect()
        return result
    }

    public func observe(address: RelayAddress, privateKey: Data, relayKey: Data,
                        onProgress: ((String) -> Void)? = nil,
                        onSample: (TabletReadings) -> Void) async throws {
        guard privateKey.count == 32, relayKey.count == 32 else {
            throw RelaySetupError.invalidState
        }
        let codec = privateKey.withUnsafeBytes { client in
            relayKey.withUnsafeBytes { relay in
                pltr_client_link_create(client.bindMemory(to: UInt8.self).baseAddress,
                    relay.bindMemory(to: UInt8.self).baseAddress, address.linkType)
            }
        }
        guard let codec else { throw RelaySetupError.protocolError }
        defer { pltr_client_link_destroy(codec) }
        guard pltr_client_link_enable_input_observer(codec) == 0 else { throw RelaySetupError.protocolError }
        let socket = connection(address, onProgress: onProgress)
        try await bounded(socket: socket, seconds: 3600) {
            try await socket.connect()
            var output = [UInt8](repeating: 0, count: 8448)
            var written = 0
            guard pltr_client_link_start(codec, &output, output.count, &written) == 0 else {
                throw RelaySetupError.protocolError
            }
            try await socket.send(Data(output.prefix(written)))
            var requested = false
            while true {
                let data = try await self.receiveWithDeadline(socket)
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    var consumed = 0, replySize = 0, payloadSize = 0
                    var type: UInt16 = 0
                    var payload = [UInt8](repeating: 0, count: 8192)
                    let result = data.withUnsafeBytes { bytes in
                        pltr_client_link_receive(codec,
                            bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset),
                            data.count-offset, &consumed, &output, output.count, &replySize,
                            &type, &payload, payload.count, &payloadSize)
                    }
                    guard result >= 0, consumed > 0, consumed <= data.count-offset,
                          replySize <= output.count else { throw RelaySetupError.protocolError }
                    offset += consumed
                    if replySize > 0 { try await socket.send(Data(output.prefix(replySize))) }
                    if !requested, pltr_client_link_peer_version(codec) != nil {
                        let enable: [UInt8] = [1]
                        guard pltr_client_link_send(codec, UInt16(PLTR_INPUT_OBSERVE.rawValue), enable, 1,
                            &output, output.count, &written) == 0 else { throw RelaySetupError.unexpectedMessage }
                        try await socket.send(Data(output.prefix(written)))
                        requested = true
                    }
                    if type == UInt16(PLTR_INPUT_SAMPLE.rawValue), requested {
                        onSample(try TabletReadings(data: Data(payload.prefix(payloadSize))))
                    } else if type == UInt16(PLTR_PING.rawValue), payloadSize == 16 {
                        var pong = Array(payload.prefix(16))
                        let now = DispatchTime.now().uptimeNanoseconds / 1000
                        let timestamp = (0..<8).map { UInt8(truncatingIfNeeded: now >> (8*$0)) }
                        pong.append(contentsOf: timestamp); pong.append(contentsOf: timestamp)
                        guard pltr_client_link_send(codec, UInt16(PLTR_PONG.rawValue), pong, pong.count,
                            &output, output.count, &written) == 0 else { throw RelaySetupError.protocolError }
                        try await socket.send(Data(output.prefix(written)))
                    } else if type != 0 { throw RelaySetupError.unexpectedMessage }
                }
            }
        }
    }

    func receiveWithDeadline(_ socket: any RelayByteConnection) async throws -> Data {
        var expired = false
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            expired = true
            socket.cancel()
        }
        defer { deadline.cancel() }
        do { return try await socket.receive() }
        catch {
            if expired && !Task.isCancelled { throw RelaySetupError.timedOut }
            throw error
        }
    }

    func bounded<T>(socket: any RelayByteConnection, seconds: UInt64, closing: Bool = true,
                            operation: () async throws -> T) async throws -> T {
        var expired = false
        let timer = Task {
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            expired = true
            socket.cancel()
        }
        defer { timer.cancel(); if closing { socket.cancel() } }
        return try await withTaskCancellationHandler {
            do {
                let result = try await operation()
                if closing { await socket.finishDisconnect() }
                return result
            } catch {
                await socket.finishDisconnect()
                if Task.isCancelled { throw CancellationError() }
                if expired { throw RelaySetupError.timedOut }
                throw error
            }
        } onCancel: { socket.cancel() }
    }
}
