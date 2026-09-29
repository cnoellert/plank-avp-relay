// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

@MainActor
public final class SetupCoordinator: ObservableObject {
    @Published public private(set) var state = SetupState()
    @Published public private(set) var message = "Scan for the relay beside your tablet."
    @Published public private(set) var peerVersion: String?
    @Published public private(set) var readings: TabletReadings?
    @Published public private(set) var readingCount = 0
    @Published public private(set) var bluetoothTestResult: String?
    @Published public private(set) var tabletStatus: TabletSetupStatus?
    @Published public private(set) var tabletCommandPending = false
    public let scanner = RelayBLEScanner()
    private let keys = RelayKeyStore()
    private let client = RelayPairingClient()
    private var task: Task<Void, Never>?
    private var tabletCommand: (String, String?)?

    public init() {}

    public func selectBluetoothRelay(_ relay: BluetoothRelay) {
        guard !state.busy else { return }
        scanner.stop()
        bluetoothTestResult = nil
        let address = RelayAddress(bluetoothIdentifier: relay.id, name: relay.name)
        do {
            let trusted = try keys.relayKey(address) != nil
            guard state.selectRelay(address, trusted: trusted) else { return }
            message = trusted ? "Saved pairing found. Start live readings to verify the relay and tablet." :
                "Pair a tablet to finish setting up this headset and relay."
            tabletStatus = nil
            if !trusted { manageTablets() }
        } catch { message = error.localizedDescription }
    }

    public func manageTablets() {
        guard let address = state.address, let id = state.beginTabletSetup() else { return }
        tabletStatus = nil
        tabletCommand = nil
        tabletCommandPending = false
        message = "Checking the relay’s saved tablets…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let relayKey = self.state.hasTrust ? try self.keys.relayKey(address) : nil
                let privateKey = try self.keys.clientKey()
                let completedEnrollment = try await self.client.manageTablets(address: address, privateKey: privateKey, relayKey: relayKey,
                    onIdentity: { key in try self.keys.rememberSetupRelay(key, address: address) },
                    expectedIdentity: try self.keys.setupRelayKey(address),
                    onAuthorized: { [weak self] key in
                        guard let self, self.state.operation == id, !Task.isCancelled else { throw CancellationError() }
                        try self.keys.saveRelay(key, address: address)
                        _ = self.state.authorizeTabletSetup(id)
                    }, nextCommand: { [weak self] in
                        guard let self, self.state.operation == id else { return nil }
                        let command = self.tabletCommand
                        self.tabletCommand = nil
                        return command
                    }, onStatus: { [weak self] status in
                        guard let self, self.state.operation == id else { return }
                        self.tabletStatus = status
                        // An earlier status poll must not acknowledge a command
                        // queued while that poll was in flight.
                        if self.tabletCommand == nil { self.tabletCommandPending = false }
                        self.message = status.message
                    }, onProgress: { [weak self] message in
                        guard let self, self.state.operation == id else { return }
                        self.message = message
                    })
                guard self.state.finishTabletSetup(id) else { return }
                self.task = nil
                self.tabletCommandPending = false
                if completedEnrollment { self.startReadings() }
                return
            } catch is CancellationError {
                guard self.state.operation == id else { return }
                _ = self.state.finishTabletSetup(id)
                self.message = "Tablet setup closed. Saved pairings are retained."
            } catch {
                guard self.state.operation == id else { return }
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
            }
            guard self.state.operation == nil else { return }
            self.task = nil
            self.tabletCommandPending = false

        }
    }

    public func tabletOperation(_ operation: String, tablet: String? = nil) {
        guard state.activity == .managingTablets, !tabletCommandPending,
              tabletStatus?.operating != true else { return }
        tabletCommand = (operation, tablet)
        tabletCommandPending = true
    }

    public func finishTabletSetup() {
        guard state.activity == .managingTablets else { return }
        message = "Closing tablet setup…"
        task?.cancel()
    }

    public func checkConnection() {
        guard let address = state.address, let id = state.beginCheck() else { return }
        message = "Checking the saved relay identity…"
        peerVersion = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let relayKey = try self.keys.relayKey(address) else {
                    throw RelaySetupError.invalidStoredKey
                }
                let version = try await self.client.check(address: address,
                    privateKey: self.keys.clientKey(), relayKey: relayKey)
                try Task.checkCancellation()
                guard self.state.operation == id else { return }
                self.peerVersion = version
                _ = self.state.succeed(id)
                self.message = "Saved identity verified. The diagnostic connection is now closed; no tablet was claimed."
            } catch {
                guard self.state.operation == id else { return }
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
            }
            self.task = nil
        }
    }

    public func testBluetooth() {
        guard let address = state.address, let id = state.beginBluetoothTest() else { return }
        bluetoothTestResult = nil
        message = "Starting a Bluetooth byte test. No tablet is needed."
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.testBluetooth(address: address) { [weak self] message in
                    guard let self, self.state.operation == id else { return }
                    self.message = message
                }
                try Task.checkCancellation()
                guard self.state.finishBluetoothTest(id) else { return }
                self.bluetoothTestResult = result
                self.message = "Bluetooth communication passed in both directions."
            } catch {
                guard self.state.operation == id else { return }
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
            }
            self.task = nil
        }
    }

    public func cancel() {
        if state.activity == .managingTablets {
            finishTabletSetup()
            return
        }
        scanner.stop()
        task?.cancel()
        task = nil
        state.cancel()
        readings = nil
        bluetoothTestResult = nil
        message = "Operation canceled. Existing pairing was not removed."
    }

    public func pauseForInactivity() {
        scanner.stop()
        if state.busy {
            cancel()
            message = "Setup paused while the app is inactive. Retry when you return."
        }
    }

    public func startReadings() {
        guard let address = state.address, let id = state.beginObservation() else { return }
        readings = nil
        readingCount = 0
        message = "Verifying the relay and starting live tablet readings…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let relayKey = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                try await self.client.observe(address: address, privateKey: self.keys.clientKey(), relayKey: relayKey,
                    onProgress: { [weak self] message in
                        guard let self, self.state.operation == id else { return }
                        self.message = message
                    }) {
                    [weak self] sample in
                    guard let self, self.state.operation == id else { return }
                    self.state.verifyObservation(id)
                    self.readings = sample
                    self.readingCount += 1
                    self.message = sample.attached ? "Receiving live tablet readings over Bluetooth." :
                        "The relay is connected. The tablet is offline; wake it to resume input. Pairing is retained."
                }
            } catch {
                guard self.state.operation == id else { return }
                self.readings = nil
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
            }
            self.task = nil
        }
    }

    public func back() {
        state.back()
        bluetoothTestResult = nil
        message = "Choose the next setup step."
    }

}
