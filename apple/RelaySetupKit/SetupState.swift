// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SetupStep: Int, CaseIterable, Sendable {
    case relay, tablet, authorize, complete

    public var title: String {
        switch self {
        case .relay: "Find your relay"
        case .tablet: "Connect your tablet"
        case .authorize: "Authorize your headset"
        case .complete: "Your tablet relay"
        }
    }
}

public enum SetupActivity: Equatable, Sendable {
    case idle, pairing, checking, observing, testingBluetooth, managingTablets, failed(String), paired
}

public struct RelayAddress: Equatable, Sendable {
    public let bluetoothIdentifier: UUID
    public let bluetoothName: String

    public init(bluetoothIdentifier: UUID, name: String) {
        self.bluetoothIdentifier = bluetoothIdentifier
        bluetoothName = String(name.prefix(64))
    }

    public var description: String { bluetoothName }

    // Retain the existing account format so app updates preserve BLE trust.
    public var keychainAccount: String {
        "relay-ble-v1:\(bluetoothIdentifier.uuidString.lowercased())"
    }
}

/// Pure workflow state. Cryptographic success is supplied only by the live
/// adapter after BOTH confirmation tags.
public struct SetupState: Equatable, Sendable {
    public private(set) var step: SetupStep = .relay
    public private(set) var activity: SetupActivity = .idle
    public private(set) var address: RelayAddress?
    public private(set) var operation: UUID?
    public private(set) var hasTrust = false
    public private(set) var connectionVerified = false

    public init() {}

    public var busy: Bool { operation != nil }

    @discardableResult
    public mutating func selectRelay(_ address: RelayAddress, trusted: Bool = false) -> Bool {
        guard !busy else { return false }
        self.address = address
        hasTrust = trusted
        connectionVerified = false
        activity = trusted ? .paired : .idle
        step = trusted ? .complete : .tablet
        return true
    }

    @discardableResult
    public mutating func prepareAuthorization() -> Bool {
        guard !busy, step == .tablet, address != nil else { return false }
        step = .authorize
        activity = .idle
        return true
    }

    public mutating func beginButtonApproval() -> UUID? {
        guard !busy, step == .authorize, !hasTrust, address != nil else { return nil }
        let id = UUID()
        operation = id
        activity = .pairing
        return id
    }

    public mutating func beginCheck() -> UUID? {
        guard !busy, hasTrust, step == .complete else { return nil }
        let id = UUID()
        operation = id
        activity = .checking
        connectionVerified = false
        return id
    }

    public mutating func beginBluetoothTest() -> UUID? {
        guard !busy, address != nil else { return nil }
        let id = UUID()
        operation = id
        activity = .testingBluetooth
        connectionVerified = false
        return id
    }

    @discardableResult
    public mutating func finishBluetoothTest(_ id: UUID) -> Bool {
        guard operation == id, activity == .testingBluetooth else { return false }
        operation = nil
        activity = hasTrust ? .paired : .idle
        // A byte echo is not verification of the relay's saved identity.
        return true
    }

    public mutating func beginObservation() -> UUID? {
        guard address != nil, let id = beginCheck() else { return nil }
        activity = .observing
        return id
    }

    public mutating func beginTabletSetup() -> UUID? {
        guard !busy, address != nil else { return nil }
        let id = UUID()
        operation = id
        activity = .managingTablets
        connectionVerified = false
        return id
    }

    @discardableResult
    public mutating func finishTabletSetup(_ id: UUID) -> Bool {
        guard operation == id, activity == .managingTablets else { return false }
        operation = nil
        activity = hasTrust ? .paired : .idle
        return true
    }

    public mutating func verifyObservation(_ id: UUID) {
        guard operation == id, activity == .observing else { return }
        connectionVerified = true
    }

    @discardableResult
    public mutating func succeed(_ id: UUID) -> Bool {
        guard operation == id, activity != .testingBluetooth, activity != .managingTablets else { return false }
        operation = nil
        hasTrust = true
        connectionVerified = true
        activity = .paired
        step = .complete
        return true
    }

    public mutating func fail(_ id: UUID, message: String) {
        guard operation == id else { return }
        operation = nil
        connectionVerified = false
        activity = .failed(message)
    }

    public mutating func cancel() {
        operation = nil
        connectionVerified = false
        activity = hasTrust ? .paired : .idle
    }

    public mutating func back() {
        guard !busy else { return }
        if step == .authorize { step = .tablet }
        else { step = .relay; address = nil; hasTrust = false }
        activity = .idle
        connectionVerified = false
    }

    public mutating func forget() {
        guard !busy else { return }
        hasTrust = false
        connectionVerified = false
        step = address == nil ? .relay : .tablet
        activity = .idle
    }
}
