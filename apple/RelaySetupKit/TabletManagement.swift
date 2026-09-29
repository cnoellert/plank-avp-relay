// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CRelayProtocol

public struct ManagedTablet: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let connected: Bool
    public let paired: Bool
}

public struct TabletSetupStatus: Decodable, Equatable, Sendable {
    public let version: Int
    public let id: Int
    public let ok: Bool
    public let hostname: String
    public let phase: String
    public let message: String
    public let canManage: Bool
    public let initialSetup: Bool
    public let attached: Bool
    public let selected: String?
    public let secondsRemaining: Int
    public let tablets: [ManagedTablet]
    public let candidates: [ManagedTablet]
    public let enrollmentVersion: Int?
    public let headsetAuthorized: Bool?
    public let relayKey: String?

    public static func decode(_ data: Data, request: Int) throws -> Self {
        struct Envelope: Decodable { let version: Int; let id: Int; let ok: Bool; let error: String? }
        guard data.count <= 4096 else { throw RelaySetupError.protocolError }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, envelope.id == request else { throw RelaySetupError.protocolError }
        guard envelope.ok else { throw RelaySetupError.network(envelope.error ?? "Tablet setup failed.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard ["idle", "scanning", "pairing", "connecting", "verifying", "ready", "failed"].contains(result.phase),
              (0...60).contains(result.secondsRemaining), result.tablets.count <= 16,
              result.candidates.count <= 16, result.hostname.utf8.count <= 255,
              result.message.utf8.count <= 1024 else { throw RelaySetupError.protocolError }
        return result
    }

    public var operating: Bool { ["pairing", "connecting", "verifying"].contains(phase) }
    public var needsHeadsetRecovery: Bool { !canManage && !initialSetup && headsetAuthorized != true }

    public var enrollmentIdentity: Data? {
        guard enrollmentVersion == 1, let relayKey, relayKey.utf8.count == 64 else { return nil }
        let characters = Array(relayKey.utf8)
        var bytes = [UInt8]()
        for offset in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: characters[offset..<offset+2], as: UTF8.self), radix: 16)
            else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }
}

struct TabletSetupCommand: Encodable, Sendable {
    let version = 1
    let id: Int
    let op: String
    let tablet: String?
}

extension RelayPairingClient {
    /// The plaintext endpoint supplies only status and the public relay identity.
    /// All changes use Noise; a first-use session is restricted to tablet setup
    /// until the relay saves the initiating headset after tablet verification.
    public func manageTablets(address: RelayAddress, privateKey: Data, relayKey: Data?,
        onIdentity: (Data) throws -> Void, expectedIdentity: Data?,
        onAuthorized: (Data) throws -> Void,
        nextCommand: () -> (String, String?)?, onStatus: (TabletSetupStatus) -> Void,
        onProgress: @escaping (String) -> Void) async throws -> Bool {
        let wasAuthorized = relayKey != nil
        let identity: Data
        if let relayKey {
            identity = relayKey
        } else {
            let bootstrap = try await setupStatus(address, onProgress: onProgress)
            guard let discovered = bootstrap.enrollmentIdentity else {
                throw RelaySetupError.network("Update the relay package to use combined tablet and headset setup.")
            }
            if let expectedIdentity, expectedIdentity != discovered { throw RelaySetupError.identityChanged }
            try onIdentity(discovered)
            identity = discovered
            onProgress(bootstrap.initialSetup ? "Opening secure tablet setup…" : "Restoring this headset’s saved authorization…")
        }
        guard privateKey.count == 32, identity.count == 32 else { throw RelaySetupError.invalidStoredKey }
        let socket = connection(address, onProgress: onProgress)
        let codec = privateKey.withUnsafeBytes { key in
            identity.withUnsafeBytes { relay in
                pltr_client_link_create(key.bindMemory(to: UInt8.self).baseAddress,
                    relay.bindMemory(to: UInt8.self).baseAddress, address.linkType)
            }
        }
        guard let codec else { throw RelaySetupError.protocolError }
        defer { pltr_client_link_destroy(codec) }
        guard pltr_client_link_enable_tablet_management(codec) == 0 else { throw RelaySetupError.protocolError }
        var handshakeComplete = false
        do {
            let completed = try await bounded(socket: socket, seconds: 300) {
                try await socket.connect()
                var output = [UInt8](repeating: 0, count: 8448)
                var written = 0
                guard pltr_client_link_start(codec, &output, output.count, &written) == 0 else {
                    throw RelaySetupError.protocolError
                }
                try await socket.send(Data(output.prefix(written)))
                while pltr_client_link_peer_version(codec) == nil {
                    let frames = try await self.managementFrames(socket, codec: codec)
                    guard frames.isEmpty else { throw RelaySetupError.unexpectedMessage }
                }
                handshakeComplete = true
                var reportedAuthorization = false
                for request in 1...300 {
                    try Task.checkCancellation()
                    let command = nextCommand() ?? ("status", nil)
                    let payload = try JSONEncoder().encode(TabletSetupCommand(id: request, op: command.0, tablet: command.1))
                    let result = payload.withUnsafeBytes { bytes in
                        pltr_client_link_send(codec, UInt16(PLTR_TABLET_REQUEST.rawValue),
                            bytes.bindMemory(to: UInt8.self).baseAddress, payload.count,
                            &output, output.count, &written)
                    }
                    guard result == 0 else { throw RelaySetupError.protocolError }
                    try await socket.send(Data(output.prefix(written)))
                    var response: Data?
                    while response == nil {
                        let frames = try await self.managementFrames(socket, codec: codec)
                        guard frames.count <= 1 else { throw RelaySetupError.protocolError }
                        response = frames.first
                    }
                    let status = try TabletSetupStatus.decode(response!, request: request)
                    try Task.checkCancellation()
                    if status.headsetAuthorized == true && !reportedAuthorization {
                        try onAuthorized(identity)
                        reportedAuthorization = true
                    }
                    onStatus(status)
                    if !wasAuthorized && reportedAuthorization && status.phase == "ready" {
                        return true
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                throw RelaySetupError.timedOut
            }
            await socket.finishDisconnect()
            return completed
        } catch {
            await socket.finishDisconnect()
            if !wasAuthorized && !handshakeComplete && !(error is CancellationError) {
                throw RelaySetupError.network("Could not verify this headset with the relay. Retry the connection. If this is a replacement headset, reset ownership through SSH on the relay first.")
            }
            throw error
        }
    }

    func setupStatus(_ address: RelayAddress, onProgress: @escaping (String) -> Void) async throws -> TabletSetupStatus {
        let socket = connection(address, channel: .setup, onProgress: onProgress)
        do {
            let status = try await bounded(socket: socket, seconds: 40) {
                try await socket.connect()
                let payload = try JSONEncoder().encode(TabletSetupCommand(id: 1, op: "status", tablet: nil))
                var record = Data([UInt8(truncatingIfNeeded: payload.count), UInt8(payload.count >> 8)])
                record.append(payload)
                try await socket.send(record)
                var buffer = Data()
                while true {
                    buffer.append(try await self.receiveWithDeadline(socket))
                    guard buffer.count <= 4098 else { throw RelaySetupError.protocolError }
                    if buffer.count >= 2 {
                        let size = Int(buffer[0]) | Int(buffer[1]) << 8
                        guard (2...4096).contains(size), buffer.count <= size + 2 else { throw RelaySetupError.protocolError }
                        if buffer.count == size + 2 {
                            return try TabletSetupStatus.decode(Data(buffer.dropFirst(2)), request: 1)
                        }
                    }
                }
            }
            await socket.finishDisconnect()
            return status
        } catch {
            await socket.finishDisconnect()
            throw error
        }
    }

    func managementFrames(_ socket: any RelayByteConnection, codec: OpaquePointer) async throws -> [Data] {
        let data = try await receiveWithDeadline(socket)
        var frames: [Data] = [], offset = 0
        while offset < data.count {
            var consumed = 0, replySize = 0, payloadSize = 0
            var type: UInt16 = 0
            var output = [UInt8](repeating: 0, count: 8448)
            var payload = [UInt8](repeating: 0, count: 8192)
            let result = data.withUnsafeBytes { bytes in
                pltr_client_link_receive(codec,
                    bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), data.count-offset,
                    &consumed, &output, output.count, &replySize, &type, &payload, payload.count, &payloadSize)
            }
            guard result >= 0, consumed > 0, consumed <= data.count-offset, replySize <= output.count,
                  payloadSize <= payload.count else { throw RelaySetupError.protocolError }
            offset += consumed
            if replySize > 0 { try await socket.send(Data(output.prefix(replySize))) }
            if type == UInt16(PLTR_TABLET_RESPONSE.rawValue) {
                frames.append(Data(payload.prefix(payloadSize)))
            } else if type == UInt16(PLTR_PING.rawValue), payloadSize == 16 {
                var pong = Array(payload.prefix(16))
                let now = DispatchTime.now().uptimeNanoseconds / 1000
                let timestamp = (0..<8).map { UInt8(truncatingIfNeeded: now >> (8*$0)) }
                pong.append(contentsOf: timestamp); pong.append(contentsOf: timestamp)
                var written = 0
                guard pltr_client_link_send(codec, UInt16(PLTR_PONG.rawValue), pong, pong.count,
                    &output, output.count, &written) == 0 else { throw RelaySetupError.protocolError }
                try await socket.send(Data(output.prefix(written)))
            } else if type != 0 { throw RelaySetupError.unexpectedMessage }
        }
        return frames
    }
}
