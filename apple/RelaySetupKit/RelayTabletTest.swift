// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@MainActor
protocol RelayTabletTestClient {
    func tabletStatus(address: RelayAddress, privateKey: Data, relayKey: Data) async throws -> TabletSetupStatus
    func observe(address: RelayAddress, privateKey: Data, relayKey: Data,
                 onProgress: ((String) -> Void)?, onSample: (TabletReadings) -> Void) async throws
}

extension RelayPairingClient: RelayTabletTestClient {}

/// Uses the existing authenticated status request followed by observation.
/// Address learning never introduces a separate startup connection.
@MainActor
struct RelayTabletTest {
    let client: any RelayTabletTestClient
    var retryDelay: Duration = .seconds(1)

    func run(addresses: [RelayAddress], transport: RelayTestTransport,
             privateKey: Data, relayKey: Data,
             onStatus: (RelayAddress, TabletSetupStatus) throws -> Void,
             onProgress: @escaping (RelayAddress, String) -> Void,
             onRetry: (RelayAddress) -> Void,
             onSample: (RelayAddress, TabletReadings) -> Void) async throws {
        let allowed = try transport.candidates(addresses)
        let candidates = RelayControlRoutes.fallbackOrder(allowed)
        var preferred: RelayAddress?
        var recoveries = 0
        while true {
            // Recovery starts with the route that actually delivered readings.
            // Initial route failures do not spend this separate recovery budget.
            let ordered = RelayControlRoutes.fallbackOrder(preferred.map { last in
                [last] + candidates.filter { $0 != last }
            } ?? candidates)
            for attempt in 0..<4 {
                try Task.checkCancellation()
                let address = ordered[attempt % ordered.count]
                var receivedReadings = false
                do {
                    onProgress(address, "Verifying the relay and starting live tablet readings…")
                    let status = try await client.tabletStatus(address: address,
                        privateKey: privateKey, relayKey: relayKey)
                    try Task.checkCancellation()
                    try onStatus(address, status)
                    guard status.headsetAuthorized == true else {
                        throw RelaySetupError.rejected("This relay has not authorized the headset. Set up a tablet to finish authorization.")
                    }
                    guard status.captureBusy != true else {
                        throw RelaySetupError.rejected(TabletSetupStatus.captureBusyGuidance)
                    }
                    guard status.canStartReadings else {
                        throw RelaySetupError.rejected("Connect a USB tablet, or pair and select a Bluetooth tablet before testing.")
                    }
                    try await client.observe(address: address, privateKey: privateKey, relayKey: relayKey,
                        onProgress: { onProgress(address, $0) }) { sample in
                            receivedReadings = true
                            onSample(address, sample)
                        }
                    try Task.checkCancellation()
                    return
                } catch {
                    try Task.checkCancellation()
                    guard let failure = error as? RelaySetupError else { throw error }
                    switch failure { case .network, .timedOut: break; default: throw error }
                    if receivedReadings {
                        guard recoveries < 3 else { throw error }
                        recoveries += 1
                        preferred = address
                    } else {
                        guard attempt < 3 else { throw error }
                    }
                    // Both requests complete teardown before throwing. Never
                    // overlap a failed session with the next connection.
                    onRetry(address)
                    try await Task.sleep(for: retryDelay)
                    if receivedReadings { break }
                }
            }
        }
    }
}
