// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

@MainActor
private final class Gate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class Attempt: RelayBLEAttemptConnection {
    var connectError: (any Error)?
    var receiveError: (any Error)?
    var deadlines: [ContinuousClock.Instant] = []
    var writes: [Data] = []
    var disconnects = 0
    var onDisconnect: (() async -> Void)?

    func connect(until deadline: ContinuousClock.Instant) async throws {
        deadlines.append(deadline)
        if let connectError { throw connectError }
    }
    func send(_ data: Data) async throws { writes.append(data) }
    func receive() async throws -> Data {
        if let receiveError { throw receiveError }
        return Data([42])
    }
    nonisolated func cancel() {}
    func finishDisconnect() async {
        disconnects += 1
        await onDisconnect?()
    }
}

@MainActor
private final class SlowDisconnect: RelayByteConnection {
    let receiving = Gate(), closing = Gate(), allowClose = Gate()
    func connect() async throws {}
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data {
        receiving.open()
        try await Task.sleep(for: .seconds(60))
        return Data()
    }
    nonisolated func cancel() {}
    func finishDisconnect() async {
        closing.open()
        await allowClose.wait()
    }
}

@main
enum RelayConnectionTests {
    @MainActor static func main() async throws {
        // Reproduce the observed ordering: a new session attaches to the old
        // physical link, which disconnects before its GATT subscription is ready.
        let old = Attempt(), fresh = Attempt()
        old.connectError = RelayBLEStartupDisconnect(reason: "Previous link closed")
        var attempts = 0, messages: [String] = []
        let connection = RelayBLEConnection(makeAttempt: {
            attempts += 1
            if attempts == 1 { return old }
            precondition(old.disconnects == 1, "Finish the old attempt before creating the next")
            return fresh
        }, onProgress: { messages.append($0) })
        try await connection.connect()
        precondition(attempts == 2 && messages.count == 1)
        precondition(old.deadlines == fresh.deadlines, "Recovery must not extend the startup deadline")
        try await connection.send(Data([1, 2, 3]))
        let reply = try await connection.receive()
        precondition(reply == Data([42]) && old.writes.isEmpty && fresh.writes == [Data([1, 2, 3])])

        // A stream failure after startup never replays authorization or samples.
        fresh.receiveError = RelayBLEStartupDisconnect(reason: "Already delivering protocol data")
        do {
            _ = try await connection.receive()
            fatalError("An established stream failure must reach its caller")
        } catch is RelayBLEStartupDisconnect {}
        precondition(attempts == 2)
        await connection.finishDisconnect()

        // Two startup disconnects fail; there is no unbounded retry loop.
        let unavailable = Attempt()
        unavailable.connectError = RelayBLEStartupDisconnect(reason: "Still unavailable")
        var failures = 0
        let bounded = RelayBLEConnection(makeAttempt: { failures += 1; return unavailable })
        do {
            try await bounded.connect()
            fatalError("A second startup failure must be reported")
        } catch is RelayBLEStartupDisconnect {}
        precondition(failures == 2 && unavailable.disconnects == 2)

        // Unsupported services, permission errors and timeouts are not a signal
        // to silently repeat the operation.
        for error in [RelaySetupError.network("Missing relay service"), .protocolError, .timedOut] {
            let rejected = Attempt()
            rejected.connectError = error
            var count = 0
            let socket = RelayBLEConnection(makeAttempt: { count += 1; return rejected })
            do {
                try await socket.connect()
                fatalError("A non-disconnect failure must be reported")
            } catch {}
            precondition(count == 1 && rejected.disconnects == 1)
        }

        // Cancel while teardown is suspended: no replacement connection starts.
        let cleanupStarted = Gate(), allowCleanup = Gate()
        let canceled = Attempt()
        canceled.connectError = RelayBLEStartupDisconnect(reason: "Previous link closed")
        canceled.onDisconnect = { cleanupStarted.open(); await allowCleanup.wait() }
        var canceledAttempts = 0
        let socket = RelayBLEConnection(makeAttempt: { canceledAttempts += 1; return canceled })
        let task = Task { try await socket.connect() }
        await cleanupStarted.wait()
        task.cancel()
        allowCleanup.open()
        do {
            try await task.value
            fatalError("Cancellation must stop recovery")
        } catch is CancellationError {}
        precondition(canceledAttempts == 1)
        // A canceled tablet stream must finish disconnect before the caller
        // can release the relay to Network, even if teardown is asynchronous.
        let draining = SlowDisconnect(), client = RelayPairingClient()
        var finished = false
        let observation = Task {
            do {
                _ = try await client.bounded(socket: draining, seconds: 60) {
                    try await draining.connect()
                    return try await draining.receive()
                }
                fatalError("Canceled observation succeeded")
            } catch is CancellationError {} catch { fatalError("Unexpected cancellation error") }
            finished = true
        }
        await draining.receiving.wait()
        observation.cancel()
        await draining.closing.wait()
        precondition(!finished, "Network must wait for transport teardown")
        draining.allowClose.open()
        await observation.value
        precondition(finished)
        print("PASS: early disconnect recovery, shared deadline, no protocol replay, bounded failures, cancellation and drained observation teardown")
    }
}
