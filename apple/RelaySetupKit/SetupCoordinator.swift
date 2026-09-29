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
    public let scanner = RelayScanner()
    private var addresses: [RelayAddress] = []
    private let keys = RelayKeyStore()
    private let client = RelayPairingClient()
    private var task: Task<Void, Never>?
    private var tabletCommand: (String, String?)?

    public init() {}

    public func selectRelay(_ relay: AvailableRelay) {
        guard !state.busy, let address = relay.addresses.first else { return }
        addresses = relay.addresses
        scanner.stop()
        bluetoothTestResult = nil
        do {
            let trusted = try keys.relayKey(address) != nil
            guard state.selectRelay(address, trusted: trusted) else { return }
            message = trusted ? "Saved pairing found. Start live readings to verify the relay and tablet." :
                "Pair a tablet to finish setting up this headset and relay."
            tabletStatus = nil
            if !trusted { manageTablets() }
        } catch { message = error.localizedDescription }
    }

    // Probe only read-only status during transport selection. Never replay a
    // tablet mutation when a setup session is interrupted.
    private func availableAddress(_ selected: RelayAddress) async throws -> RelayAddress {
        let expected = try keys.setupRelayKey(selected) ?? selected.advertisedKey
        var failure: any Error = RelaySetupError.timedOut
        for address in addresses.isEmpty ? [selected] : addresses {
            do {
                let status = try await client.setupStatus(address) { [weak self] in self?.message = $0 }
                guard let key = status.enrollmentIdentity else { throw RelaySetupError.protocolError }
                if let advertised = address.advertisedKey, key != advertised { throw RelaySetupError.identityChanged }
                if let expected, key != expected { throw RelaySetupError.identityChanged }
                if let saved = try keys.setupRelayKey(address), key != saved { throw RelaySetupError.identityChanged }
                return address
            } catch {
                try Task.checkCancellation()
                guard Self.transportFailure(error) else { throw error }
                failure = error
            }
        }
        throw failure
    }

    private static func transportFailure(_ error: any Error) -> Bool {
        guard let error = error as? RelaySetupError else { return false }
        switch error { case .network, .timedOut: return true; default: return false }
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
                let address = try await self.availableAddress(address)
                self.state.useAddress(address, operation: id)
                let relayKey = try self.keys.relayKey(address)
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
        message = "Starting a connection test. No tablet is needed."
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let address = try await self.availableAddress(address)
                self.state.useAddress(address, operation: id)
                let result = try await self.client.testBluetooth(address: address) { [weak self] message in
                    guard let self, self.state.operation == id else { return }
                    self.message = message
                }
                try Task.checkCancellation()
                guard self.state.finishBluetoothTest(id) else { return }
                self.bluetoothTestResult = result
                self.message = "Communication passed in both directions over \(address.transportName)."
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
                let candidates = self.addresses.isEmpty ? [address] : self.addresses
                for attempt in 0..<4 {
                    let candidate = candidates[attempt % candidates.count]
                    self.state.useAddress(candidate, operation: id)
                    do {
                        try await self.client.observe(address: candidate, privateKey: self.keys.clientKey(), relayKey: relayKey,
                            onProgress: { [weak self] message in
                                guard let self, self.state.operation == id else { return }
                                self.message = message
                            }) { [weak self] sample in
                                guard let self, self.state.operation == id else { return }
                                self.state.verifyObservation(id)
                                self.readings = sample
                                self.readingCount += 1
                                self.message = sample.attached ? "Receiving live tablet readings over \(candidate.transportName)." :
                                    "The relay is connected. The tablet is offline; wake it to resume input. Pairing is retained."
                            }
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard self.state.operation == id, attempt < 3, Self.transportFailure(error) else { throw error }
                        self.readings = nil
                        self.message = "Connection interrupted. Reconnecting to the same authorized relay…"
                        try await Task.sleep(for: .seconds(1))
                    }
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
