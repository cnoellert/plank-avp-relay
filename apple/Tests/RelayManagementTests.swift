// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CManagementPeer
@testable import RelaySetupKit

private final class PeerStorage: @unchecked Sendable {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
    deinit { management_peer_destroy(value) }
}

@MainActor
private final class Peer: RelayByteConnection {
    let storage: PeerStorage
    let key: Data
    var incoming = Data()
    var connects = 0
    var sends = 0
    var disconnected = false
    var canceled = false
    var connectDelay: Duration = .zero
    var loseReply = false
    var waiting = false
    var requests: UInt32 { management_peer_requests(storage.value) }
    init(_ privateKey: Data) {
        var key = [UInt8](repeating: 0, count: 32)
        let peer = privateKey.withUnsafeBytes { bytes in
            management_peer_create(bytes.bindMemory(to: UInt8.self).baseAddress, &key)
        }!
        storage = PeerStorage(peer); self.key = Data(key)
    }
    func connect() async throws {
        precondition(!disconnected)
        connects += 1
        try await Task.sleep(for: connectDelay)
        if canceled { throw CancellationError() }
    }
    func send(_ data: Data) async throws {
        sends += 1
        var bytes = [UInt8](repeating: 0, count: 16384), count = 0
        let result = data.withUnsafeBytes {
            management_peer_receive(storage.value, $0.bindMemory(to: UInt8.self).baseAddress,
                                    data.count, &bytes, bytes.count, &count)
        }
        guard result == 0 else { throw RelaySetupError.protocolError }
        incoming.append(contentsOf: bytes.prefix(count))
    }
    func receive() async throws -> Data {
        if loseReply && requests > 0 {
            waiting = true
            try await Task.sleep(for: .seconds(100))
        }
        guard !incoming.isEmpty else { throw RelaySetupError.network("Lost response") }
        // Fragment the encrypted stream, including handshakes.
        let part = incoming.prefix(17)
        incoming.removeFirst(part.count)
        return Data(part)
    }
    nonisolated func cancel() { Task { @MainActor in self.canceled = true } }
    func finishDisconnect() async { disconnected = true }
}

@main
enum RelayManagementTests {
    @MainActor static func main() async throws {
        let privateKey = Data(repeating: 41, count: 32)
        let peer = Peer(privateKey), client = RelayPairingClient()
        let address = RelayAddress(service: "Test", domain: "local.", name: "Test", key: peer.key)
        let payload = Data(#"{"op":"wifi-status"}"#.utf8)
        let connection = try RelayManagementConnection(address: address, privateKey: privateKey, relayKey: peer.key, socket: peer)
        try await client.withManagementSession {
            client.managementConnection = connection
            for _ in 0..<5 {
                let reply = try await client.managementRequests(address: address, privateKey: privateKey, relayKey: peer.key, payloads: [payload])
                precondition(reply == [payload] && !peer.disconnected)
            }
            precondition(peer.connects == 1 && peer.requests == 5)
            precondition(!connection.matches(address: address, privateKey: privateKey, relayKey: Data(repeating: 99, count: 32)))
        }
        precondition(peer.disconnected && client.managementConnection == nil && !client.managementScope)

        // A valid transport connection may exceed the management handshake's
        // 12 s budget. The old enclosing timer canceled this before any Noise
        // bytes were sent. Keep this real timing regression: connect owns its
        // separate bounded deadline in the production transport.
        let slow = Peer(privateKey)
        slow.connectDelay = .seconds(13)
        let slowConnection = try RelayManagementConnection(address: address,
            privateKey: privateKey, relayKey: slow.key, socket: slow)
        try await client.withManagementSession {
            client.managementConnection = slowConnection
            let reply = try await client.managementRequests(address: address,
                privateKey: privateKey, relayKey: slow.key, payloads: [payload])
            precondition(reply == [payload] && !slow.canceled && slow.connects == 1)
        }
        precondition(slow.disconnected && slow.requests == 1)

        let starting = Peer(privateKey)
        starting.connectDelay = .seconds(100)
        let startingConnection = try RelayManagementConnection(address: address,
            privateKey: privateKey, relayKey: starting.key, socket: starting)
        let startupTask = Task {
            try await client.withManagementSession {
                client.managementConnection = startingConnection
                _ = try await client.managementRequests(address: address,
                    privateKey: privateKey, relayKey: starting.key, payloads: [payload])
            }
        }
        while starting.connects == 0 { await Task.yield() }
        startupTask.cancel()
        do { try await startupTask.value; fatalError("Startup cancellation must throw") }
        catch is CancellationError {}
        await Task.yield()
        precondition(starting.canceled && starting.disconnected && starting.sends == 0)
        precondition(client.managementConnection == nil && !client.managementScope)

        let canceled = Peer(privateKey)
        canceled.loseReply = true
        let second = try RelayManagementConnection(address: address, privateKey: privateKey, relayKey: peer.key, socket: canceled)
        let task = Task {
            try await client.withManagementSession {
                client.managementConnection = second
                _ = try await client.managementRequests(address: address, privateKey: privateKey, relayKey: peer.key, payloads: [payload])
            }
        }
        while !canceled.waiting { await Task.yield() }
        task.cancel()
        do { try await task.value; fatalError("Cancellation must throw") } catch is CancellationError {}
        precondition(canceled.disconnected && canceled.requests == 1 && canceled.connects == 1,
                     "Cancellation never replays an ambiguous request")
        precondition(client.managementConnection == nil && !client.managementScope)

        let wrong = Peer(privateKey)
        let rejected = try RelayManagementConnection(address: address, privateKey: privateKey,
            relayKey: Data(repeating: 99, count: 32), socket: wrong)
        do { _ = try await rejected.requests([payload], client: client); fatalError("Wrong identity accepted") }
        catch RelaySetupError.protocolError {}
        await rejected.close()
        precondition(wrong.requests == 0 && wrong.disconnected)
        print("PASS: transport startup before handshake deadline, one encrypted connection, teardown, cancellation without replay, pinned identity")
    }
}
