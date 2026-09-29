// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelaySetupKit

@main
enum RelayBackgroundRefreshTests {
    @MainActor
    static func main() async {
        let refresh = RelayBackgroundRefresh()
        var state = SetupState()
        precondition(state.selectRelay(RelayAddress(bluetoothIdentifier: UUID(), name: "relay"), trusted: true))
        var release: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let polling = Task {
            await refresh.run {
                events.append("read")
                precondition(!state.busy && state.hasTrust)
                await withCheckedContinuation { release = $0 }
                precondition(Task.isCancelled)
                // Stand in for finishDisconnect: canceling alone is not enough.
                events.append("disconnected")
            }
        }
        while release == nil { await Task.yield() }
        await refresh.run { fatalError("Overlapping background connection") }
        precondition(!state.busy)
        let operation = state.beginNetworkSettings()!
        let foreground = Task {
            await refresh.cancelAndWait()
            events.append("foreground")
        }
        for _ in 0..<10 { await Task.yield() }
        precondition(events == ["read"])
        release!.resume()
        await foreground.value
        await polling.value
        precondition(events == ["read", "disconnected", "foreground"])
        precondition(state.succeed(operation))

        // Leaving the tab / opening a password sheet cancels the transport.
        release = nil
        var canceled = false
        let tab = Task {
            await refresh.run {
                await withCheckedContinuation { release = $0 }
                canceled = Task.isCancelled
            }
        }
        while release == nil { await Task.yield() }
        tab.cancel()
        release!.resume()
        await tab.value
        precondition(canceled && !state.busy)
        var restarted = false
        await refresh.run { restarted = true }
        precondition(restarted)
        print("PASS: nonblocking refresh, one connection, drained foreground cancellation and tab cancellation")
    }
}
