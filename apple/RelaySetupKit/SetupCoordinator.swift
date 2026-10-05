// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

public enum RelayDiagnostic: Equatable, Sendable {
    case idle, running(String), passed(String), failed(String), canceled
}

@MainActor
public final class SetupCoordinator: ObservableObject {
    @Published public private(set) var state = SetupState()
    @Published public private(set) var message = "Scan for the relay beside your tablet."
    public let tabletTest = TabletTestReadings()
    @Published public private(set) var testTransport = RelayTestTransport.load()
    @Published public private(set) var tabletTestConnection: String?
    @Published public private(set) var connectionDiagnostic: RelayDiagnostic = .idle {
        didSet { connectionDiagnosticContext = Self.completed(connectionDiagnostic, transport: state.address?.transportName) }
    }
    @Published public private(set) var authorizationDiagnostic: RelayDiagnostic = .idle {
        didSet { authorizationDiagnosticContext = Self.completed(authorizationDiagnostic, transport: state.address?.transportName) }
    }
    /// When and over which transport a completed diagnostic ran. Results are
    /// shown as previous results and cleared when the relay or test
    /// transport changes.
    @Published public private(set) var connectionDiagnosticContext: RelayVerifiedConnection?
    @Published public private(set) var authorizationDiagnosticContext: RelayVerifiedConnection?
    /// The last Setup → Relay management exchange that actually completed.
    @Published public private(set) var setupConnectionVerified: RelayVerifiedConnection?
    @Published public private(set) var tabletStatus: TabletSetupStatus?
    /// Shown only after a PLANK launch could not be completed. Public
    /// endpoint metadata the user can act on; never a credential.
    @Published public private(set) var handoffFallback: String?
    @Published public private(set) var tabletCommandPending = false
    @Published public private(set) var relayIdentityChanged = false
    @Published public private(set) var networkStatus: RelayNetworkStatus?
    @Published public private(set) var networkConnectionMessage = "Connection not checked."
    @Published public private(set) var networkMessage = "Select and authorize a relay to manage its network mode."
    @Published public private(set) var wifiEnablePending: Bool?
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
    private let networkRefresh = RelayBackgroundRefresh()
    private var networkRoutes = RelayControlRoutes()
    private var wifiListsNeedRefresh = true
    private var tabletCommand: (String, String?)?
    private var handoffManagementIdentity: Data?

    public init() {}

    private static func completed(_ result: RelayDiagnostic, transport: String?) -> RelayVerifiedConnection? {
        switch result {
        case .passed, .failed: RelayVerifiedConnection(transport: transport ?? "Unknown", at: Date())
        case .idle, .running, .canceled: nil
        }
    }

    private func recordSetupConnection(_ address: RelayAddress) {
        setupConnectionVerified = RelayVerifiedConnection(transport: address.transportName, at: Date())
    }

    /// Setup → Relay, worded from evidence: connected only while an operation
    /// is running on a verified link, otherwise the last verified exchange.
    public var setupConnectionLabel: String {
        RelayConnectionLabels.setupConnection(selectedTransport: state.address?.transportName,
            lastVerified: setupConnectionVerified,
            operationConnected: state.busy && state.connectionVerified)
    }

    /// Every decoded status becomes published state here, so the handoff offer
    /// can never come from a status the rest of the UI is not showing.
    ///
    /// Only a status that proves the relay's saved identity may supply the
    /// `managementIdentity` the app link carries. Identities never substitute
    /// for one another, so this is kept separate from the drawing identity the
    /// descriptor names (contract §10.3).
    func acceptTabletStatus(_ status: TabletSetupStatus, relayKey: Data? = nil) {
        tabletStatus = status
        handoffManagementIdentity = status.headsetAuthorized == true && status.enrollmentIdentity != nil
            && status.enrollmentIdentity == relayKey ? relayKey : nil
        handoffFallback = nil
    }

    func clearTabletStatus() {
        tabletStatus = nil
        handoffManagementIdentity = nil
        handoffFallback = nil
    }

    private var drawingDescriptor: DrawingDescriptor? {
        guard let management = handoffManagementIdentity,
              case let .handoffReady(raw)? = tabletStatus?.drawingHandoff else { return nil }
        var descriptor = raw
        if raw.bluetoothAvailable {
            // Match the private Setup pin, never the display name. A Bluetooth
            // UUID is a rendezvous hint, not authority in PLANK.
            for address in ([state.address].compactMap { $0 } + addresses) where address.linkType == 1 {
                if (try? keys.setupRelayKey(address)) == management {
                    descriptor.bluetoothIdentifier = address.bluetoothIdentifier
                    break
                }
            }
        }
        guard !descriptor.routes.isEmpty || descriptor.bluetoothIdentifier != nil else { return nil }
        return descriptor
    }

    /// Setup offers the handoff only on `handoffReady`. Every other outcome
    /// shows its own specific reason, and a missing drawing service is never
    /// reported as an authorization problem (contract §11).
    public var handoffAction: DrawingHandoffAction {
        var outcome = handoffManagementIdentity == nil ? nil : tabletStatus?.drawingHandoff
        if case .handoffReady? = outcome {
            outcome = drawingDescriptor.map(DrawingHandoffOutcome.handoffReady) ?? .drawingUnavailable("listener.noUsableAddress")
        }
        return DrawingHandoffAction(outcome: outcome, activity: state.activity, busy: state.busy)
    }

    /// Hands the relay to PLANK as an app link carrying public metadata only.
    ///
    /// A running tablet test owns capture, so it is stopped and allowed to
    /// finish releasing before the link is opened. A launch that does not
    /// succeed changes nothing: no capture is retained, no pairing is reset and
    /// the ready outcome stands, so the user can simply try again.
    public func useInPLANK(open: @MainActor (URL) async -> Bool) async {
        guard handoffAction.available, let status = tabletStatus,
              let descriptor = drawingDescriptor else { return }
        handoffFallback = nil
        if state.activity == .observing || state.activity == .stoppingObservation {
            message = "Stopping the tablet test before handing off to PLANK…"
            stopTesting()
            await task?.value
            guard !state.busy else {
                handoffFallback = "The tablet test is still stopping. Run Use in PLANK again in a moment."
                return
            }
        }
        guard let identity = handoffManagementIdentity else {
            handoffFallback = "This relay’s saved authorization could not be confirmed, so nothing was handed off. Check headset authorization and try again."
            return
        }
        let link: DrawingHandoffLink
        do {
            link = try DrawingHandoff.link(descriptor: descriptor,
                displayName: DrawingHandoff.displayName(status.hostname), managementIdentity: identity)
        } catch {
            handoffFallback = "This relay’s drawing endpoint could not be put into a PLANK link, so nothing was handed off."
            return
        }
        message = "Opening PLANK with this relay’s drawing endpoint…"
        guard await open(link.url) else {
            handoffFallback = "PLANK did not open. Install or open PLANK on this headset, then run Use in PLANK again. Relays are added to PLANK only from here."
            message = "PLANK did not open. This relay is still set up and nothing changed."
            return
        }
        message = "PLANK was opened with this relay. First-time drawing registration returns here for your approval."
    }

    public func registerPLANK(_ inbox: DrawingEnrollmentInbox,
                              open: @escaping @MainActor (URL) async -> Bool) {
        guard !state.busy, !inbox.busy, inbox.live, let request = inbox.request,
              let target = inbox.target, let address = state.address,
              let operation = state.beginNetworkSettings() else {
            inbox.message = "Stop the current operation, then select and authorize the requested Relay."
            return
        }
        inbox.busy = true
        inbox.message = "Verifying the selected Relay…"
        task = Task { [weak self] in
            guard let self else { return }
            var preparedAddress: RelayAddress?
            var mutationAttempted = false
            var managementKey: Data?
            var privateKey: Data?
            do {
                await self.networkRefresh.cancelAndWait()
                guard let key = try self.keys.setupRelayKey(address),
                      key.map({ String(format: "%02x", $0) }).joined() == target.managementIdentity else {
                    throw DrawingRegistrationError.wrongRelay
                }
                try DrawingRegistrationReceipt.requirePending(request)
                managementKey = key
                let localKey = try self.keys.clientKey()
                privateKey = localKey
                try await self.client.withManagementSession {
                    var selected: RelayAddress?
                    var lastError: any Error = RelaySetupError.timedOut
                    for candidate in self.networkRoutes.ordered(self.addresses.isEmpty ? [address] : self.addresses) {
                        do {
                            let status = try await self.client.tabletStatus(address: candidate, privateKey: localKey, relayKey: key)
                            try Task.checkCancellation()
                            guard inbox.live, inbox.request == request, status.headsetAuthorized == true,
                                  status.enrollmentIdentity == key,
                                  case let .handoffReady(current) = status.drawingHandoff,
                                  current.drawingIdentity == target.descriptor.drawingIdentity else {
                                throw DrawingRegistrationError.wrongRelay
                            }
                            self.acceptTabletStatus(status, relayKey: key)
                            selected = candidate
                            break
                        } catch {
                            try Task.checkCancellation()
                            guard Self.transportFailure(error) else { throw error }
                            lastError = error
                        }
                    }
                    guard let selected else { throw lastError }
                    preparedAddress = selected
                    mutationAttempted = true
                    inbox.message = "Approving PLANK’s drawing key…"
                    // Exactly once. An ambiguous mutation is revoked, never
                    // retried on another route with the same request id.
                    try await self.client.prepareDrawingRegistration(address: selected, privateKey: localKey,
                        relayKey: key, request: request, drawingIdentity: target.descriptor.drawingIdentity)
                }
                try Task.checkCancellation()
                guard inbox.live, inbox.request == request else { throw DrawingRegistrationError.expired }
                try DrawingRegistrationReceipt.approve(request)
                _ = self.state.succeed(operation)
                inbox.message = "Opening PLANK to verify its drawing connection…"
                guard await open(request.url(reply: true)) else {
                    throw RelaySetupError.rejected("PLANK did not open. Registration was canceled; try again from Use in PLANK.")
                }
                inbox.busy = false
                inbox.dismiss(removeReceipt: false)
                self.message = "PLANK is verifying this Relay. No tablet button sequence is needed."
            } catch {
                // Revocation runs even if this operation was canceled. It is
                // authenticated and bounded; expiry remains the safety net if
                // the Relay can no longer be reached.
                if mutationAttempted, let selected = preparedAddress,
                   let key = managementKey, let localKey = privateKey {
                    await Task { @MainActor in
                        try? await self.client.prepareDrawingRegistration(address: selected, privateKey: localKey,
                            relayKey: key, request: request, drawingIdentity: target.descriptor.drawingIdentity, cancel: true)
                    }.value
                }
                if self.state.operation == operation { self.state.fail(operation, message: error.localizedDescription) }
                DrawingRegistrationReceipt.remove(request)
                inbox.busy = false
                inbox.message = error.localizedDescription + " Nothing was registered in PLANK."
            }
            if self.state.operation == nil { self.task = nil }
        }
    }

    public func setTestTransport(_ value: RelayTestTransport) {
        guard !state.busy, RelayTestTransport.isAvailable else { return }
        testTransport = value
        value.save()
        connectionDiagnostic = .idle
        authorizationDiagnostic = .idle
    }

    public func selectRelay(_ relay: AvailableRelay) {
        networkRefresh.cancel()
        guard !state.busy, let address = relay.addresses.first else { return }
        addresses = relay.addresses
        networkRoutes = RelayControlRoutes()
        wifiListsNeedRefresh = true
        scanner.stop()
        connectionDiagnostic = .idle
        authorizationDiagnostic = .idle
        relayIdentityChanged = false
        setupConnectionVerified = nil
        networkStatus = nil
        networkConnectionMessage = "Connection not checked."
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
                "Connect a USB tablet or pair a Bluetooth tablet to finish setup."
            clearTabletStatus()
            if trusted { refreshTabletStatus() } else { manageTablets() }
        } catch { message = error.localizedDescription }
    }

    // Probe only read-only status during transport selection. Never replay a
    // tablet mutation when a setup session is interrupted.
    // No default: Bluetooth-only testing must not silently fall back to
    // automatic when a caller forgets to pass its captured preference.
    private func availableAddress(_ selected: RelayAddress, testTransport: RelayTestTransport,
                                  onProgress: ((String) -> Void)? = nil) async throws -> RelayAddress {
        let expected = try keys.setupRelayKey(selected) ?? selected.advertisedKey
        var failure: any Error = RelaySetupError.timedOut
        let candidates = try testTransport.candidates(networkRoutes.ordered(
            addresses.isEmpty ? [selected] : addresses, preferBluetooth: false))
        for address in RelayControlRoutes.fallbackOrder(candidates) {
            do {
                let status = try await client.setupStatus(address) { [weak self] in
                    self?.message = $0
                    onProgress?($0)
                }
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

    private func networkConnected(_ address: RelayAddress) {
        recordSetupConnection(address)
        networkConnectionMessage = RelayConnectionLabels.setupConnectionTitle + ": " + setupConnectionLabel + "."
    }

    private func rememberNetworkRoutes(_ status: TabletSetupStatus, address: RelayAddress, relayKey: Data) {
        guard status.headsetAuthorized == true, let identity = status.enrollmentIdentity,
              identity == relayKey, status.networkAddresses != nil, status.tcpPort != nil else { return }
        // Replace previous literal hints after DHCP or interface changes. Keep
        // Bonjour and Bluetooth discovery, and bound learned routes to eight.
        addresses.removeAll { $0.networkHost != nil }
        for route in status.routes(name: address.description, relayKey: relayKey) where !addresses.contains(route) {
            addresses.append(route)
        }
    }

    public func manageTablets() {
        guard let address = state.address, let id = state.beginTabletSetup() else { return }
        clearTabletStatus()
        tabletCommand = nil
        tabletCommandPending = false
        message = "Checking the relay’s saved tablets…"
        task = Task { [weak self] in
            guard let self else { return }
            await self.networkRefresh.cancelAndWait()
            do {
                try Task.checkCancellation()
                // Commissioning may use any reachable route; this is not the
                // transport-restricted test path.
                let address = try await self.availableAddress(address, testTransport: .automatic)
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
                        let saved = try? self.keys.relayKey(address)
                        self.acceptTabletStatus(status, relayKey: saved)
                        self.recordSetupConnection(address)
                        if let saved {
                            self.rememberNetworkRoutes(status, address: address, relayKey: saved)
                        }
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
        guard tabletStatus?.captureBusy != true else {
            message = TabletSetupStatus.captureBusyGuidance
            return
        }
        tabletCommand = (operation, tablet)
        tabletCommandPending = true
    }

    public func finishTabletSetup() {
        guard state.activity == .managingTablets else { return }
        message = "Closing tablet setup…"
        task?.cancel()
    }

    public func refreshTabletStatus() {
        refreshTabletStatus(reportAuthorization: false)
    }

    public func checkAuthorization() {
        refreshTabletStatus(reportAuthorization: true)
    }

    private func refreshTabletStatus(reportAuthorization: Bool) {
        guard let address = state.address, let id = state.beginCheck() else { return }
        let transport = reportAuthorization ? testTransport : .automatic
        if !reportAuthorization {
            state.updateTabletAvailability(false, operation: id)
            clearTabletStatus()
        }
        message = reportAuthorization ? "Checking this headset’s saved approval on the relay…" :
            "Checking whether the relay has a tablet…"
        if reportAuthorization { authorizationDiagnostic = .running(message) }
        task = Task { [weak self] in
            guard let self else { return }
            await self.networkRefresh.cancelAndWait()
            do {
                try Task.checkCancellation()
                let address = try await self.availableAddress(address, testTransport: transport)
                guard let relayKey = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                let status = try await self.client.tabletStatus(address: address,
                    privateKey: self.keys.clientKey(), relayKey: relayKey)
                try Task.checkCancellation()
                guard self.state.operation == id else { return }
                self.state.useAddress(address, operation: id)
                self.acceptTabletStatus(status, relayKey: relayKey)
                self.recordSetupConnection(address)
                self.rememberNetworkRoutes(status, address: address, relayKey: relayKey)
                if status.headsetAuthorized != true {
                    self.state.cancel()
                    self.state.forget()
                    self.message = "This relay has not authorized the headset. Set up a tablet to finish authorization."
                    if reportAuthorization { self.authorizationDiagnostic = .failed(self.message) }
                } else {
                    self.state.updateTabletAvailability(status.canStartReadings, operation: id)
                    _ = self.state.succeed(id)
                    if reportAuthorization {
                        self.message = "The relay confirms this headset is authorized over \(address.transportName)."
                        self.authorizationDiagnostic = .passed(self.message)
                    } else {
                        self.message = status.captureBusy == true ? TabletSetupStatus.captureBusyGuidance :
                            status.canStartReadings ? "Tablet found. Choose Test Tablet to check its input." :
                                "Connect a USB tablet, or pair and select a Bluetooth tablet before testing."
                    }
                }
            } catch {
                guard self.state.operation == id else { return }
                if let error = error as? RelaySetupError, case .identityChanged = error { self.relayIdentityChanged = true }
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
                if reportAuthorization { self.authorizationDiagnostic = .failed(self.message) }
            }
            self.task = nil
        }
    }

    public func forgetSelectedRelay() {
        networkRefresh.cancel()
        guard !state.busy, let address = state.address else { return }
        do {
            try keys.forgetRelay(addresses.isEmpty ? [address] : addresses)
            state.forget()
            connectionDiagnostic = .idle
            authorizationDiagnostic = .idle
            relayIdentityChanged = false
            clearTabletStatus()
            tabletTest.reset()
            networkStatus = nil
            wifiStatus = nil
            wifiAvailable = []; wifiSaved = []
            wifiAvailableNext = nil; wifiSavedNext = nil
            wifiAvailableGeneration = ""; wifiSavedGeneration = ""
            message = "Saved relay identity forgotten. Set up a tablet on this relay again."
            manageTablets()
        } catch { message = error.localizedDescription }
    }

    public func testRelayConnection() {
        guard let address = state.address, let id = state.beginBluetoothTest() else { return }
        let transport = testTransport
        message = "Starting a connection test. No tablet is needed."
        connectionDiagnostic = .running(message)
        task = Task { [weak self] in
            guard let self else { return }
            await self.networkRefresh.cancelAndWait()
            do {
                try Task.checkCancellation()
                let candidates = try transport.candidates(self.networkRoutes.ordered(
                    self.addresses.isEmpty ? [address] : self.addresses, preferBluetooth: false))
                let (address, result) = try await self.client.testConnection(addresses: RelayControlRoutes.fallbackOrder(candidates)) { [weak self] candidate, message in
                    guard let self, self.state.operation == id else { return }
                    self.state.useAddress(candidate, operation: id)
                    self.message = message
                    self.connectionDiagnostic = .running(message)
                }
                try Task.checkCancellation()
                guard self.state.finishBluetoothTest(id) else { return }
                self.connectionDiagnostic = .passed("\(address.transportName): \(result)")
                self.message = "Communication passed in both directions over \(address.transportName)."
            } catch is CancellationError {
                guard self.state.finishBluetoothTest(id) else { return }
                self.connectionDiagnostic = .canceled
                self.message = "Connection test canceled. Existing pairing was not removed."
            } catch {
                guard self.state.operation == id else { return }
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
                self.connectionDiagnostic = .failed(self.message)
            }
            self.task = nil
        }
    }

    public func cancel() {
        networkRefresh.cancel()
        wifiEnablePending = nil
        if state.activity == .testingBluetooth {
            message = "Stopping the connection test…"
            connectionDiagnostic = .running(message)
            // Reserve the relay until the diagnostic finishes disconnecting.
            task?.cancel()
            return
        }
        if state.activity == .observing || state.activity == .stoppingObservation {
            stopTesting()
            return
        }
        if state.activity == .managingTablets {
            finishTabletSetup()
            return
        }
        if state.activity == .managingNetwork {
            networkMessage = "Status monitoring stopped. An accepted network change continues on the relay; refresh to check it."
            wifiMessage = networkMessage
            // Keep controls busy until the canceled connection has torn down.
            task?.cancel()
            return
        }
        scanner.stop()
        task?.cancel()
        task = nil
        if case .running = connectionDiagnostic { connectionDiagnostic = .canceled }
        if case .running = authorizationDiagnostic { authorizationDiagnostic = .canceled }
        state.cancel()
        tabletTest.reset()
        message = "Operation canceled. Existing pairing was not removed."
    }

    public func refreshNetworkSettings() { networkSettings(mode: nil, refreshWifiLists: true) }
    public func pollNetworkSettings() async {
        guard !state.busy, state.hasTrust, let address = state.address else { return }
        await networkRefresh.run { [weak self] in
            guard let self else { return }
            do {
                try await self.client.withManagementSession {
                    guard let key = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                    let privateKey = try self.keys.clientKey()
                    // Prefer the existing LAN for passive reads. Mutations retain
                    // their BLE preference so changing a subnet cannot lose the command.
                    let candidates = self.networkRoutes.ordered(self.addresses.isEmpty ? [address] : self.addresses,
                        preferBluetooth: false)
                    var failure: any Error = RelaySetupError.timedOut
                    for candidate in candidates {
                        do {
                            let statuses = try await self.client.networkAndWifiStatus(address: candidate,
                                privateKey: privateKey, relayKey: key)
                            try Task.checkCancellation()
                            guard !self.state.busy, self.state.address == address else { return }
                            self.networkStatus = statuses.0
                            self.networkMessage = statuses.0.message
                            self.networkRoutes.succeeded(candidate)
                            try await self.readWifi(candidate, privateKey: privateKey, relayKey: key, lists: false, status: statuses.1)
                            self.networkConnected(candidate)
                            return
                        } catch {
                            try Task.checkCancellation()
                            guard Self.transportFailure(error) else { throw error }
                            self.networkRoutes.failed(candidate)
                            self.networkConnectionMessage = "Reconnecting to the relay. Showing last confirmed settings."
                            failure = error
                        }
                    }
                    throw failure
                }
            } catch is CancellationError {
                // Leave the current status and the user's edits in place.
            } catch {
                guard !Task.isCancelled, !self.state.busy, self.state.address == address else { return }
                self.networkMessage = "Could not refresh: \(error.localizedDescription)"
                self.networkConnectionMessage = "Relay connection interrupted. Showing last confirmed settings; retrying automatically."
            }
        }
    }

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
            await self.networkRefresh.cancelAndWait()
            do {
                try await self.client.withManagementSession {
                    try Task.checkCancellation()
                    guard let key = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                    let privateKey = try self.keys.clientKey()
                    // Reads use TCP first. A mode change prefers Bluetooth because
                    // it can remove the network path carrying the command.
                    var candidates = self.networkRoutes.ordered(self.addresses.isEmpty ? [address] : self.addresses,
                        preferBluetooth: mode != nil)
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
                            self.networkRoutes.succeeded(candidate)
                            break
                        } catch {
                            try Task.checkCancellation()
                            guard Self.transportFailure(error) else { throw error }
                            self.networkRoutes.failed(candidate)
                            lastError = error
                        }
                    }
                    guard let selected else { throw lastError }
                    self.state.useAddress(selected, operation: id)
                    self.networkConnected(selected)
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
                        while ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(500))
                            for relay in self.scanner.relays {
                                for candidate in relay.addresses where candidate.advertisedKey == key && !candidates.contains(candidate) {
                                    candidates.append(candidate)
                                }
                            }
                            let candidate = self.networkRoutes.ordered(candidates)[0]
                            do {
                                let status = try await self.client.networkSettings(address: candidate, privateKey: privateKey, relayKey: key)
                                try Task.checkCancellation()
                                self.networkStatus = status
                                self.networkRoutes.succeeded(candidate)
                                if status.confirms(request, mode: mode) {
                                    self.state.useAddress(candidate, operation: id)
                                    self.networkConnected(candidate)
                                    self.addresses = candidates
                                    self.networkMessage = "\(mode.title) mode saved."
                                    return
                                }
                                if status.requestID == request && status.phase == "failed" {
                                    throw RelaySetupError.rejected(status.message)
                                }
                            } catch {
                                try Task.checkCancellation()
                                guard Self.transportFailure(error) else { throw error }
                                self.networkRoutes.failed(candidate)
                            }
                        }
                        throw RelaySetupError.rejected("The mode change has not been confirmed. Reconnect and refresh its status before trying again.")
                    } else {
                        self.networkMessage = self.networkStatus?.message ?? "Connection status refreshed."
                        do {
                            guard let wifi else { throw RelaySetupError.protocolError }
                            try await self.readWifi(selected, privateKey: privateKey, relayKey: key, lists: refreshWifiLists, status: wifi)
                        } catch {
                            try Task.checkCancellation()
                            self.wifiMessage = "Could not refresh Wi-Fi: \(error.localizedDescription)"
                        }
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
        // Keep Wi-Fi as a separate, identity-pinned route. Bonjour can retain
        // the removed Ethernet address for minutes after a USB cable change.
        if status.supported && status.phase != "unavailable" {
            self.addresses.removeAll { $0.networkHost != nil }
            for route in status.routes(name: address.description, relayKey: relayKey) where !self.addresses.contains(route) {
                self.addresses.append(route)
            }
        }
        if lists || wifiAvailableGeneration.isEmpty || previous?.requestID != status.requestID || previous?.phase != status.phase {
            wifiListsNeedRefresh = true
        }
        if status.supported && wifiListsNeedRefresh {
            let pages = try await self.client.wifiLists(address: address, privateKey: privateKey, relayKey: relayKey)
            try Task.checkCancellation()
            self.wifiAvailable = pages.0.networks; self.wifiSaved = pages.1.networks
            self.wifiAvailableGeneration = pages.0.generation; self.wifiSavedGeneration = pages.1.generation
            self.wifiAvailableNext = pages.0.next; self.wifiSavedNext = pages.1.next
            self.wifiListsNeedRefresh = false
        }
    }

    public func performWifi(_ action: RelayWifiAction) {
        guard wifiStatus?.canChange == true else {
            wifiMessage = wifiStatus?.message ?? "Select an authorized relay and refresh its Wi-Fi status."
            return
        }
        wifiOperation(action: action)
    }

    public func moreWifiNetworks(saved: Bool) {
        guard let offset = saved ? wifiSavedNext : wifiAvailableNext else { return }
        wifiOperation(page: (saved ? "saved" : "available", offset, saved ? wifiSavedGeneration : wifiAvailableGeneration))
    }

    private func wifiOperation(action: RelayWifiAction? = nil, page: (String, Int, String)? = nil) {
        guard let address = state.address, let id = state.beginNetworkSettings() else {
            wifiMessage = state.busy ? "Finish the current relay operation before changing Wi-Fi." :
                "Select a relay and finish tablet setup to authorize Wi-Fi controls."
            return
        }
        if case .enable(let enabled)? = action { wifiEnablePending = enabled }
        let request = UUID().uuidString.lowercased()
        switch action {
        case .scan:
            wifiMessage = "Scanning for nearby networks…"
            wifiAvailable = []
            wifiAvailableNext = nil
            wifiAvailableGeneration = ""
        case .join, .connect: wifiMessage = "Connecting to the selected network…"
        case .forget: wifiMessage = "Forgetting the network…"
        case .enable(let enabled): wifiMessage = enabled ? "Enabling Wi-Fi…" : "Disabling Wi-Fi…"
        case nil: wifiMessage = "Reading networks…"
        }
        task = Task { [weak self] in
            guard let self else { return }
            await self.networkRefresh.cancelAndWait()
            do {
                try await self.client.withManagementSession {
                    try Task.checkCancellation()
                    guard let key = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                    let privateKey = try self.keys.clientKey()
                    let changesLink: Bool
                    switch action {
                    case .enable, .join, .connect, .forget: changesLink = true
                    default: changesLink = false
                    }
                    var candidates = self.networkRoutes.ordered(self.addresses.isEmpty ? [address] : self.addresses,
                        preferBluetooth: changesLink)
                    var selected: RelayAddress?
                    var failure: any Error = RelaySetupError.timedOut
                    for candidate in candidates {
                        do {
                            self.wifiStatus = try await self.client.wifiStatus(address: candidate, privateKey: privateKey, relayKey: key)
                            try Task.checkCancellation()
                            selected = candidate
                            self.networkRoutes.succeeded(candidate)
                            break
                        } catch {
                            try Task.checkCancellation()
                            guard Self.transportFailure(error) else { throw error }
                            self.networkRoutes.failed(candidate)
                            failure = error
                        }
                    }
                    guard let selected else { throw failure }
                    self.state.useAddress(selected, operation: id)
                    self.networkConnected(selected)
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
                        var confirmed = false
                        while ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(500))
                            for relay in self.scanner.relays {
                                for endpoint in relay.addresses where endpoint.advertisedKey == key && !candidates.contains(endpoint) { candidates.append(endpoint) }
                            }
                            let endpoint = self.networkRoutes.ordered(candidates)[0]
                            do {
                                let status = try await self.client.wifiStatus(address: endpoint, privateKey: privateKey, relayKey: key)
                                try Task.checkCancellation()
                                self.wifiStatus = status; self.wifiMessage = status.message
                                self.networkRoutes.succeeded(endpoint)
                                if status.confirms(request) {
                                    self.state.useAddress(endpoint, operation: id)
                                    self.networkConnected(endpoint)
                                    self.addresses = candidates
                                    try await self.readWifi(endpoint, privateKey: privateKey, relayKey: key, lists: true, status: status)
                                    confirmed = true; break
                                }
                                if status.requestID == request && status.phase == "failed" { throw RelaySetupError.rejected(status.message) }
                            } catch {
                                try Task.checkCancellation()
                                guard Self.transportFailure(error) else { throw error }
                                self.networkRoutes.failed(endpoint)
                            }
                        }
                        guard confirmed else { throw RelaySetupError.rejected("Wi-Fi change has not been confirmed. Refresh its status before trying again.") }
                    }
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
            self.wifiEnablePending = nil
            self.task = nil
        }
    }

    public func pauseForInactivity() {
        networkRefresh.cancel()
        scanner.stop()
        if state.busy {
            cancel()
            message = "Setup paused while the app is inactive. Retry when you return."
        }
    }

    public func stopTesting() {
        guard state.stopObservation() else { return }
        tabletTest.reset()
        tabletTestConnection = nil
        message = "Stopping tablet test…"
        task?.cancel()
        // Keep state.busy until observe/preflight has completed disconnect.
        // Relay selection and Network refresh wait for this reservation to end.
    }

    public func startReadings() {
        guard tabletStatus?.captureBusy != true else {
            message = TabletSetupStatus.captureBusyGuidance
            return
        }
        guard let address = state.address, let id = state.beginObservation() else { return }
        let transport = testTransport
        tabletTest.reset()
        tabletTestConnection = nil
        message = "Verifying the relay and starting live tablet readings…"
        task = Task { [weak self] in
            guard let self else { return }
            await self.networkRefresh.cancelAndWait()
            do {
                try Task.checkCancellation()
                guard let relayKey = try self.keys.relayKey(address) else { throw RelaySetupError.invalidStoredKey }
                let candidates = self.networkRoutes.ordered(
                    self.addresses.isEmpty ? [address] : self.addresses, preferBluetooth: false)
                try await RelayTabletTest(client: self.client).run(addresses: candidates, transport: transport,
                    privateKey: self.keys.clientKey(), relayKey: relayKey,
                    onStatus: { [weak self] candidate, status in
                        guard let self, self.state.operation == id else { throw CancellationError() }
                        self.acceptTabletStatus(status, relayKey: relayKey)
                        self.recordSetupConnection(candidate)
                        self.rememberNetworkRoutes(status, address: candidate, relayKey: relayKey)
                        self.state.updateTabletAvailability(status.canStartReadings, operation: id)
                        if status.headsetAuthorized != true {
                            self.state.cancel()
                            self.state.forget()
                            self.message = "This relay has not authorized the headset. Set up a tablet to finish authorization."
                            self.task = nil
                        } else {
                            self.networkRoutes.succeeded(candidate)
                        }
                    }, onProgress: { [weak self] candidate, message in
                        guard let self, self.state.operation == id, self.state.activity == .observing else { return }
                        self.state.useAddress(candidate, operation: id)
                        self.message = message
                    }, onRetry: { [weak self] candidate in
                        guard let self, self.state.operation == id else { return }
                        self.networkRoutes.failed(candidate)
                        self.tabletTest.reset()
                        self.tabletTestConnection = nil
                        self.message = transport == .bluetoothOnly
                            ? "Bluetooth interrupted. Reconnecting over Bluetooth only…"
                            : "Connection interrupted. Reconnecting to the same authorized relay…"
                    }, onSample: { [weak self] candidate, sample in
                        guard let self, self.state.operation == id, self.state.activity == .observing else { return }
                        if !self.state.connectionVerified { self.state.verifyObservation(id) }
                        let activeTransport = candidate.linkType == 1 ? "Bluetooth · L2CAP" : candidate.transportName
                        if self.tabletTestConnection != activeTransport {
                            self.tabletTestConnection = activeTransport
                            self.networkRoutes.succeeded(candidate)
                        }
                        self.tabletTest.accept(sample)
                        let message = sample.attached ? "Receiving live tablet readings over \(candidate.transportName)." :
                            "The relay is connected. Reconnect the USB tablet or wake the Bluetooth tablet to resume input. Saved pairings are retained."
                        if self.message != message { self.message = message }
                    })
                try Task.checkCancellation()
                if self.state.finishObservation(id) { self.message = "Tablet test stopped." }
            } catch is CancellationError {
                guard self.state.finishObservation(id) else { return }
                self.tabletTest.reset()
                self.message = "Tablet test stopped."
            } catch {
                guard self.state.operation == id else { return }
                self.tabletTest.reset()
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
            }
            self.tabletTestConnection = nil
            self.task = nil
        }
    }

}
