// SPDX-License-Identifier: GPL-3.0-or-later
// Uses the same C CPace/Noise implementation as the relay. The session framing
// and Keychain approach follow cnoellert's Vision Pro prototype; see NOTICE.md.
import Foundation
import Security
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
    case approvalFailed

    public var errorDescription: String? {
        switch self {
        case .invalidState: "Choose a Bluetooth relay first."
        case .storage: "The app could not access its pairing keys in Keychain."
        case .invalidStoredKey: "The saved identity is invalid. It was not replaced."
        case .random: "The system could not generate secure random data."
        case .protocolError: "The relay exchange could not be verified. Try connecting again."
        case let .network(message): "Relay connection failed: \(message)"
        case .timedOut: "The relay did not complete the operation in time. You can try again."
        case .identityChanged: "This address already has a different trusted relay. Forget it explicitly before pairing a replacement."
        case .unexpectedMessage: "The relay sent an unsupported message. The connection closed; saved trust is retained."
        case .approvalFailed: "Tablet approval expired or could not be verified. Tap Pair to try again."
        }
    }
}

/// Separate namespace: test-app pairing never replaces the full Client's trust.
@MainActor
public final class RelayKeyStore {
    private let service = "la.instinctual.PLANK.TabletSetup.pairing.v1"
    public init() {}

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
        try read(address.keychainAccount)
    }

    public func clientKey() throws -> Data {
        if let existing = try read("client-private-v1") { return existing }
        let key = try Self.randomBytes(count: 32)
        try add(key, account: "client-private-v1")
        return key
    }

    public func saveRelay(_ key: Data, address: RelayAddress) throws {
        if let existing = try relayKey(address) {
            guard existing == key else { throw RelaySetupError.identityChanged }
            return
        }
        try add(key, account: address.keychainAccount)
    }

    public func forgetRelay(_ address: RelayAddress) throws {
        let result = SecItemDelete(query(address.keychainAccount) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw RelaySetupError.storage(result)
        }
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
}

@MainActor
public final class RelayPairingClient {
    public init() {}

    private func connection(_ address: RelayAddress, onProgress: ((String) -> Void)? = nil) -> RelayBLEConnection {
        RelayBLEConnection(identifier: address.bluetoothIdentifier, onProgress: onProgress)
    }

    /// Tests only byte delivery over dedicated, unauthenticated echo channels.
    /// No pairing codec, Keychain access or tablet input is used or authorized.
    public func testBluetooth(address: RelayAddress, onProgress: @escaping (String) -> Void) async throws -> String {
        let socket = RelayBLEConnection(identifier: address.bluetoothIdentifier, channel: .echo, onProgress: onProgress)
        let result = try await bounded(socket: socket, seconds: 40) {
            try await socket.connect()
            var total = 0
            for (index, size) in [64, 512, 1024].enumerated() {
                var bytes = [UInt8](repeating: 0, count: size)
                guard SecRandomCopyBytes(kSecRandomDefault, size, &bytes) == errSecSuccess else {
                    throw RelaySetupError.random
                }
                let sent = Data(bytes)
                onProgress("Bluetooth test \(index + 1) of 3: sending \(size) bytes to the relay…")
                try await socket.send(sent)
                var received = Data()
                while received.count < sent.count {
                    let fragment = try await self.receiveWithDeadline(socket)
                    guard received.count + fragment.count <= sent.count else {
                        throw RelaySetupError.network("Bluetooth test returned more bytes than were sent.")
                    }
                    received.append(fragment)
                }
                guard received == sent else {
                    throw RelaySetupError.network("Bluetooth test returned different bytes. The test did not pass.")
                }
                total += size
                onProgress("Bluetooth test \(index + 1) of 3 verified in both directions.")
            }
            return "3 round trips verified; \(total) bytes sent and \(total) matching bytes returned."
        }
        await socket.finishDisconnect()
        return result
    }

    /// Returns a verified key, but does not persist it. The caller checks its
    /// current operation token before committing trust, preventing stale success.
    public func pairByButton(address: RelayAddress, privateKey: Data,
                             onProgress: ((String) -> Void)? = nil,
                             onApproval: @escaping (ButtonApproval) -> Void) async throws -> Data {
        guard privateKey.count == 32 else { throw RelaySetupError.invalidState }
        let name = Array("PLANK Tablet Setup".utf8)
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

    /// Verify the saved relay without SESSION_READY, HID attachment or Host
    /// feature negotiation. The current daemon serves one connection at a time.
    public func check(address: RelayAddress, privateKey: Data, relayKey: Data) async throws -> String {
        guard privateKey.count == 32, relayKey.count == 32 else {
            throw RelaySetupError.invalidStoredKey
        }
        let codec = privateKey.withUnsafeBytes { client in
            relayKey.withUnsafeBytes { relay in
                pltr_client_link_create(client.bindMemory(to: UInt8.self).baseAddress,
                                        relay.bindMemory(to: UInt8.self).baseAddress, 1)
            }
        }
        guard let codec else { throw RelaySetupError.protocolError }
        defer { pltr_client_link_destroy(codec) }
        let socket = connection(address)
        return try await bounded(socket: socket, seconds: 10) {
            try await socket.connect()
            var output = [UInt8](repeating: 0, count: 8448)
            var written = 0
            guard pltr_client_link_start(codec, &output, output.count, &written) == 0 else {
                throw RelaySetupError.protocolError
            }
            try await socket.send(Data(output.prefix(written)))
            while true {
                let data = try await socket.receive()
                var offset = 0
                while offset < data.count {
                    var consumed = 0, replySize = 0, payloadSize = 0
                    var type: UInt16 = 0
                    var payload = [UInt8](repeating: 0, count: 8192)
                    let result = data.withUnsafeBytes { bytes in
                        pltr_client_link_receive(codec,
                            bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset),
                            data.count - offset, &consumed, &output, output.count, &replySize,
                            &type, &payload, payload.count, &payloadSize)
                    }
                    guard result >= 0, consumed > 0, consumed <= data.count - offset,
                          replySize <= output.count else { throw RelaySetupError.protocolError }
                    offset += consumed
                    if replySize > 0 { try await socket.send(Data(output.prefix(replySize))) }
                    // A verified HELLO exposes the peer version. No raw input is
                    // requested or consumed by this diagnostic connection.
                    if let version = pltr_client_link_peer_version(codec) {
                        let peerVersion = String(cString: version)
                        var endSize = 0
                        let goodbye: [UInt8] = [1, 0]
                        if pltr_client_link_send(codec, UInt16(PLTR_GOODBYE.rawValue), goodbye, goodbye.count,
                                                 &output, output.count, &endSize) == 0 {
                            try await socket.send(Data(output.prefix(endSize)))
                        }
                        try Task.checkCancellation()
                        return peerVersion
                    }
                    guard type == 0 else { throw RelaySetupError.unexpectedMessage }
                }
            }
        }
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
                    relay.bindMemory(to: UInt8.self).baseAddress, 1)
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

    func bounded<T>(socket: any RelayByteConnection, seconds: UInt64,
                            operation: () async throws -> T) async throws -> T {
        var expired = false
        let timer = Task {
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            expired = true
            socket.cancel()
        }
        defer { timer.cancel(); socket.cancel() }
        return try await withTaskCancellationHandler {
            do { return try await operation() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if expired { throw RelaySetupError.timedOut }
                throw error
            }
        } onCancel: { socket.cancel() }
    }
}
