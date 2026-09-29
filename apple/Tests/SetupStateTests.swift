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
               "App update retains the existing Bluetooth Keychain account format")
        expect(address.keychainAccount == renamed.keychainAccount, "Name changes do not lose trust")
        expect(RelayAddress(bluetoothIdentifier: UUID(), name: "Test relay").keychainAccount != address.keychainAccount,
               "A different peripheral never inherits trust from its name")
        var state = SetupState()
        expect(state.step == .relay && !state.hasTrust, "Starts at relay selection")
        expect(state.beginButtonApproval() == nil, "No approval without a relay")
        expect(state.beginBluetoothTest() == nil, "No byte test without a relay")
        expect(state.beginObservation() == nil, "No readings without a trusted relay")
        expect(!state.prepareAuthorization(), "No premature authorization")
        expect(state.selectRelay(address), "Select Bluetooth relay")
        let tabletSetup = state.beginTabletSetup()!
        expect(!state.succeed(tabletSetup), "Tablet setup cannot approve a headset")
        expect(!state.prepareAuthorization(), "Finish tablet management before headset approval")
        expect(state.finishTabletSetup(tabletSetup), "Bootstrap tablet setup finishes independently")
        expect(!state.hasTrust, "Pairing a tablet does not grant headset trust")
        expect(!state.finishTabletSetup(tabletSetup), "Ignore stale tablet-setup completion")
        expect(state.prepareAuthorization(), "Prepare button approval")
        let first = state.beginButtonApproval()!
        expect(!state.selectRelay(renamed), "No endpoint switch in flight")
        expect(state.beginButtonApproval() == nil, "One pairing at a time")
        expect(!state.succeed(UUID()), "Ignore unrelated completion")
        state.cancel()
        expect(!state.busy && !state.hasTrust, "Cancellation cannot grant trust")
        expect(!state.succeed(first), "Ignore success after cancellation")
        let retry = state.beginButtonApproval()!
        state.fail(first, message: "stale failure")
        expect(state.operation == retry, "Stale error cannot cancel retry")
        state.fail(retry, message: "timeout")
        expect(!state.hasTrust, "Failure cannot save trust")
        let next = state.beginButtonApproval()!
        expect(state.succeed(next) && state.hasTrust, "Verified completion")
        expect(state.step == .complete && state.connectionVerified, "Success page")
        let check = state.beginCheck()!
        state.fail(check, message: "offline")
        expect(state.hasTrust && !state.connectionVerified, "Outage preserves trust")
        let reconnect = state.beginCheck()!
        expect(state.succeed(reconnect), "Reconnect existing identity")
        state.back()
        expect(state.step == .relay && !state.hasTrust, "Back clears only current UI selection")
        expect(state.selectRelay(address, trusted: true), "Restore saved endpoint")
        expect(state.step == .complete && !state.connectionVerified, "Saved trust is not a live connection")
        state.forget()
        expect(!state.hasTrust && state.step == .tablet, "Explicit local forget")
        expect(state.prepareAuthorization(), "Prepare fresh approval after forgetting")
        let approved = state.beginButtonApproval()!
        expect(state.succeed(approved), "Fresh approval completes")
        let observation = state.beginObservation()!
        expect(state.activity == .observing && state.busy, "One live observation at a time")
        expect(state.beginBluetoothTest() == nil, "No byte test during observation")
        state.verifyObservation(UUID())
        expect(!state.connectionVerified, "Ignore stale observation")
        state.verifyObservation(observation)
        expect(state.connectionVerified, "Authenticated observation verifies connection")
        state.cancel()
        state.verifyObservation(observation)
        expect(state.hasTrust && !state.connectionVerified, "Cancel retains trust and ignores late readings")
        let trustedTest = state.beginBluetoothTest()!
        expect(!state.succeed(trustedTest), "Byte echo cannot claim identity verification")
        expect(state.finishBluetoothTest(trustedTest), "Saved relay can run a byte test")
        expect(state.hasTrust && !state.connectionVerified, "Byte test preserves but does not verify trust")
        state.forget()
        let diagnostic = state.beginBluetoothTest()!
        expect(state.beginButtonApproval() == nil, "No pairing while byte test is active")
        expect(!state.succeed(diagnostic), "Byte test cannot create trust")
        expect(state.finishBluetoothTest(diagnostic), "Unpaired relay can finish byte test")
        expect(!state.hasTrust && !state.connectionVerified && state.step == .tablet, "No authorization from echo")
        let canceledTest = state.beginBluetoothTest()!
        state.cancel()
        let retriedTest = state.beginBluetoothTest()!
        expect(!state.finishBluetoothTest(canceledTest), "Ignore canceled echo completion")
        expect(state.operation == retriedTest, "Stale echo result cannot stop retry")
        state.cancel()
        print("PASS: \(checks) setup-state assertions")
    }
}
