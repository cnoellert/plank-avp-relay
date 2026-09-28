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
        let address = RelayAddress(host: "relay.example", port: "28990")!
        expect(SetupState().mode == .live, "App opens directly in live mode")
        var state = SetupState(mode: .simulation)
        expect(state.mode == .simulation, "Explicit preview remains isolated")
        expect(state.beginPairing(code: [1, 2, 3, 4, 5]) == nil, "No endpoint")
        expect(!state.prepareAuthorization(), "No premature authorization")
        expect(RelayAddress(host: "https://relay.example", port: "28990") == nil, "Reject URL")
        expect(RelayAddress(host: "relay.example", port: "0") == nil, "Reject zero port")
        expect(RelayAddress(host: "relay.example", port: "65536") == nil, "Reject oversized port")
        expect(RelayAddress(host: "", port: "28990") == nil, "Reject empty host")
        expect(RelayAddress(host: "[]", port: "28990") == nil, "Reject empty bracketed host")
        expect(RelayAddress(host: "[[::1]]", port: "28990") == nil, "Reject nested brackets")
        expect(RelayAddress(host: "relay example", port: "28990") == nil, "Reject whitespace")
        expect(RelayAddress(host: "[2001:db8::1]", port: "28990")?.description == "[2001:db8::1]:28990", "IPv6")
        expect(RelayAddress(host: " Relay.Example ", port: "28990") == address, "Normalize host")
        expect(state.selectRelay(address), "Select relay")
        expect(state.chooseConnection(.bluetooth), "Simulation Bluetooth")
        expect(state.prepareAuthorization(), "Prepare pairing")
        expect(state.beginPairing(code: [1, 2, 3]) == nil, "Require five presses")
        expect(state.beginPairing(code: [1, 2, 3, 4, 9]) == nil, "Reject nonexistent ExpressKey")
        let first = state.beginPairing(code: [1, 2, 3, 4, 8])!
        expect(!state.selectRelay(address), "No endpoint switch in flight")
        expect(state.beginPairing(code: [1, 2, 3, 4, 5]) == nil, "One pairing at a time")
        expect(!state.succeed(UUID()), "Ignore unrelated completion")
        state.cancel()
        expect(state.code.isEmpty && !state.busy && !state.hasTrust, "Cancel clears sensitive UI")
        expect(!state.succeed(first), "Ignore success after cancellation")
        let retry = state.beginPairing(code: [8, 8, 2, 2, 1])!
        state.fail(first, message: "stale failure")
        expect(state.operation == retry, "Stale error cannot cancel retry")
        state.fail(retry, message: "timeout")
        expect(!state.hasTrust && state.code.isEmpty, "Failure cannot save trust")
        let next = state.beginPairing(code: [8, 8, 2, 2, 1])!
        expect(state.succeed(next) && state.hasTrust, "Verified completion")
        expect(state.step == .complete && state.connectionVerified, "Success page")
        let check = state.beginCheck()!
        state.fail(check, message: "offline")
        expect(state.hasTrust && !state.connectionVerified, "Outage preserves trust")
        let reconnect = state.beginCheck()!
        expect(state.succeed(reconnect), "Reconnect existing identity")
        state.forget()
        expect(!state.hasTrust && state.step == .tablet, "Explicit local forget")
        state.changeMode(.live)
        expect(state.step == .relay && state.address == nil && !state.hasTrust, "No simulated trust in live mode")
        expect(state.selectRelay(address), "Live endpoint")
        expect(!state.chooseConnection(.bluetooth), "Legacy TCP pairing remains USB-only")
        expect(state.chooseConnection(.usb), "Live USB")
        expect(state.prepareAuthorization(), "Live manual prerequisite")
        let live = state.beginPairing(code: [1, 1, 1, 1, 1])!
        state.changeMode(.simulation)
        expect(!state.succeed(live), "Mode switch invalidates pending live result")
        expect(state.selectRelay(address, trusted: true), "Restore trusted endpoint")
        expect(state.step == .complete && !state.connectionVerified, "Stored trust is not a live connection")
        state.back()
        expect(state.step == .relay && !state.hasTrust, "Back forgets only current UI selection")
        state.changeMode(.live)
        let bluetooth = RelayAddress(bluetoothIdentifier: UUID(), name: "Test relay")
        expect(bluetooth.linkType == 1 && address.linkType == 2, "Transport-specific crypto binding")
        expect(bluetooth.keychainAccount != address.keychainAccount, "Transport-specific trust lookup")
        expect(state.selectRelay(bluetooth, trusted: true), "Select saved Bluetooth relay")
        state.forget()
        expect(state.prepareAuthorization(), "Prepare button approval")
        let canceledApproval = state.beginButtonApproval()!
        expect(state.code.isEmpty, "Button approval has no challenge sequence")
        expect(state.beginButtonApproval() == nil, "Only one pending approval")
        state.cancel()
        expect(!state.succeed(canceledApproval), "Late approval cannot persist after cancellation")
        let approved = state.beginButtonApproval()!
        expect(state.succeed(approved), "Current approval completes")
        let observation = state.beginObservation()!
        expect(state.activity == .observing && state.busy, "One live observation at a time")
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
        expect(state.hasTrust && !state.connectionVerified, "Byte test preserves but does not verify saved trust")
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
        state.changeMode(.simulation)
        expect(state.beginObservation() == nil, "Simulation cannot start live readings")
        expect(state.beginBluetoothTest() == nil, "No simulated Bluetooth test")
        print("PASS: \(checks) setup-state assertions")
    }
}
