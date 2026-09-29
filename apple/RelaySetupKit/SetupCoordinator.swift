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
    @Published public private(set) var relayIdentityChanged = false
    @Published public private(set) var networkStatus: RelayNetworkStatus?
    @Published public private(set) var networkMessage = "Select and authorize a relay to manage its network mode."
    @Published public private(set) var wifiStatus: RelayWifiStatus?
    @Published public private(set) var wifiAvailable: [RelayWifiNetwork] = []
    @Published public private(set) var wifiSaved: [RelayWifiNetwork] = []
    @Published public private(set) var wifiMessage = "Open Network to manage the relay’s Wi-Fi."
    @Published public private(set) var wifiAvailableNext: Int?
    @Published public private(set) var wifiSavedNext: Int?
    private var wifiAvailableGeneration = ""
    private var wifiSavedGeneration = ""
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
        relayIdentityChanged = false
        networkStatus = nil
        wifiStatus = nil
        wifiAvailable = []; wifiSaved = []
        wifiAvailableNext = nil; wifiSavedNext = nil
        wifiAvailableGeneration = ""; wifiSavedGeneration = ""
        wifiMessage = "Open Network to manage the relay’s Wi-Fi."
        networkMessage = "Open Network to check the selected relay’s settings."
        do {
            let trusted = try keys.relayKey(address) != nil
            guard state.selectRelay(address, trusted: trusted) else { return }
            message = trusted ? "Checking the relay’s saved authorization and tablets…" :
                "Pair a tablet to finish setting up this headset and relay."
            tabletStatus = nil
            if trusted { refreshTabletStatus() } else { manageTablets() }
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
                        self.state.updateTabletAvailability(status.canStartReadings, operation: id)
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
                if let error = error as? RelaySetupError, case .identityChanged = error { self.relayIdentityChanged = true }
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

    public func refreshTabletStatus() {
        guard let address = state.address, let id = state.beginCheck() else { return }
        state.updateTabletAvailability(false, operation: id)
        tabletStatus = nil
        message = "Checking whether the relay has a tablet…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let address = try await self.availableAddress(address)
                guard let relayKey = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                let status = try await self.client.tabletStatus(address: address,
                    privateKey: self.keys.clientKey(), relayKey: relayKey)
                try Task.checkCancellation()
                guard self.state.operation == id else { return }
                self.state.useAddress(address, operation: id)
                self.tabletStatus = status
                if status.headsetAuthorized != true {
                    self.state.cancel()
                    self.state.forget()
                    self.message = "This relay has not authorized the headset. Set up a tablet to finish authorization."
                } else {
                    self.state.updateTabletAvailability(status.canStartReadings, operation: id)
                    _ = self.state.succeed(id)
                    self.message = status.canStartReadings ? "Tablet found. Start live readings to check its input." :
                        "Pair or select a tablet before starting live readings."
                }
            } catch {
                guard self.state.operation == id else { return }
                if let error = error as? RelaySetupError, case .identityChanged = error { self.relayIdentityChanged = true }
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
            }
            self.task = nil
        }
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

    public func forgetSelectedRelay() {
        guard !state.busy, let address = state.address else { return }
        do {
            try keys.forgetRelay(addresses.isEmpty ? [address] : addresses)
            state.forget()
            relayIdentityChanged = false
            tabletStatus = nil
            readings = nil
            networkStatus = nil
            wifiStatus = nil
            wifiAvailable = []; wifiSaved = []
            wifiAvailableNext = nil; wifiSavedNext = nil
            wifiAvailableGeneration = ""; wifiSavedGeneration = ""
            message = "Saved relay identity forgotten. Set up a tablet on this relay again."
            manageTablets()
        } catch { message = error.localizedDescription }
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
        if state.activity == .managingNetwork {
            networkMessage = "Status monitoring stopped. An accepted network change continues on the relay; refresh to check it."
            wifiMessage = networkMessage
        }
        scanner.stop()
        task?.cancel()
        task = nil
        state.cancel()
        readings = nil
        bluetoothTestResult = nil
        message = "Operation canceled. Existing pairing was not removed."
    }

    public func refreshNetworkSettings() { networkSettings(mode: nil, refreshWifiLists: true) }
    public func pollNetworkSettings() { networkSettings(mode: nil) }

    public func applyNetworkMode(_ mode: RelayNetworkMode) {
        guard networkStatus?.canChange == true, networkStatus?.mode != mode else { return }
        networkSettings(mode: mode)
    }

    private func networkSettings(mode: RelayNetworkMode?, refreshWifiLists: Bool = false) {
        guard let address = state.address, let id = state.beginNetworkSettings() else { return }
        let request = mode == nil ? nil : UUID().uuidString.lowercased()
        networkMessage = mode == nil ? "Reading connection status…" : "Changing network mode…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let key = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                let privateKey = try self.keys.clientKey()
                // Prefer BLE control so changing the USB subnet does not break
                // the command connection. All candidates must prove this key.
                var candidates = self.addresses.isEmpty ? [address] : self.addresses
                candidates.sort { $0.linkType < $1.linkType }
                var selected: RelayAddress?
                var wifi: RelayWifiStatus?
                var lastError: any Error = RelaySetupError.timedOut
                for candidate in candidates {
                    do {
                        if mode == nil {
                            let statuses = try await self.client.networkAndWifiStatus(address: candidate, privateKey: privateKey, relayKey: key)
                            self.networkStatus = statuses.0; wifi = statuses.1
                        } else {
                            self.networkStatus = try await self.client.networkSettings(address: candidate, privateKey: privateKey, relayKey: key)
                        }
                        try Task.checkCancellation()
                        selected = candidate
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard Self.transportFailure(error) else { throw error }
                        lastError = error
                    }
                }
                guard let selected else { throw lastError }
                self.state.useAddress(selected, operation: id)
                if let mode, let request {
                    try Task.checkCancellation()
                    do {
                        self.networkStatus = try await self.client.networkSettings(address: selected, privateKey: privateKey,
                            relayKey: key, mode: mode, requestID: request)
                    } catch {
                        try Task.checkCancellation()
                        guard Self.transportFailure(error) else { throw error }
                        // The relay may have committed before its reply was
                        // lost. Only poll status; never resend this mutation.
                    }
                    self.networkMessage = "Changing network mode… Reconnecting to the same relay."
                    self.scanner.start()
                    defer { self.scanner.stop() }
                    let deadline = ContinuousClock.now + .seconds(90)
                    var attempt = 0
                    while ContinuousClock.now < deadline {
                        try await Task.sleep(for: .seconds(2))
                        for relay in self.scanner.relays {
                            for candidate in relay.addresses where candidate.advertisedKey == key && !candidates.contains(candidate) {
                                candidates.append(candidate)
                            }
                        }
                        let candidate = candidates[attempt % candidates.count]
                        attempt += 1
                        do {
                            let status = try await self.client.networkSettings(address: candidate, privateKey: privateKey, relayKey: key)
                            try Task.checkCancellation()
                            self.networkStatus = status
                            if status.confirms(request, mode: mode) {
                                self.state.useAddress(candidate, operation: id)
                                self.addresses = candidates
                                self.networkMessage = "\(mode.title) mode saved."
                                _ = self.state.succeed(id)
                                self.task = nil
                                return
                            }
                            if status.requestID == request && status.phase == "failed" {
                                throw RelaySetupError.rejected(status.message)
                            }
                        } catch {
                            try Task.checkCancellation()
                            guard Self.transportFailure(error) else { throw error }
                        }
                    }
                    throw RelaySetupError.rejected("The mode change has not been confirmed. Reconnect and refresh its status before trying again.")
                } else {
                    self.networkMessage = self.networkStatus?.message ?? "Connection status refreshed."
                    do {
                        if let wifi {
                            try await self.readWifi(selected, privateKey: privateKey, relayKey: key, lists: refreshWifiLists, status: wifi)
                        } else {
                            self.wifiStatus = nil
                            self.wifiMessage = "Update the relay to use Wi-Fi controls."
                        }
                    } catch {
                        try Task.checkCancellation()
                        self.wifiMessage = "Wi-Fi settings could not be read. Check that the relay is updated, then refresh."
                    }
                }
                _ = self.state.succeed(id)
            } catch is CancellationError {
                guard self.state.operation == id else { return }
                self.state.cancel()
                self.networkMessage = "Status monitoring stopped. An accepted network change continues on the relay; refresh to check it."
            } catch {
                guard self.state.operation == id else { return }
                self.networkMessage = error.localizedDescription
                self.state.fail(id, message: error.localizedDescription)
            }
            guard self.state.operation == nil else { return }
            self.task = nil
        }
    }

    private func readWifi(_ address: RelayAddress, privateKey: Data, relayKey: Data, lists: Bool, status supplied: RelayWifiStatus? = nil) async throws {
        let previous = self.wifiStatus
        let status: RelayWifiStatus
        if let supplied { status = supplied }
        else { status = try await self.client.wifiStatus(address: address, privateKey: privateKey, relayKey: relayKey) }
        try Task.checkCancellation()
        self.wifiStatus = status
        self.wifiMessage = status.message
        if status.supported && (lists || wifiAvailableGeneration.isEmpty || previous?.requestID != status.requestID || previous?.phase != status.phase) {
            let pages = try await self.client.wifiLists(address: address, privateKey: privateKey, relayKey: relayKey)
            try Task.checkCancellation()
            self.wifiAvailable = pages.0.networks; self.wifiSaved = pages.1.networks
            self.wifiAvailableGeneration = pages.0.generation; self.wifiSavedGeneration = pages.1.generation
            self.wifiAvailableNext = pages.0.next; self.wifiSavedNext = pages.1.next
        }
    }

    public func performWifi(_ action: RelayWifiAction) {
        guard wifiStatus?.canChange == true else { return }
        wifiOperation(action: action)
    }

    public func moreWifiNetworks(saved: Bool) {
        guard let offset = saved ? wifiSavedNext : wifiAvailableNext else { return }
        wifiOperation(page: (saved ? "saved" : "available", offset, saved ? wifiSavedGeneration : wifiAvailableGeneration))
    }

    private func wifiOperation(action: RelayWifiAction? = nil, page: (String, Int, String)? = nil) {
        guard let address = state.address, let id = state.beginNetworkSettings() else { return }
        let request = UUID().uuidString.lowercased()
        wifiMessage = action == nil ? "Reading networks…" : "Applying Wi-Fi settings…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let key = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                let privateKey = try self.keys.clientKey()
                var candidates = self.addresses.isEmpty ? [address] : self.addresses
                candidates.sort { $0.linkType < $1.linkType }
                var selected: RelayAddress?
                var failure: any Error = RelaySetupError.timedOut
                for candidate in candidates {
                    do {
                        self.wifiStatus = try await self.client.wifiStatus(address: candidate, privateKey: privateKey, relayKey: key)
                        try Task.checkCancellation()
                        selected = candidate; break
                    } catch {
                        try Task.checkCancellation()
                        guard Self.transportFailure(error) else { throw error }
                        failure = error
                    }
                }
                guard let selected else { throw failure }
                self.state.useAddress(selected, operation: id)
                if let page {
                    let result = try await self.client.wifiPage(address: selected, privateKey: privateKey, relayKey: key,
                                                              kind: page.0, offset: page.1, generation: page.2)
                    try Task.checkCancellation()
                    guard result.generation == page.2, result.next == nil || result.next! > page.1 else { throw RelaySetupError.protocolError }
                    if page.0 == "saved" {
                        self.wifiSaved += result.networks.filter { row in !self.wifiSaved.contains(where: { $0.id == row.id }) }
                        self.wifiSavedNext = result.next
                    } else {
                        self.wifiAvailable += result.networks.filter { row in !self.wifiAvailable.contains(where: { $0.id == row.id }) }
                        self.wifiAvailableNext = result.next
                    }
                    self.wifiMessage = "Network list updated."
                } else if let action {
                    try Task.checkCancellation()
                    do {
                        self.wifiStatus = try await self.client.wifiStatus(address: selected, privateKey: privateKey,
                                                                         relayKey: key, action: action, request: request)
                    } catch {
                        try Task.checkCancellation()
                        guard Self.transportFailure(error) else { throw error }
                        // Never repeat a mutation after an ambiguous lost reply.
                    }
                    self.scanner.start()
                    defer { self.scanner.stop() }
                    let deadline = ContinuousClock.now + .seconds(100)
                    var attempt = 0
                    var confirmed = false
                    while ContinuousClock.now < deadline {
                        try await Task.sleep(for: .seconds(2))
                        for relay in self.scanner.relays {
                            for endpoint in relay.addresses where endpoint.advertisedKey == key && !candidates.contains(endpoint) { candidates.append(endpoint) }
                        }
                        let endpoint = candidates[attempt % candidates.count]; attempt += 1
                        do {
                            let status = try await self.client.wifiStatus(address: endpoint, privateKey: privateKey, relayKey: key)
                            try Task.checkCancellation()
                            self.wifiStatus = status; self.wifiMessage = status.message
                            if status.confirms(request) {
                                self.state.useAddress(endpoint, operation: id)
                                self.addresses = candidates
                                try await self.readWifi(endpoint, privateKey: privateKey, relayKey: key, lists: true)
                                confirmed = true; break
                            }
                            if status.requestID == request && status.phase == "failed" { throw RelaySetupError.rejected(status.message) }
                        } catch {
                            try Task.checkCancellation()
                            guard Self.transportFailure(error) else { throw error }
                        }
                    }
                    guard confirmed else { throw RelaySetupError.rejected("Wi-Fi change has not been confirmed. Refresh its status before trying again.") }
                }
                _ = self.state.succeed(id)
            } catch is CancellationError {
                guard self.state.operation == id else { return }
                self.state.cancel()
                self.wifiMessage = "Stopped waiting. An accepted Wi-Fi change continues on the relay."
            } catch {
                guard self.state.operation == id else { return }
                self.wifiMessage = error.localizedDescription
                self.state.fail(id, message: error.localizedDescription)
            }
            guard self.state.operation == nil else { return }
            self.task = nil
        }
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
                        let status = try await self.client.tabletStatus(address: candidate,
                            privateKey: self.keys.clientKey(), relayKey: relayKey)
                        try Task.checkCancellation()
                        guard self.state.operation == id else { return }
                        self.tabletStatus = status
                        self.state.updateTabletAvailability(status.canStartReadings, operation: id)
                        if status.headsetAuthorized != true {
                            self.state.cancel()
                            self.state.forget()
                            self.message = "This relay has not authorized the headset. Set up a tablet to finish authorization."
                            self.task = nil
                            return
                        }
                        guard status.canStartReadings else {
                            throw RelaySetupError.rejected("Pair or select a tablet before starting live readings.")
                        }
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
        relayIdentityChanged = false
        bluetoothTestResult = nil
        message = "Choose the next setup step."
    }

}
