// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

@MainActor
private final class Socket: RelayByteConnection {
    var connectError: (any Error)?
    var corruptReply = false
    var stallReply = false
    var receiving = false
    var closed = false
    var connectCount = 0
    var sent: [Data] = []
    var pending = Data()
    var onClose: (() async -> Void)?

    func connect() async throws {
        connectCount += 1
        if let connectError { throw connectError }
    }
    func send(_ data: Data) async throws {
        precondition(!closed && pending.isEmpty)
        sent.append(data)
        pending = data
        if corruptReply { pending[pending.startIndex] ^= 1 }
    }
    func receive() async throws -> Data {
        receiving = true
        if stallReply { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        precondition(!closed && !pending.isEmpty)
        let fragment = Data(pending.prefix(17))
        pending.removeFirst(fragment.count)
        return fragment
    }
    nonisolated func cancel() {}
    func finishDisconnect() async {
        guard !closed else { return }
        closed = true
        await onClose?()
    }
}

@main
enum RelayDiagnosticTests {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Diagnostic did not reach the expected state")
    }

    @MainActor static func main() async throws {
        let client = RelayPairingClient()
        let bluetooth = RelayAddress(bluetoothIdentifier: UUID(), name: "test-relay")
        let network = RelayAddress(service: "test-relay", domain: "local.", name: "test-relay", key: Data(repeating: 7, count: 32))
        let socket = Socket()
        var connections: [RelayAddress] = []
        client.makeDiagnosticConnection = { address, _ in
            connections.append(address)
            precondition(connections.count == 1, "A diagnostic must not reopen its Bluetooth PSM")
            return socket
        }
        let (address, result) = try await client.testConnection(addresses: [bluetooth]) { _, _ in }
        precondition(address == bluetooth && result.contains("3 round trips verified"))
        precondition(connections == [bluetooth] && socket.connectCount == 1 && socket.closed)
        precondition(socket.sent.map(\.count) == [64, 512, 1024],
                     "One echo connection must carry all three random payloads")

        // Automatic routing may try another address, but only after cleanup.
        let unreachable = Socket(), reachable = Socket()
        unreachable.connectError = RelaySetupError.network("Unreachable network route")
        connections = []
        client.makeDiagnosticConnection = { address, _ in
            connections.append(address)
            if address == network { return unreachable }
            precondition(unreachable.closed, "Close the failed route before fallback")
            return reachable
        }
        let (fallback, _) = try await client.testConnection(addresses: [network, bluetooth]) { _, _ in }
        precondition(fallback == bluetooth && connections == [network, bluetooth] && reachable.closed)

        // A Bluetooth-only failure must never reach an otherwise usable network.
        if RelayTestTransport.isAvailable {
            let offline = Socket()
            offline.connectError = RelaySetupError.network("Bluetooth unavailable")
            connections = []
            client.makeDiagnosticConnection = { address, _ in
                connections.append(address)
                precondition(address == bluetooth)
                return offline
            }
            do {
                _ = try await client.testConnection(addresses: RelayTestTransport.bluetoothOnly.candidates([network, bluetooth])) { _, _ in }
                fatalError("An unavailable Bluetooth route passed")
            } catch let error as RelaySetupError {
                guard case .network = error else { throw error }
            }
            precondition(connections == [bluetooth] && offline.closed)
        }

        let corrupt = Socket()
        corrupt.corruptReply = true
        client.makeDiagnosticConnection = { _, _ in corrupt }
        do {
            _ = try await client.testConnection(addresses: [bluetooth]) { _, _ in }
            fatalError("Corrupted echo passed")
        } catch let error as RelaySetupError {
            guard case .network = error else { throw error }
        }
        precondition(corrupt.closed && corrupt.sent.count == 1)

        // Cancellation must drain teardown before completing or trying a route.
        let canceled = Socket()
        canceled.stallReply = true
        var closing = false, allowClose = false, finished = false
        canceled.onClose = {
            closing = true
            while !allowClose { await Task.yield() }
        }
        connections = []
        client.makeDiagnosticConnection = { address, _ in
            connections.append(address)
            return canceled
        }
        let task = Task {
            defer { finished = true }
            return try await client.testConnection(addresses: [bluetooth, network]) { _, _ in }
        }
        await wait { canceled.receiving }
        task.cancel()
        await wait { closing }
        precondition(!finished && connections == [bluetooth])
        allowClose = true
        do { _ = try await task.value; fatalError("Canceled diagnostic passed") } catch is CancellationError {}
        precondition(finished && connections == [bluetooth])
        print("PASS: one-channel byte diagnostic, fragmented replies, route cleanup, Bluetooth-only restriction, corruption and cancellation")
    }
}
