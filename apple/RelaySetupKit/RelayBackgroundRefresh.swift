// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Read-only refreshes do not reserve the foreground workflow. Foreground
// operations drain cancellation, including transport disconnect, before using
// the relay's single authorized connection.
@MainActor
public final class RelayBackgroundRefresh {
    private var pending: Task<Void, Never>?
    private var generation: UUID?

    public init() {}

    public func run(_ operation: @escaping @MainActor () async -> Void) async {
        guard pending == nil, !Task.isCancelled else { return }
        let id = UUID()
        let refresh = Task { if !Task.isCancelled { await operation() } }
        pending = refresh
        generation = id
        await withTaskCancellationHandler {
            await refresh.value
        } onCancel: {
            refresh.cancel()
        }
        if generation == id { pending = nil; generation = nil }
    }

    public func cancel() { pending?.cancel() }

    public func cancelAndWait() async {
        let refresh = pending
        let id = generation
        refresh?.cancel()
        await refresh?.value
        if generation == id { pending = nil; generation = nil }
    }
}
