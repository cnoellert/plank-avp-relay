// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SetupStep: Int, CaseIterable, Sendable {
    case relay, tablet, complete

    public var title: String {
        switch self {
        case .relay: "Find your relay"
        case .tablet: "Connect your tablet"
        case .complete: "Your tablet relay"
        }
    }
}

public enum SetupActivity: Equatable, Sendable {
    case idle, checking, observing, testingBluetooth, managingTablets, managingNetwork, failed(String), paired
}

public struct RelayAddress: Equatable, Sendable {
    public let bluetoothIdentifier: UUID
    public let bluetoothName: String
    public let networkService: String?
    public let networkDomain: String?
    // Discovery is a hint. Every connection must prove the pinned identity.
    public let advertisedKey: Data?

    public init(bluetoothIdentifier: UUID, name: String) {
        self.bluetoothIdentifier = bluetoothIdentifier
        bluetoothName = String(name.prefix(64))
        networkService = nil; networkDomain = nil; advertisedKey = nil
    }

    public init(service: String, domain: String, name: String, key: Data) {
        bluetoothIdentifier = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        bluetoothName = String(name.prefix(64))
        networkService = service; networkDomain = domain; advertisedKey = key
    }

    public var linkType: UInt8 { networkService == nil ? 1 : 2 }
    public var transportName: String { networkService == nil ? "Bluetooth" : "Network" }

    public var description: String { bluetoothName }

    // Retain the existing account format so app updates preserve BLE trust.
    public var keychainAccount: String {
        if let advertisedKey { return "relay-network-v1:" + advertisedKey.map { String(format: "%02x", $0) }.joined() }
        return "relay-ble-v1:\(bluetoothIdentifier.uuidString.lowercased())"
    }
}

/// Pure workflow state. Cryptographic success is supplied only by the live
/// adapter after authenticated confirmation from the relay.
public struct SetupState: Equatable, Sendable {
    public private(set) var step: SetupStep = .relay
    public private(set) var activity: SetupActivity = .idle
    public private(set) var address: RelayAddress?
    public private(set) var operation: UUID?
    public private(set) var hasTrust = false
    public private(set) var connectionVerified = false
    public private(set) var hasTablet = false

    public init() {}

    public var busy: Bool { operation != nil }
    public var canObserve: Bool { !busy && hasTrust && hasTablet && address != nil }

    @discardableResult
    public mutating func selectRelay(_ address: RelayAddress, trusted: Bool = false) -> Bool {
        guard !busy else { return false }
        self.address = address
        hasTrust = trusted
        hasTablet = false
        connectionVerified = false
        activity = trusted ? .paired : .idle
        step = trusted ? .complete : .tablet
        return true
    }

    public mutating func useAddress(_ address: RelayAddress, operation: UUID) {
        guard self.operation == operation else { return }
        self.address = address
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
        guard canObserve, let id = beginCheck() else { return nil }
        activity = .observing
        return id
    }

    /// Availability comes from the current relay status, separately from
    /// headset authorization. Stale callbacks cannot enable another relay.
    public mutating func updateTabletAvailability(_ available: Bool, operation: UUID) {
        guard self.operation == operation,
              activity == .checking || activity == .managingTablets || activity == .observing else { return }
        hasTablet = available
    }

    public mutating func beginNetworkSettings() -> UUID? {
        guard let id = beginCheck() else { return nil }
        activity = .managingNetwork
        return id
    }

    public mutating func beginTabletSetup() -> UUID? {
        guard !busy, address != nil else { return nil }
        let id = UUID()
        operation = id
        activity = .managingTablets
        hasTablet = false
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

    /// Called only after a Noise-authenticated status confirms the relay has
    /// persisted this headset's approval. Tablet presence alone cannot do so.
    @discardableResult
    public mutating func authorizeTabletSetup(_ id: UUID) -> Bool {
        guard operation == id, activity == .managingTablets else { return false }
        hasTrust = true
        step = .complete
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
        step = .relay; address = nil; hasTrust = false
        hasTablet = false
        activity = .idle
        connectionVerified = false
    }

    public mutating func forget() {
        guard !busy else { return }
        hasTrust = false
        hasTablet = false
        connectionVerified = false
        step = address == nil ? .relay : .tablet
        activity = .idle
    }
}
