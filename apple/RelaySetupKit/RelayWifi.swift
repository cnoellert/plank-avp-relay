// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct RelayWifiNetwork: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let secured: Bool
    public let supported: Bool
    public let signal: Int?
    public let saved: Bool
    public let hidden: Bool
}

public struct RelayWifiStatus: Decodable, Equatable, Sendable {
    public let supported: Bool
    public let enabled: Bool
    public let phase: String
    public let connection: String
    public let message: String
    public let network: String?
    public let name: String?
    public let addresses: [String]
    public let requestID: String?
    public var applying: Bool { phase == "applying" }
    public var canChange: Bool { supported && !applying }
    public var connectionLabel: String {
        switch connection {
        case "connected": "Connected"
        case "disabled": "Disabled"
        case "blocked": "Hardware switch disabled"
        case "associating": "Connecting"
        case "address": "Obtaining address"
        case "disconnected": "Not connected"
        default: "Unavailable"
        }
    }
    public func confirms(_ request: String) -> Bool { requestID == request && phase == "idle" }

    public static func decode(_ data: Data, request: Int) throws -> Self {
        try validateWifiEnvelope(data, request: request)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard ["idle", "applying", "failed", "unavailable"].contains(value.phase),
              ["connected", "disabled", "blocked", "associating", "address", "disconnected", "unavailable"].contains(value.connection),
              value.message.utf8.count <= 1024, value.addresses.count <= 8,
              value.addresses.allSatisfy({ $0.utf8.count <= 64 }),
              value.name == nil || value.name!.utf8.count <= 96,
              value.network == nil || wifiIdentifier(value.network!),
              value.requestID == nil || UUID(uuidString: value.requestID!) != nil else { throw RelaySetupError.protocolError }
        return value
    }
}

public struct RelayWifiPage: Decodable, Equatable, Sendable {
    public let networks: [RelayWifiNetwork]
    public let generation: String
    public let next: Int?
    public static func decode(_ data: Data, request: Int) throws -> Self {
        try validateWifiEnvelope(data, request: request)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.networks.count <= 8, UUID(uuidString: value.generation) != nil,
              value.next == nil || (1..<256).contains(value.next!),
              Set(value.networks.map(\.id)).count == value.networks.count,
              value.networks.allSatisfy({ wifiIdentifier($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 96 &&
                  ($0.signal == nil || (0...100).contains($0.signal!)) }) else { throw RelaySetupError.protocolError }
        return value
    }
}

private func wifiIdentifier(_ value: String) -> Bool {
    value.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func validateWifiEnvelope(_ data: Data, request: Int) throws {
    struct Envelope: Decodable { let version: Int; let id: Int; let ok: Bool; let error: String?; let code: String? }
    guard data.count <= 4096 else { throw RelaySetupError.protocolError }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1, envelope.id == request else { throw RelaySetupError.protocolError }
    guard envelope.ok else {
        if envelope.code == "busy" { throw RelaySetupError.network("Wi-Fi service is busy; checking again.") }
        throw RelaySetupError.rejected(envelope.error ?? "Wi-Fi request rejected.")
    }
}

// Secrets are carried only in a request value. Neither status nor discovered
// network models have a password field, and commands are never logged.
public enum RelayWifiAction: Sendable, Equatable {
    case enable(Bool), scan, connect(String), forget(String)
    case join(network: String?, ssid: String?, security: String?, password: String)
}

struct WifiCommand: Encodable {
    var version = 1
    var id = 1
    var op: String
    var requestID: String?
    var enabled: Bool?
    var network: String?
    var ssid: String?
    var security: String?
    var password: String?
    var kind: String?
    var offset: Int?
    var generation: String?

    enum CodingKeys: String, CodingKey { case version, id, op, requestID, enabled, network, ssid, security, password, kind, offset, generation }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(id, forKey: .id); try c.encode(op, forKey: .op)
        try c.encodeIfPresent(requestID, forKey: .requestID)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        if op == "wifi-join" {
            try c.encode(network, forKey: .network); try c.encode(ssid, forKey: .ssid)
            try c.encode(security, forKey: .security); try c.encode(password, forKey: .password)
        } else { try c.encodeIfPresent(network, forKey: .network) }
        try c.encodeIfPresent(kind, forKey: .kind); try c.encodeIfPresent(offset, forKey: .offset)
        try c.encodeIfPresent(generation, forKey: .generation)
    }
    static func action(_ action: RelayWifiAction, request: String) -> Self {
        var command = WifiCommand(op: "", requestID: request)
        switch action {
        case .enable(let value): command.op = "wifi-enable"; command.enabled = value
        case .scan: command.op = "wifi-scan"
        case .connect(let id): command.op = "wifi-connect"; command.network = id
        case .forget(let id): command.op = "wifi-forget"; command.network = id
        case .join(let id, let ssid, let security, let password):
            command.op = "wifi-join"; command.network = id; command.ssid = ssid
            command.security = security; command.password = password
        }
        return command
    }
}

extension RelayPairingClient {
    public func networkAndWifiStatus(address: RelayAddress, privateKey: Data, relayKey: Data) async throws -> (RelayNetworkStatus, RelayWifiStatus) {
        let commands = [WifiCommand(id: 1, op: "network-status"), WifiCommand(id: 2, op: "wifi-status")]
        let replies = try await managementRequests(address: address, privateKey: privateKey, relayKey: relayKey,
                                                   payloads: commands.map { try JSONEncoder().encode($0) })
        let network = try RelayNetworkStatus.decode(replies[0], request: 1)
        return (network, try RelayWifiStatus.decode(replies[1], request: 2))
    }

    public func wifiStatus(address: RelayAddress, privateKey: Data, relayKey: Data,
                           action: RelayWifiAction? = nil, request: String? = nil) async throws -> RelayWifiStatus {
        guard (action == nil) == (request == nil) else { throw RelaySetupError.protocolError }
        let command = action.map { WifiCommand.action($0, request: request!) } ?? WifiCommand(op: "wifi-status")
        let data = try await managementRequests(address: address, privateKey: privateKey, relayKey: relayKey,
            payloads: [JSONEncoder().encode(command)])
        return try RelayWifiStatus.decode(data[0], request: 1)
    }

    public func wifiLists(address: RelayAddress, privateKey: Data, relayKey: Data) async throws -> (RelayWifiPage, RelayWifiPage) {
        let commands = [WifiCommand(id: 1, op: "wifi-list", kind: "available", offset: 0, generation: ""),
                        WifiCommand(id: 2, op: "wifi-list", kind: "saved", offset: 0, generation: "")]
        let data = try await managementRequests(address: address, privateKey: privateKey, relayKey: relayKey,
            payloads: commands.map { try JSONEncoder().encode($0) })
        return try (RelayWifiPage.decode(data[0], request: 1), RelayWifiPage.decode(data[1], request: 2))
    }

    public func wifiPage(address: RelayAddress, privateKey: Data, relayKey: Data, kind: String,
                         offset: Int, generation: String) async throws -> RelayWifiPage {
        let command = WifiCommand(op: "wifi-list", kind: kind, offset: offset, generation: generation)
        let data = try await managementRequests(address: address, privateKey: privateKey, relayKey: relayKey,
                                               payloads: [JSONEncoder().encode(command)])
        return try RelayWifiPage.decode(data[0], request: 1)
    }
}
