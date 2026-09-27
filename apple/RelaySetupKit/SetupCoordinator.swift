// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

@MainActor
public final class SetupCoordinator: ObservableObject {
    @Published public private(set) var state = SetupState()
    @Published public var host = ""
    @Published public var port = "28990"
    @Published public var scenario: SimulationScenario = .success
    @Published public private(set) var message = "Choose a demonstration relay to explore setup."
    @Published public private(set) var simulatedKeys: [UInt8] = []
    @Published public private(set) var bluetoothSelected = false
    @Published public private(set) var peerVersion: String?
    @Published public private(set) var readings: TabletReadings?
    @Published public private(set) var readingCount = 0
    @Published public private(set) var approval: ButtonApproval?
    public let scanner = RelayBLEScanner()
    private let keys = RelayKeyStore()
    private let client = RelayPairingClient()
    private var task: Task<Void, Never>?

    public init(mode: SetupMode = .live) { changeMode(mode) }

    public func changeMode(_ mode: SetupMode) {
        cancel()
        state.changeMode(mode)
        simulatedKeys = []
        bluetoothSelected = false
        peerVersion = nil
        readings = nil
        readingCount = 0
        host = mode == .live ? UserDefaults.standard.string(forKey: "setup.lastRelayHost") ?? "" : ""
        port = mode == .live ? UserDefaults.standard.string(forKey: "setup.lastRelayPort") ?? "28990" : "28990"
        message = mode == .simulation
            ? "Simulation only. No network connections or pairing keys are used."
            : "Scan for the relay beside your tablet."
    }

    public var savedBluetoothRelay: BluetoothRelay? {
        guard let value = UserDefaults.standard.string(forKey: "setup.lastBluetoothRelay"),
              let id = UUID(uuidString: value) else { return nil }
        return BluetoothRelay(id: id,
            name: UserDefaults.standard.string(forKey: "setup.lastBluetoothRelayName") ?? "Saved relay", signal: 0)
    }

    public func selectBluetoothRelay(_ relay: BluetoothRelay) {
        guard state.mode == .live, !state.busy else { return }
        scanner.stop()
        let address = RelayAddress(bluetoothIdentifier: relay.id, name: relay.name)
        do {
            let trusted = try keys.relayKey(address) != nil
            guard state.selectRelay(address, trusted: trusted) else { return }
            message = trusted ? "Saved pairing found. Start live readings to verify the relay and tablet." :
                "Tap Pair, then press your tablet's Home or center button three times."
        } catch { message = error.localizedDescription }
    }

    public func selectDemoRelay(second: Bool = false) {
        guard state.mode == .simulation else { return }
        host = second ? "studio-relay.example" : "desk-relay.example"
        selectRelay()
    }

    public func selectRelay() {
        guard !state.busy else { return }
        guard let address = RelayAddress(host: host, port: port) else {
            message = "Enter a hostname or IP address without a URL, and a port from 1 to 65535."
            return
        }
        do {
            let trusted = try state.mode == .live && keys.relayKey(address) != nil
            guard state.selectRelay(address, trusted: trusted) else { return }
            message = trusted
                ? "Saved trust found. Check the connection to verify that the same relay is available."
                : state.mode == .simulation
                    ? "Choose how your tablet connects to the relay."
                    : "Connect the tablet by USB and prepare the relay's pairing window. The app cannot yet detect the tablet model or button layout."
        } catch { message = error.localizedDescription }
    }

    public func chooseConnection(_ connection: TabletConnection) {
        if state.chooseConnection(connection) { bluetoothSelected = false }
    }

    public func selectBluetoothTablet() {
        guard state.mode == .simulation, state.connection == .bluetooth else { return }
        bluetoothSelected = true
        message = "Simulated Bluetooth connection ready. Next, authorize this headset with ExpressKeys."
    }

    public func preparePairing() {
        guard state.mode == .live || state.connection != .bluetooth || bluetoothSelected else { return }
        guard state.prepareAuthorization() else { return }
        message = state.mode == .simulation
            ? "Generate a sequence, then use the simulated ExpressKeys below."
            : "Only use a relay you own. Its five-key pairing window must already be open."
    }

    public func startPairing() {
        if state.usesButtonApproval { startButtonApproval(); return }
        guard let address = state.address else { return }
        do {
            let code = try RelayKeyStore.newSequence()
            guard let id = state.beginPairing(code: code) else { return }
            simulatedKeys = []
            if state.mode == .simulation {
                message = "Press the displayed sequence using the simulated keys. No physical tablet is being read."
                if scenario != .success && scenario != .wrongSequence {
                    let chosen = scenario
                    task = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        guard let self, self.state.operation == id else { return }
                        let error = chosen == .timeout ? "Simulated pairing timeout." :
                            chosen == .unavailable ? "Simulated relay unavailable." : "Simulated connection interruption."
                        self.state.fail(id, message: error)
                        self.message = error + " Retry when ready."
                        self.task = nil
                    }
                }
            } else {
                message = "Connecting. Press the five displayed ExpressKeys on the physical tablet when the relay is ready."
                task = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let privateKey = try self.keys.clientKey()
                        let relayKey = try await self.client.pair(address: address, code: code, privateKey: privateKey)
                        try Task.checkCancellation()
                        guard self.state.operation == id else { return }
                        // No await between generation check, persistence and UI
                        // success: cancellation cannot commit a stale identity.
                        try self.keys.saveRelay(relayKey, address: address)
                        guard self.state.succeed(id) else { return }
                        if let identifier = address.bluetoothIdentifier {
                            UserDefaults.standard.set(identifier.uuidString, forKey: "setup.lastBluetoothRelay")
                            UserDefaults.standard.set(address.description, forKey: "setup.lastBluetoothRelayName")
                        } else {
                            UserDefaults.standard.set(address.host, forKey: "setup.lastRelayHost")
                            UserDefaults.standard.set(String(address.port), forKey: "setup.lastRelayPort")
                        }
                        self.message = "Relay identity verified and saved in this app's Keychain. No Host session or tablet forwarding was started."
                    } catch {
                        guard self.state.operation == id else { return }
                        self.state.fail(id, message: error.localizedDescription)
                        self.message = error.localizedDescription
                    }
                    self.task = nil
                }
            }
        } catch { message = error.localizedDescription }
    }

    public func pairSelectedRelay() {
        guard state.prepareAuthorization() else { return }
        startPairing()
    }

    private func startButtonApproval() {
        guard let address = state.address, let id = state.beginButtonApproval() else { return }
        approval = nil
        message = "Connecting to the relay…"
        if state.mode == .simulation {
            approval = ButtonApproval(tabletReady: true, presses: 0, secondsRemaining: 60)
            message = "Preview data only."
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let relayKey = try await self.client.pairByButton(address: address,
                    privateKey: self.keys.clientKey()) { [weak self] status in
                    guard let self, self.state.operation == id else { return }
                    self.approval = status
                    self.message = status.tabletReady ? "Press and release the same tablet button three times." :
                        "Wake the tablet. Approval presses will count when it reconnects."
                }
                try Task.checkCancellation()
                guard self.state.operation == id else { return }
                try self.keys.saveRelay(relayKey, address: address)
                guard self.state.succeed(id) else { return }
                UserDefaults.standard.set(address.bluetoothIdentifier!.uuidString, forKey: "setup.lastBluetoothRelay")
                UserDefaults.standard.set(address.description, forKey: "setup.lastBluetoothRelayName")
                self.approval = nil
                self.task = nil
                self.startReadings()
            } catch {
                guard self.state.operation == id else { return }
                self.approval = nil
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
                self.task = nil
            }
        }
    }

    // Used by the offscreen preview only; no simulation control is in the app.
    public func pressPreviewButton() {
        guard state.mode == .simulation, let id = state.operation,
              let approval, approval.presses < 3 else { return }
        self.approval = ButtonApproval(tabletReady: true, presses: approval.presses + 1, secondsRemaining: 60)
        if approval.presses == 2 { _ = state.succeed(id) }
    }

    public func pressSimulatedKey(_ key: UInt8) {
        guard state.mode == .simulation, let id = state.operation,
              state.activity == .pairing, (1...8).contains(key),
              scenario == .success || scenario == .wrongSequence else { return }
        simulatedKeys.append(key)
        if simulatedKeys.count == 5 {
            if simulatedKeys == state.code && scenario != .wrongSequence {
                _ = state.succeed(id)
                message = "Simulated setup complete. Real pairing keys were not created or saved."
            } else {
                state.fail(id, message: "The simulated sequence did not match.")
                message = "The sequence was rejected. Generate a new sequence to try again."
            }
        }
    }

    public func checkConnection() {
        guard let address = state.address, let id = state.beginCheck() else { return }
        message = "Checking the saved relay identity…"
        peerVersion = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let version: String
                if self.state.mode == .simulation {
                    try await Task.sleep(for: .milliseconds(700))
                    if self.scenario == .unavailable || self.scenario == .disconnected {
                        throw RelaySetupError.network("Simulated relay unavailable; saved trust is retained.")
                    }
                    version = "simulated"
                } else {
                    guard let relayKey = try self.keys.relayKey(address) else {
                        throw RelaySetupError.invalidStoredKey
                    }
                    version = try await self.client.check(address: address,
                        privateKey: self.keys.clientKey(), relayKey: relayKey)
                }
                try Task.checkCancellation()
                guard self.state.operation == id else { return }
                self.peerVersion = version
                _ = self.state.succeed(id)
                self.message = self.state.mode == .simulation ? "Simulated reconnection succeeded." :
                    "Saved identity verified. The diagnostic connection is now closed; no tablet was claimed."
            } catch {
                guard self.state.operation == id else { return }
                self.state.fail(id, message: error.localizedDescription)
                self.message = error.localizedDescription
            }
            self.task = nil
        }
    }

    public func cancel() {
        scanner.stop()
        task?.cancel()
        task = nil
        state.cancel()
        simulatedKeys = []
        readings = nil
        approval = nil
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
                try await self.client.observe(address: address, privateKey: self.keys.clientKey(), relayKey: relayKey) {
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
        simulatedKeys = []
        message = "Choose the next setup step."
    }

    public func forget() {
        guard !state.busy, let address = state.address else { return }
        do {
            if state.mode == .live { try keys.forgetRelay(address) }
            state.forget()
            peerVersion = nil
            message = "Local trust removed. The relay still retains its approved Client key; relay-side revocation is not implemented here."
        } catch { message = error.localizedDescription }
    }
}
