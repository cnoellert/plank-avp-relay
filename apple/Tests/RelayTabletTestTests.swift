// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

@MainActor
private final class Client: RelayTabletTestClient {
    let key = Data(repeating: 0x12, count: 32)
    var calls: [(String, RelayAddress)] = []
    var status: TabletSetupStatus
    var statusError: (RelayAddress) -> (any Error)? = { _ in nil }
    var stream: @MainActor (RelayAddress, (TabletReadings) -> Void) async throws -> Void = { _, _ in }

    init(_ changes: [String: Any] = [:]) throws {
        let fields: [String: Any] = ["version": 1, "id": 1, "ok": true,
            "hostname": "relay", "phase": "idle", "message": "Ready", "canManage": true,
            "initialSetup": false, "attached": true, "secondsRemaining": 0,
            "tablets": [], "candidates": [], "headsetAuthorized": true,
            "enrollmentVersion": 1, "relayKey": String(repeating: "12", count: 32)]
        status = try TabletSetupStatus.decode(JSONSerialization.data(withJSONObject:
            fields.merging(changes) { _, new in new }), request: 1)
    }

    func tabletStatus(address: RelayAddress, privateKey: Data, relayKey: Data) async throws -> TabletSetupStatus {
        precondition(relayKey == key)
        calls.append(("status", address))
        if let error = statusError(address) { throw error }
        return status
    }

    func observe(address: RelayAddress, privateKey: Data, relayKey: Data,
                 onProgress: ((String) -> Void)?, onSample: (TabletReadings) -> Void) async throws {
        precondition(relayKey == key)
        calls.append(("observe", address))
        try await stream(address, onSample)
    }

    func run(_ addresses: [RelayAddress], transport: RelayTestTransport = .automatic,
             retryDelay: Duration = .zero, onRetry: @escaping () -> Void = {}) async throws {
        try await RelayTabletTest(client: self, retryDelay: retryDelay).run(
            addresses: addresses, transport: transport,
            privateKey: Data(repeating: 41, count: 32), relayKey: key,
            onStatus: { _, _ in }, onProgress: { _, _ in },
            onRetry: { _ in onRetry() }, onSample: { _, _ in })
    }
}

@main
enum RelayTabletTestTests {
    @MainActor static func main() async throws {
        let bluetooth = RelayAddress(bluetoothIdentifier: UUID(), name: "relay")
        let network = (1...8).map {
            RelayAddress(wifiHost: "192.0.2.\($0)", port: 28991, name: "relay", key: Data(repeating: 0x12, count: 32))
        }
        let sample = try TabletReadings(data: Data([1] + Array(repeating: 0, count: 79)))

        // Startup is exactly one existing status request and observation, even
        // with fresh advertised addresses. No separate discovery request.
        for changes: [String: Any] in [[:], ["networkAddresses": network.compactMap(\.networkHost), "tcpPort": 28991]] {
            let direct = try Client(changes)
            try await direct.run([network[0], bluetooth])
            precondition(direct.calls.map(\.0) == ["status", "observe"])
            precondition(direct.calls.allSatisfy { $0.1 == network[0] })
        }

        // Eight unreachable IPs cannot starve a usable Bluetooth connection.
        let fallback = try Client()
        fallback.statusError = { $0.linkType == 1 ? nil : RelaySetupError.timedOut }
        try await fallback.run(network + [bluetooth])
        precondition(fallback.calls.map(\.1) == [network[0], network[1], bluetooth, bluetooth])
        precondition(fallback.calls.map(\.0) == ["status", "status", "status", "observe"])

        // An observer failing before its first sample is still a startup failure.
        let beforeReadings = try Client()
        beforeReadings.stream = { address, _ in
            if address.linkType != 1 { throw RelaySetupError.network("No readings") }
        }
        try await beforeReadings.run(network + [bluetooth])
        precondition(beforeReadings.calls.filter { $0.0 == "observe" }.map(\.1) == [network[0], network[1], bluetooth])

        // Initial failures leave a separate recovery budget. Reconnect the
        // working Bluetooth route first instead of probing stale TCP addresses.
        let recovery = try Client()
        recovery.statusError = fallback.statusError
        var streams = 0
        recovery.stream = { address, receive in
            precondition(address == bluetooth)
            streams += 1
            receive(sample)
            if streams == 1 { throw RelaySetupError.network("Stream interrupted") }
        }
        try await recovery.run(network + [bluetooth])
        precondition(streams == 2)
        precondition(recovery.calls.map(\.1) == [network[0], network[1], bluetooth, bluetooth, bluetooth, bluetooth])

        // If that working route disappears, recovery can use another route.
        let changed = try Client()
        var vanished = false
        changed.statusError = { $0 == network[0] && vanished ? RelaySetupError.timedOut : nil }
        changed.stream = { address, receive in
            receive(sample)
            if address == network[0] { vanished = true; throw RelaySetupError.timedOut }
        }
        try await changed.run([network[0], network[1], bluetooth])
        precondition(changed.calls.map(\.1) == [network[0], network[0], network[0], network[1], network[1]])

        // Exhaustion is bounded with and without an available Bluetooth route.
        for routes in [network + [bluetooth], network, [bluetooth]] {
            let offline = try Client()
            offline.statusError = { _ in RelaySetupError.timedOut }
            do { try await offline.run(routes); fatalError("Unavailable routes passed") }
            catch RelaySetupError.timedOut {}
            precondition(offline.calls.count == 4)
            if routes.contains(bluetooth) { precondition(offline.calls.contains { $0.1 == bluetooth }) }
        }
        let flapping = try Client()
        flapping.stream = { _, receive in receive(sample); throw RelaySetupError.timedOut }
        do { try await flapping.run([bluetooth]); fatalError("Unbounded stream recovery") }
        catch RelaySetupError.timedOut {}
        precondition(flapping.calls.filter { $0.0 == "observe" }.count == 4)

        // Authorization, identity and capture contention never trigger fallback.
        for fields: [String: Any] in [["headsetAuthorized": false], ["captureBusy": true], ["attached": false]] {
            let rejected = try Client(fields)
            do { try await rejected.run(network + [bluetooth]); fatalError("Rejected status started readings") }
            catch RelaySetupError.rejected {}
            precondition(rejected.calls.count == 1)
        }
        let wrong = try Client()
        wrong.statusError = { _ in RelaySetupError.identityChanged }
        do { try await wrong.run(network + [bluetooth]); fatalError("Identity mismatch retried") }
        catch RelaySetupError.identityChanged {}
        precondition(wrong.calls.count == 1)

        if RelayTestTransport.isAvailable {
            let restricted = try Client()
            restricted.statusError = { address in
                precondition(address == bluetooth)
                return RelaySetupError.timedOut
            }
            do { try await restricted.run(network + [bluetooth], transport: .bluetoothOnly); fatalError("Bluetooth-only escaped") }
            catch RelaySetupError.timedOut {}
            precondition(restricted.calls.count == 4)
            let absent = try Client()
            do { try await absent.run(network, transport: .bluetoothOnly); fatalError("Missing Bluetooth accepted") }
            catch RelaySetupError.network {}
            precondition(absent.calls.isEmpty)
        }

        let canceled = try Client()
        canceled.statusError = { _ in RelaySetupError.timedOut }
        var retrying = false
        let task = Task { try await canceled.run(network + [bluetooth], retryDelay: .seconds(60)) { retrying = true } }
        while !retrying { await Task.yield() }
        task.cancel()
        do { try await task.value; fatalError("Canceled startup retried") } catch is CancellationError {}
        precondition(canceled.calls.count == 1)

        // Preserve a recently working route's priority and remove duplicates.
        let ranked = RelayControlRoutes.fallbackOrder([network[4], network[4]] + network + [bluetooth])
        precondition(ranked.first == network[4] && ranked[2] == bluetooth && ranked.count == 9)
        precondition(RelayControlRoutes.fallbackOrder([bluetooth] + network).first == bluetooth)
        print("PASS: direct tablet startup, bounded network/Bluetooth fallback, independent recovery, trust, capture ownership and cancellation")
    }
}
