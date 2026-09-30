// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main
@MainActor
enum SetupStateTests {
    static var checks = 0
    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }
    static func main() {
        let identifier = UUID(uuidString: "A1234567-89AB-CDEF-0123-456789ABCDEF")!
        let address = RelayAddress(bluetoothIdentifier: identifier, name: "Test relay")
        let renamed = RelayAddress(bluetoothIdentifier: identifier, name: "Renamed relay")
        expect(address.keychainAccount == "relay-ble-v1:a1234567-89ab-cdef-0123-456789abcdef",
               "App updates retain the existing Bluetooth Keychain account format")
        expect(address.keychainAccount == renamed.keychainAccount, "Rename retains identity")
        expect(RelayAddress(bluetoothIdentifier: UUID(), name: "Test relay").keychainAccount != address.keychainAccount,
               "Matching names do not confer trust")
        var state = SetupState()
        expect(state.step == .relay && !state.hasTrust, "Starts at relay discovery")
        expect(state.beginTabletSetup() == nil && state.beginObservation() == nil, "A relay must be selected")
        expect(state.selectRelay(address), "Select relay")
        expect(state.step == .tablet && !state.hasTrust, "Tablet setup precedes authorization")
        let canceled = state.beginTabletSetup()!
        expect(!state.succeed(canceled), "Ordinary setup success cannot grant trust")
        expect(state.finishTabletSetup(canceled), "Setup can close before completion")
        expect(!state.hasTrust, "Closing without relay confirmation never authorizes")
        expect(!state.authorizeTabletSetup(canceled), "Late authorization after close ignored")
        let failed = state.beginTabletSetup()!
        state.fail(failed, message: "Tablet failed verification")
        expect(!state.hasTrust && state.beginObservation() == nil, "Failed tablet setup cannot enable readings")
        let enrollment = state.beginTabletSetup()!
        expect(!state.authorizeTabletSetup(failed), "Earlier session cannot approve new session")
        expect(!state.selectRelay(renamed), "Cannot switch relay during setup")
        expect(state.authorizeTabletSetup(enrollment), "Verified relay approval grants trust in the same setup")
        expect(state.hasTrust && state.step == .complete, "No separate button approval page")
        expect(!state.hasTablet, "Headset authorization alone does not make a tablet available")
        state.updateTabletAvailability(true, operation: failed)
        expect(!state.hasTablet, "A stale status cannot enable live readings")
        state.updateTabletAvailability(true, operation: enrollment)
        expect(state.beginObservation() == nil, "Finish setup transport before readings")
        expect(state.finishTabletSetup(enrollment), "Close setup after both bonds complete")
        expect(state.hasTrust && !state.connectionVerified, "Enrollment is not a live input sample")
        let observation = state.beginObservation()!
        state.verifyObservation(UUID())
        expect(!state.connectionVerified, "Ignore stale readings")
        state.verifyObservation(observation)
        expect(state.connectionVerified, "Authenticated readings verify the live connection")
        expect(state.stopObservation(), "Stopping an active test reserves its connection until teardown")
        expect(state.activity == .stoppingObservation && state.busy, "Stop remains busy while disconnecting")
        expect(state.beginNetworkSettings() == nil && state.beginObservation() == nil, "Network and another test cannot overlap teardown")
        expect(!state.stopObservation(), "Repeated stop requests are harmless")
        state.verifyObservation(observation)
        expect(!state.connectionVerified, "Late samples cannot revive a stopping test")
        expect(!state.finishObservation(UUID()), "Stale teardown cannot release the current operation")
        expect(state.finishObservation(observation), "Disconnect releases the test reservation")
        expect(state.hasTrust && state.hasTablet && state.address == address && !state.connectionVerified,
               "Stopping retains selection, tablet availability and ownership")
        let networkAfterTest = state.beginNetworkSettings()!
        expect(!state.finishObservation(observation), "A late test completion cannot cancel the Network operation")
        expect(state.succeed(networkAfterTest), "Network is usable after the test disconnects")
        let connectingTest = state.beginObservation()!
        expect(state.stopObservation() && state.finishObservation(connectingTest), "A test can be stopped before its first sample")

        // Removing every tablet and adding another is management, not re-approval.
        let replacement = state.beginTabletSetup()!
        expect(state.hasTrust, "Tablet management preserves headset ownership")
        expect(!state.hasTablet, "Reopening management requires fresh tablet status")
        state.updateTabletAvailability(false, operation: replacement)
        expect(state.finishTabletSetup(replacement), "Close after removing a tablet")
        expect(state.hasTrust && state.step == .complete, "No table-button dependency after removal")
        expect(!state.canObserve && state.beginObservation() == nil, "Removing the final tablet blocks readings without clearing ownership")
        let network = state.beginNetworkSettings()!
        expect(state.succeed(network), "Network controls remain usable with no paired tablet")
        let retry = state.beginTabletSetup()!
        state.fail(retry, message: "Replacement tablet offline")
        expect(state.hasTrust, "Replacement failure preserves ownership")
        let recovered = state.beginTabletSetup()!
        expect(state.finishTabletSetup(recovered), "Owner can reopen setup and add a replacement")

        let diagnostic = state.beginBluetoothTest()!
        expect(!state.authorizeTabletSetup(diagnostic), "Byte test cannot approve a headset")
        expect(!state.succeed(diagnostic), "Byte echo cannot verify saved identity")
        expect(state.finishBluetoothTest(diagnostic), "Close diagnostic")
        state.back()
        expect(state.step == .relay && !state.hasTrust, "Back clears selection only")
        expect(state.selectRelay(address, trusted: true), "Restore saved pairing on discovery")
        expect(state.step == .complete, "Normal reconnect skips setup")
        expect(!state.canObserve && state.beginObservation() == nil, "Cached headset trust cannot enable readings before tablet status is checked")
        let check = state.beginCheck()!
        state.fail(check, message: "Offline")
        expect(state.hasTrust, "Radio outage preserves ownership")
        let nextCheck = state.beginCheck()!
        expect(state.succeed(nextCheck), "Check verifies saved identity")
        expect(!state.canObserve, "Verifying authorization still does not imply a paired tablet")
        let tabletCheck = state.beginCheck()!
        state.updateTabletAvailability(true, operation: tabletCheck)
        expect(state.succeed(tabletCheck) && state.canObserve, "A selected saved tablet permits readings after the check closes")
        state.back()
        expect(state.selectRelay(address), "Reopen with lost local relay key")
        let restoration = state.beginTabletSetup()!
        expect(state.authorizeTabletSetup(restoration), "Same private headset identity restores relay approval")
        expect(state.finishTabletSetup(restoration) && state.hasTrust, "Restoration does not require a tablet button")
        print("PASS: \(checks) combined setup, replacement, cancellation and recovery assertions")
    }
}
