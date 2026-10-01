// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CRelayProtocol
import OSLog

/// Prefer a working route during confirmation; failed routes get a short
/// cooldown instead of being retried on every other status request.
struct RelayControlRoutes {
    private(set) var successful: RelayAddress?
    private var failures: [RelayAddress: ContinuousClock.Instant] = [:]

    mutating func succeeded(_ address: RelayAddress) {
        successful = address
        failures.removeValue(forKey: address)
    }

    mutating func failed(_ address: RelayAddress, now: ContinuousClock.Instant = .now) {
        failures[address] = now + .seconds(15)
        if successful == address { successful = nil }
    }

    func ordered(_ addresses: [RelayAddress], preferBluetooth: Bool? = nil,
                 now: ContinuousClock.Instant = .now) -> [RelayAddress] {
        func rank(_ address: RelayAddress) -> Int {
            let cooling = (failures[address].map { $0 > now } ?? false) ? 100 : 0
            let transport = preferBluetooth.map { ($0 == (address.linkType == 1)) ? 0 : 10 } ?? 0
            return cooling + transport + (successful == address ? 0 : 1)
        }
        return addresses.enumerated().sorted {
            let a = rank($0.element), b = rank($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
}

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
        case "waiting": "Waiting for Ethernet"
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
        let payload = try JSONEncoder().encode(RelayNetworkCommand(op: mode == nil ? "network-status" : "network-mode", mode: mode, requestID: requestID))
        let replies = try await managementRequests(address: address, privateKey: privateKey, relayKey: relayKey, payloads: [payload])
        return try RelayNetworkStatus.decode(replies[0], request: 1)
    }

    func managementRequests(address: RelayAddress, privateKey: Data, relayKey: Data, payloads: [Data]) async throws -> [Data] {
        guard privateKey.count == 32, relayKey.count == 32, !payloads.isEmpty, payloads.count <= 3,
              payloads.allSatisfy({ $0.count <= 1024 }) else { throw RelaySetupError.protocolError }
        if !managementScope {
            return try await withManagementSession {
                try await self.managementRequests(address: address, privateKey: privateKey, relayKey: relayKey, payloads: payloads)
            }
        }
        if let current = managementConnection,
           !current.matches(address: address, privateKey: privateKey, relayKey: relayKey) {
            managementConnection = nil
            await current.close()
        }
        do {
            let session: RelayManagementConnection
            if let current = managementConnection { session = current }
            else {
                session = try RelayManagementConnection(address: address, privateKey: privateKey,
                    relayKey: relayKey, socket: connection(address))
                managementConnection = session
            }
            return try await session.requests(payloads, client: self)
        } catch {
            let failed = managementConnection
            managementConnection = nil
            await failed?.close()
            throw error // A sent mutation is never replayed here.
        }
    }

    /// A foreground operation (or one background refresh) owns the relay's
    /// single authorized stream until completion, failure, or cancellation.
    func withManagementSession<T>(_ operation: () async throws -> T) async throws -> T {
        guard !managementScope else { throw RelaySetupError.invalidState }
        managementScope = true
        do {
            let result = try await operation()
            await finishManagementSession()
            try Task.checkCancellation()
            return result
        } catch {
            await finishManagementSession()
            throw error
        }
    }

    private func finishManagementSession() async {
        let previous = managementConnection
        managementConnection = nil
        await previous?.close()
        managementScope = false
    }
}

// The pointer is only used by its MainActor owner; destruction cannot overlap
// a request because requests retain the owner across every suspension point.
private final class ManagementCodec: @unchecked Sendable {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
    deinit { pltr_client_link_destroy(value) }
}

@MainActor
final class RelayManagementConnection {
    private let address: RelayAddress
    private let privateKey: Data
    private let relayKey: Data
    private let socket: any RelayByteConnection
    private let link: ManagementCodec
    private var ready = false
    private var closed = false
    private var exchanging = false
    private let logger = Logger(subsystem: "la.instinctual.PLANK.TabletSetup", category: "NetworkControl")

    init(address: RelayAddress, privateKey: Data, relayKey: Data, socket: any RelayByteConnection) throws {
        self.address = address; self.privateKey = privateKey; self.relayKey = relayKey; self.socket = socket
        let codec = privateKey.withUnsafeBytes { key in
            relayKey.withUnsafeBytes { relay in
                pltr_client_link_create(key.bindMemory(to: UInt8.self).baseAddress,
                    relay.bindMemory(to: UInt8.self).baseAddress, address.linkType)
            }
        }
        guard let codec else { throw RelaySetupError.protocolError }
        link = ManagementCodec(codec)
        guard pltr_client_link_enable_tablet_management(codec) == 0 else { throw RelaySetupError.protocolError }
    }

    func matches(address: RelayAddress, privateKey: Data, relayKey: Data) -> Bool {
        !closed && self.address == address && self.privateKey == privateKey && self.relayKey == relayKey
    }

    func requests(_ payloads: [Data], client: RelayPairingClient) async throws -> [Data] {
        guard !closed, !exchanging else { throw RelaySetupError.invalidState }
        exchanging = true
        defer { exchanging = false }
        let codec = link.value
        if !ready {
            let start = ContinuousClock.now
            // Transport startup owns its deadline (BLE 20 s, TCP 8 s). Starting
            // the authorization timer before connect truncated BLE startup to
            // 12 s and reported "Bluetooth interrupted" before a link existed.
            try await withTaskCancellationHandler {
                try await self.socket.connect()
                try Task.checkCancellation()
            } onCancel: { self.socket.cancel() }
            try await client.bounded(socket: socket, seconds: 12, closing: false) {
                var output = [UInt8](repeating: 0, count: 8448)
                var written = 0
                guard pltr_client_link_start(codec, &output, output.count, &written) == 0 else { throw RelaySetupError.protocolError }
                try await self.socket.send(Data(output.prefix(written)))
                while pltr_client_link_peer_version(codec) == nil {
                    guard try await client.managementFrames(self.socket, codec: codec).isEmpty else { throw RelaySetupError.unexpectedMessage }
                }
            }
            ready = true
            logger.notice("Management connection ready over \(self.address.transportName, privacy: .public), elapsed \(String(describing: start.duration(to: .now)), privacy: .public)")
        }
        var responses: [Data] = []
        for payload in payloads {
            let start = ContinuousClock.now
            let response = try await client.bounded(socket: socket, seconds: 10, closing: false) {
                    try Task.checkCancellation()
                    var output = [UInt8](repeating: 0, count: 8448)
                    var written = 0
                    let result = payload.withUnsafeBytes { bytes in
                        pltr_client_link_send(codec, UInt16(PLTR_TABLET_REQUEST.rawValue),
                            bytes.bindMemory(to: UInt8.self).baseAddress, payload.count,
                            &output, output.count, &written)
                    }
                    guard result == 0 else { throw RelaySetupError.protocolError }
                    try await self.socket.send(Data(output.prefix(written)))
                    while true {
                        let replies = try await client.managementFrames(self.socket, codec: codec)
                        guard replies.count <= 1 else { throw RelaySetupError.protocolError }
                        if let reply = replies.first { return reply }
                    }
            }
            responses.append(response)
            // Only fixed operation names and timing; never SSIDs, keys, or payloads.
            let command = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let name = command?["op"] as? String ?? "unknown"
            let permitted = ["network-status", "network-mode", "wifi-status", "wifi-list", "wifi-scan", "wifi-enable", "wifi-join", "wifi-connect", "wifi-forget"]
            let operation = permitted.contains(name) ? name : "unknown"
            logger.notice("Management \(operation, privacy: .public) completed, elapsed \(String(describing: start.duration(to: .now)), privacy: .public)")
        }
        return responses
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await socket.finishDisconnect()
    }
}
