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
    @Published public private(set) var approval: ButtonApproval?
    @Published public private(set) var bluetoothTestResult: String?
    public let scanner = RelayBLEScanner()
    private let keys = RelayKeyStore()
    private let client = RelayPairingClient()
    private var task: Task<Void, Never>?

    public init() {}

    public var savedBluetoothRelay: BluetoothRelay? {
        guard let value = UserDefaults.standard.string(forKey: "setup.lastBluetoothRelay"),
              let id = UUID(uuidString: value) else { return nil }
        return BluetoothRelay(id: id,
            name: UserDefaults.standard.string(forKey: "setup.lastBluetoothRelayName") ?? "Saved relay", signal: 0)
    }

    public func selectBluetoothRelay(_ relay: BluetoothRelay) {
        guard !state.busy else { return }
        scanner.stop()
        bluetoothTestResult = nil
        let address = RelayAddress(bluetoothIdentifier: relay.id, name: relay.name)
        do {
            let trusted = try keys.relayKey(address) != nil
            guard state.selectRelay(address, trusted: trusted) else { return }
            message = trusted ? "Saved pairing found. Start live readings to verify the relay and tablet." :
                "Tap Pair, then press your tablet's Home or center button three times."
        } catch { message = error.localizedDescription }
    }

    public func pairSelectedRelay() {
        guard state.prepareAuthorization() else { return }
        startButtonApproval()
    }

    public func startButtonApproval() {
        guard let address = state.address, let id = state.beginButtonApproval() else { return }
        approval = nil
        message = "Preparing this headset’s pairing identity…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let relayKey = try await self.client.pairByButton(address: address,
                    privateKey: self.keys.clientKey(), onProgress: { [weak self] message in
                        guard let self, self.state.operation == id else { return }
                        self.message = message
                    }) { [weak self] status in
                    guard let self, self.state.operation == id else { return }
                    self.approval = status
                    self.message = status.tabletReady ? "Press and release the same tablet button three times." :
                        "Wake the tablet. Approval presses will count when it reconnects."
                }
                try Task.checkCancellation()
                guard self.state.operation == id else { return }
                try self.keys.saveRelay(relayKey, address: address)
                guard self.state.succeed(id) else { return }
                UserDefaults.standard.set(address.bluetoothIdentifier.uuidString, forKey: "setup.lastBluetoothRelay")
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
        approval = nil
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
        scanner.stop()
        task?.cancel()
        task = nil
        state.cancel()
        readings = nil
        approval = nil
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
        bluetoothTestResult = nil
        message = "Choose the next setup step."
    }

    public func forget() {
        guard !state.busy, let address = state.address else { return }
        do {
            try keys.forgetRelay(address)
            state.forget()
            peerVersion = nil
            message = "Local trust removed. The relay still retains its approved Client key; relay-side revocation is not implemented here."
        } catch { message = error.localizedDescription }
    }
}
