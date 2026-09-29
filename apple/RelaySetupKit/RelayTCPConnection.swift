// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@preconcurrency import Network

@MainActor
final class RelayTCPConnection: RelayByteConnection {
    private let endpoint: NWEndpoint
    private let channel: UInt8
    private var connection: NWConnection?
    private var waiter: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var closed = false

    init(endpoint: NWEndpoint, channel: UInt8 = 0) {
        self.endpoint = endpoint
        self.channel = channel
    }

    func connect() async throws {
        try Task.checkCancellation()
        guard connection == nil, !closed else { throw RelaySetupError.invalidState }
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.enableKeepalive = true
        let socket = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: options))
        connection = socket
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter = continuation
            socket.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.changed(state) }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.fail(RelaySetupError.timedOut)
            }
            socket.start(queue: .main)
        }
        var preface = Data("PLTRTCP1".utf8)
        preface.append(channel)
        try await send(preface)
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            deadline?.cancel()
            let pending = waiter; waiter = nil
            pending?.resume()
        case .failed(let error): fail(RelaySetupError.network(error.localizedDescription))
        case .cancelled: fail(CancellationError())
        case .waiting(let error):
            if case .dns(let code) = error, code == -65570 {
                fail(RelaySetupError.network("Allow Local Network access for PLANK AVP Relay Setup in Settings."))
            }
        default: break
        }
    }

    private func fail(_ error: any Error) {
        deadline?.cancel()
        let pending = waiter; waiter = nil
        closed = true
        connection?.cancel()
        pending?.resume(throwing: error)
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !closed, let connection, data.count <= 16384 else { throw RelaySetupError.network("Network connection closed.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: RelaySetupError.network(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        try Task.checkCancellation()
        guard !closed, let connection else { throw RelaySetupError.network("Network connection closed.") }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if let error { continuation.resume(throwing: RelaySetupError.network(error.localizedDescription)) }
                else { continuation.resume(throwing: RelaySetupError.network(complete ? "Relay closed the network connection." : "No network data received.")) }
            }
        }
    }

    nonisolated func cancel() {
        Task { @MainActor in self.fail(CancellationError()) }
    }

    func finishDisconnect() async { fail(CancellationError()) }
}
