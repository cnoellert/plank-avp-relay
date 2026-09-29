// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CRelayProtocol

public enum RelayNetworkMode: String, CaseIterable, Codable, Sendable {
    case bridge, router
    public var title: String { self == .bridge ? "Bridge" : "Router" }
}

public struct RelayNetworkStatus: Decodable, Equatable, Sendable {
    public let supported: Bool
    public let mode: RelayNetworkMode
    public let targetMode: RelayNetworkMode
    public let phase: String
    public let message: String
    public let ethernet: String
    public let usb: String
    public let addresses: [String]
    public let requestID: String?

    public var applying: Bool { phase == "applying" }
    public var canChange: Bool { supported && !["applying", "reboot", "unavailable"].contains(phase) }
    public var ethernetLabel: String {
        switch ethernet { case "connected": "Connected"; case "disconnected": "Disconnected"; default: "Unavailable" }
    }
    public var usbLabel: String {
        switch usb {
        case "connected": "Connected to USB host"
        case "suspended": "USB connection suspended"
        case "disconnected": "No USB connection"
        case "waiting": "Disabled — Ethernet disconnected"
        case "reboot": "Relay restart required"
        case "preparing": "Preparing USB connection"
        case "error": "USB configuration failed"
        default: "Unavailable"
        }
    }

    public static func decode(_ data: Data, request: Int) throws -> Self {
        struct Envelope: Decodable { let version: Int; let id: Int; let ok: Bool; let error: String?; let code: String? }
        guard data.count <= 4096 else { throw RelaySetupError.protocolError }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, envelope.id == request else { throw RelaySetupError.protocolError }
        guard envelope.ok else {
            if envelope.code == "busy" { throw RelaySetupError.network(envelope.error ?? "Network service is applying settings.") }
            throw RelaySetupError.rejected(envelope.error ?? "Network settings were rejected.")
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard ["idle", "applying", "failed", "unavailable", "reboot"].contains(result.phase),
              ["connected", "disconnected", "unknown"].contains(result.ethernet),
              ["connected", "suspended", "disconnected", "waiting", "reboot", "preparing", "error", "unavailable"].contains(result.usb),
              result.message.utf8.count <= 1024, result.addresses.count <= 8,
              result.addresses.allSatisfy({ $0.utf8.count <= 64 }),
              result.requestID == nil || UUID(uuidString: result.requestID!) != nil else {
            throw RelaySetupError.protocolError
        }
        return result
    }

    public func confirms(_ request: String, mode: RelayNetworkMode) -> Bool {
        requestID == request && phase == "idle" && self.mode == mode && targetMode == mode
    }
}

struct RelayNetworkCommand: Encodable {
    let version = 1
    let id = 1
    let op: String
    let mode: RelayNetworkMode?
    let requestID: String?
}

extension RelayPairingClient {
    public func networkSettings(address: RelayAddress, privateKey: Data, relayKey: Data,
                                mode: RelayNetworkMode? = nil, requestID: String? = nil) async throws -> RelayNetworkStatus {
        guard privateKey.count == 32, relayKey.count == 32, (mode == nil) == (requestID == nil) else {
            throw RelaySetupError.invalidStoredKey
        }
        let socket = connection(address) { _ in }
        let codec = privateKey.withUnsafeBytes { key in
            relayKey.withUnsafeBytes { relay in
                pltr_client_link_create(key.bindMemory(to: UInt8.self).baseAddress,
                    relay.bindMemory(to: UInt8.self).baseAddress, address.linkType)
            }
        }
        guard let codec else { throw RelaySetupError.protocolError }
        defer { pltr_client_link_destroy(codec) }
        guard pltr_client_link_enable_tablet_management(codec) == 0 else { throw RelaySetupError.protocolError }
        do {
            let status = try await bounded(socket: socket, seconds: 12) {
                try await socket.connect()
                var output = [UInt8](repeating: 0, count: 8448)
                var written = 0
                guard pltr_client_link_start(codec, &output, output.count, &written) == 0 else { throw RelaySetupError.protocolError }
                try await socket.send(Data(output.prefix(written)))
                while pltr_client_link_peer_version(codec) == nil {
                    guard try await self.managementFrames(socket, codec: codec).isEmpty else { throw RelaySetupError.unexpectedMessage }
                }
                let payload = try JSONEncoder().encode(RelayNetworkCommand(op: mode == nil ? "network-status" : "network-mode",
                                                                          mode: mode, requestID: requestID))
                let result = payload.withUnsafeBytes { bytes in
                    pltr_client_link_send(codec, UInt16(PLTR_TABLET_REQUEST.rawValue),
                        bytes.bindMemory(to: UInt8.self).baseAddress, payload.count,
                        &output, output.count, &written)
                }
                guard result == 0 else { throw RelaySetupError.protocolError }
                try await socket.send(Data(output.prefix(written)))
                while true {
                    let replies = try await self.managementFrames(socket, codec: codec)
                    guard replies.count <= 1 else { throw RelaySetupError.protocolError }
                    if let reply = replies.first { return try RelayNetworkStatus.decode(reply, request: 1) }
                }
            }
            await socket.finishDisconnect()
            return status
        } catch {
            await socket.finishDisconnect()
            throw error
        }
    }
}
