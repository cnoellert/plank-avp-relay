// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Only a disconnect before the reply subscription is ready can be retried.
/// No pairing, authorization or input protocol bytes have been sent yet.
struct RelayBLEStartupDisconnect: LocalizedError {
    let reason: String
    var errorDescription: String? { "Relay connection failed: \(reason)" }
}

@MainActor
protocol RelayBLEAttemptConnection: AnyObject, Sendable {
    func connect(until deadline: ContinuousClock.Instant) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    nonisolated func cancel()
    func finishDisconnect() async
}

/// CoreBluetooth can attach to a physical link whose previous session is still
/// closing. Start a fresh attempt after that disconnect, within the original
/// deadline. Each attempt owns its delegates, so late callbacks stay isolated.
@MainActor
final class RelayBLEConnection: RelayByteConnection {
    private let makeAttempt: () -> any RelayBLEAttemptConnection
    private let onProgress: ((String) -> Void)?
    private var attempt: (any RelayBLEAttemptConnection)?
    private var closed = false

    init(makeAttempt: @escaping () -> any RelayBLEAttemptConnection,
         onProgress: ((String) -> Void)? = nil) {
        self.makeAttempt = makeAttempt
        self.onProgress = onProgress
    }

    func connect() async throws {
        try Task.checkCancellation()
        guard !closed, attempt == nil else { throw RelaySetupError.invalidState }
        let deadline = ContinuousClock.now + .seconds(20)
        for number in 0...1 {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let current = makeAttempt()
            attempt = current
            do {
                try await current.connect(until: deadline)
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                return
            } catch {
                await current.finishDisconnect()
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                guard number == 0, error is RelayBLEStartupDisconnect,
                      ContinuousClock.now < deadline else { throw error }
                onProgress?("The previous Bluetooth link closed. Reconnecting to the relay…")
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !closed, let attempt else { throw RelaySetupError.invalidState }
        try await attempt.send(data)
    }

    func receive() async throws -> Data {
        guard !closed, let attempt else { throw RelaySetupError.invalidState }
        return try await attempt.receive()
    }

    nonisolated func cancel() {
        Task { @MainActor in
            self.closed = true
            self.attempt?.cancel()
        }
    }

    func finishDisconnect() async {
        closed = true
        await attempt?.finishDisconnect()
    }
}
