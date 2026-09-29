// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@preconcurrency import Network
@testable import RelaySetupKit

@MainActor
final class EchoServer {
    let listener: NWListener
    var clients: [NWConnection] = []
    var buffers: [ObjectIdentifier: Data] = [:]
    var ready: CheckedContinuation<NWEndpoint.Port, Error>?
    var headers = Set<ObjectIdentifier>()

    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let pending = self.ready; self.ready = nil
                        pending?.resume(returning: self.listener.port!)
                    case .failed(let error):
                        let pending = self.ready; self.ready = nil
                        pending?.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { return }
                    self.clients.append(connection)
                    connection.start(queue: .main)
                    self.read(connection)
                }
            }
            listener.start(queue: .main)
        }
    }

    func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    let id = ObjectIdentifier(connection)
                    var payload = data
                    if !self.headers.contains(id) {
                        self.buffers[id, default: Data()].append(data)
                        guard self.buffers[id]!.count >= 9 else { self.read(connection); return }
                        precondition(self.buffers[id]!.prefix(9) == Data("PLTRTCP1".utf8) + Data([2]))
                        payload = Data(self.buffers.removeValue(forKey: id)!.dropFirst(9))
                        self.headers.insert(id)
                    }
                    // Fragment replies independently of the client's sends.
                    for offset in stride(from: 0, to: payload.count, by: 17) {
                        connection.send(content: payload.subdata(in: offset..<min(offset+17, payload.count)), completion: .idempotent)
                    }
                }
                if !done && error == nil { self.read(connection) }
            }
        }
    }
    func close() { listener.cancel(); clients.forEach { $0.cancel() } }
}

@main
enum RelayNetworkTests {
    @MainActor static func main() async throws {
        let key = Data(repeating: 1, count: 32), otherKey = Data(repeating: 2, count: 32)
        let ble = BluetoothRelay(id: UUID(), name: "Studio", signal: -40)
        let address = RelayAddress(service: "Studio", domain: "local.", name: "Studio", key: key)
        let moved = RelayAddress(service: "Renamed service", domain: "local.", name: "Renamed", key: key)
        precondition(address.linkType == 2 && address.keychainAccount == moved.keychainAccount)
        precondition(RelayScanner.key(String(repeating: "01", count: 32)) == key)
        precondition(RelayScanner.key(String(repeating: "zz", count: 32)) == nil)
        precondition(RelayScanner.key("01") == nil)
        let joined = RelayListings.combine(network: [address], bluetooth: [ble], known: [ble.id: key])
        precondition(joined.count == 1 && joined[0].addresses.map(\.linkType) == [2, 1])
        let mismatch = RelayListings.combine(network: [address], bluetooth: [ble], known: [ble.id: otherKey])
        precondition(mismatch.count == 2, "Matching names cannot override known distinct identities")
        let duplicate = RelayAddress(service: "Studio (2)", domain: "local.", name: "Studio", key: otherKey)
        precondition(RelayListings.combine(network: [address, duplicate], bluetooth: [ble], known: [:]).count == 3,
                     "Ambiguous names must remain separate")
        let server = try EchoServer()
        let port = try await server.start()
        defer { server.close() }
        let socket = RelayTCPConnection(endpoint: .hostPort(host: "127.0.0.1", port: port), channel: 2)
        let client = RelayPairingClient()
        try await client.bounded(socket: socket, seconds: 10) {
            try await socket.connect()
            for size in [64, 512, 1024] {
                let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
                try await socket.send(payload)
                var received = Data()
                while received.count < payload.count { received.append(try await socket.receive()) }
                precondition(received == payload)
            }
        }
        let canceled = RelayTCPConnection(endpoint: .hostPort(host: "127.0.0.1", port: port))
        await canceled.finishDisconnect()
        do { try await canceled.connect(); fatalError("Canceled connection reopened") }
        catch RelaySetupError.invalidState {}
        print("PASS: fresh TCP round trips, fragmented replies, cancellation, identity grouping and address changes")
    }
}
