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
}

struct TabletSetupCommand: Encodable, Sendable {
    let version = 1
    let id: Int
    let op: String
    let tablet: String?
}

extension RelayPairingClient {
    /// One connection owns the setup window. Existing approvals use Noise;
    /// an unapproved headset gets only the relay's restricted bootstrap API.
    public func manageTablets(address: RelayAddress, privateKey: Data?, relayKey: Data?,
        nextCommand: () -> (String, String?)?, onStatus: (TabletSetupStatus) -> Void,
        onProgress: @escaping (String) -> Void) async throws {
        let authenticated = privateKey != nil && relayKey != nil
        let socket = RelayBLEConnection(identifier: address.bluetoothIdentifier,
            channel: authenticated ? .relay : .setup, requireTabletSetup: true, onProgress: onProgress)
        var codec: OpaquePointer?
        if let privateKey, let relayKey {
            guard privateKey.count == 32, relayKey.count == 32 else { throw RelaySetupError.invalidStoredKey }
            codec = privateKey.withUnsafeBytes { key in
                relayKey.withUnsafeBytes { relay in
                    pltr_client_link_create(key.bindMemory(to: UInt8.self).baseAddress,
                        relay.bindMemory(to: UInt8.self).baseAddress, 1)
                }
            }
            guard let codec, pltr_client_link_enable_tablet_management(codec) == 0 else {
                if let codec { pltr_client_link_destroy(codec) }
                throw RelaySetupError.protocolError
            }
        }
        defer { if let codec { pltr_client_link_destroy(codec) } }
        do {
            try await bounded(socket: socket, seconds: 300) {
                try await socket.connect()
                var plainBuffer = Data()
                var output = [UInt8](repeating: 0, count: 8448)
                var written = 0
                if let codec {
                    guard pltr_client_link_start(codec, &output, output.count, &written) == 0 else {
                        throw RelaySetupError.protocolError
                    }
                    try await socket.send(Data(output.prefix(written)))
                    while pltr_client_link_peer_version(codec) == nil {
                        let frames = try await self.managementFrames(socket, codec: codec)
                        guard frames.isEmpty else { throw RelaySetupError.unexpectedMessage }
                    }
                }
                for request in 1...300 {
                    try Task.checkCancellation()
                    let command = nextCommand() ?? ("status", nil)
                    let payload = try JSONEncoder().encode(TabletSetupCommand(id: request, op: command.0, tablet: command.1))
                    if let codec {
                        let result = payload.withUnsafeBytes { bytes in
                            pltr_client_link_send(codec, UInt16(PLTR_TABLET_REQUEST.rawValue),
                                bytes.bindMemory(to: UInt8.self).baseAddress, payload.count,
                                &output, output.count, &written)
                        }
                        guard result == 0 else { throw RelaySetupError.protocolError }
                        try await socket.send(Data(output.prefix(written)))
                    } else {
                        guard payload.count <= 512 else { throw RelaySetupError.protocolError }
                        var record = Data([UInt8(truncatingIfNeeded: payload.count), UInt8(payload.count >> 8)])
                        record.append(payload)
                        try await socket.send(record)
                    }
                    var response: Data?
                    while response == nil {
                        if let codec {
                            let frames = try await self.managementFrames(socket, codec: codec)
                            guard frames.count <= 1 else { throw RelaySetupError.protocolError }
                            response = frames.first
                        } else {
                            plainBuffer.append(try await self.receiveWithDeadline(socket))
                            guard plainBuffer.count <= 4098 else { throw RelaySetupError.protocolError }
                            if plainBuffer.count >= 2 {
                                let size = Int(plainBuffer[0]) | Int(plainBuffer[1]) << 8
                                guard (2...4096).contains(size), plainBuffer.count <= size + 2 else {
                                    throw RelaySetupError.protocolError
                                }
                                if plainBuffer.count == size + 2 {
                                    response = Data(plainBuffer.dropFirst(2))
                                    plainBuffer.removeAll(keepingCapacity: true)
                                }
                            }
                        }
                    }
                    onStatus(try TabletSetupStatus.decode(response!, request: request))
                    try await Task.sleep(for: .seconds(1))
                }
                throw RelaySetupError.timedOut
            }
        } catch {
            await socket.finishDisconnect()
            throw error
        }
        await socket.finishDisconnect()
    }

    private func managementFrames(_ socket: RelayBLEConnection, codec: OpaquePointer) async throws -> [Data] {
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
