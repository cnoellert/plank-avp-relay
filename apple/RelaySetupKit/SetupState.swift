// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SetupMode: String, CaseIterable, Sendable {
    case simulation = "Simulation"
    case live = "Live relay"
}

public enum TabletConnection: String, CaseIterable, Sendable {
    case usb = "USB"
    case bluetooth = "Bluetooth"
}

public enum SetupStep: Int, CaseIterable, Sendable {
    case relay, tablet, authorize, complete

    public var title: String {
        switch self {
        case .relay: "Find your relay"
        case .tablet: "Connect your tablet"
        case .authorize: "Confirm with ExpressKeys"
        case .complete: "Your tablet relay"
        }
    }
}

public enum SetupActivity: Equatable, Sendable {
    case idle, pairing, checking, observing, failed(String), paired
}

public enum SimulationScenario: String, CaseIterable, Sendable {
    case success = "Successful pairing"
    case wrongSequence = "Incorrect sequence"
    case unavailable = "Relay unavailable"
    case timeout = "Pairing times out"
    case disconnected = "Relay disconnects"
}

public struct RelayAddress: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let bluetoothIdentifier: UUID?
    public let bluetoothName: String?

    public init?(host: String, port: String) {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 253,
              !normalized.contains(where: { $0.isWhitespace }),
              !normalized.contains("/"), !normalized.contains("@"),
              !normalized.contains("%"),
              let number = UInt16(port), number > 0 else { return nil }
        // Network.framework accepts an unbracketed numeric IPv6 host.
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            let inner = String(normalized.dropFirst().dropLast())
            guard inner.contains(":"), !inner.contains("["), !inner.contains("]") else { return nil }
            self.host = inner
        } else {
            guard !normalized.contains("["), !normalized.contains("]") else { return nil }
            self.host = normalized
        }
        self.port = number
        bluetoothIdentifier = nil
        bluetoothName = nil
    }

    public init(bluetoothIdentifier: UUID, name: String) {
        self.bluetoothIdentifier = bluetoothIdentifier
        bluetoothName = String(name.prefix(64))
        host = bluetoothIdentifier.uuidString.lowercased()
        port = 0
    }

    public var linkType: UInt8 { bluetoothIdentifier == nil ? 2 : 1 }

    public var description: String {
        bluetoothName ?? (host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)")
    }

    public var keychainAccount: String {
        bluetoothIdentifier == nil ? "relay-v1:\(description)" : "relay-ble-v1:\(host)"
    }
}

/// Pure workflow state. Cryptographic success is supplied only by the live
/// adapter after BOTH confirmation tags; simulated success has separate state.
public struct SetupState: Equatable, Sendable {
    public private(set) var mode: SetupMode = .simulation
    public private(set) var step: SetupStep = .relay
    public private(set) var connection: TabletConnection = .usb
    public private(set) var activity: SetupActivity = .idle
    public private(set) var address: RelayAddress?
    public private(set) var code: [UInt8] = []
    public private(set) var operation: UUID?
    public private(set) var hasTrust = false
    public private(set) var connectionVerified = false

    public init() {}

    public var busy: Bool { operation != nil }

    public mutating func changeMode(_ mode: SetupMode) {
        self = SetupState()
        self.mode = mode
    }

    @discardableResult
    public mutating func selectRelay(_ address: RelayAddress, trusted: Bool = false) -> Bool {
        guard !busy else { return false }
        self.address = address
        if address.bluetoothIdentifier != nil { connection = .bluetooth }
        hasTrust = trusted
        connectionVerified = false
        activity = trusted ? .paired : .idle
        step = trusted ? .complete : .tablet
        code = []
        return true
    }

    @discardableResult
    public mutating func chooseConnection(_ connection: TabletConnection) -> Bool {
        guard !busy, step == .tablet,
              mode == .simulation || connection == .usb ||
                address?.bluetoothIdentifier != nil else { return false }
        self.connection = connection
        return true
    }

    @discardableResult
    public mutating func prepareAuthorization() -> Bool {
        guard !busy, step == .tablet, address != nil else { return false }
        step = .authorize
        activity = .idle
        return true
    }

    public mutating func beginPairing(code: [UInt8]) -> UUID? {
        guard !busy, step == .authorize, !hasTrust, address != nil,
              code.count == 5, code.allSatisfy({ (1...8).contains($0) }) else { return nil }
        let id = UUID()
        operation = id
        self.code = code
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

    public mutating func beginObservation() -> UUID? {
        guard mode == .live, address?.bluetoothIdentifier != nil,
              let id = beginCheck() else { return nil }
        activity = .observing
        return id
    }

    public mutating func verifyObservation(_ id: UUID) {
        guard operation == id, activity == .observing else { return }
        connectionVerified = true
    }

    @discardableResult
    public mutating func succeed(_ id: UUID) -> Bool {
        guard operation == id else { return false }
        operation = nil
        code = []
        hasTrust = true
        connectionVerified = true
        activity = .paired
        step = .complete
        return true
    }

    public mutating func fail(_ id: UUID, message: String) {
        guard operation == id else { return }
        operation = nil
        code = []
        connectionVerified = false
        activity = .failed(message)
    }

    public mutating func cancel() {
        operation = nil
        code = []
        connectionVerified = false
        activity = hasTrust ? .paired : .idle
    }

    public mutating func back() {
        guard !busy else { return }
        if step == .authorize { step = .tablet }
        else { step = .relay; address = nil; hasTrust = false }
        activity = .idle
        code = []
        connectionVerified = false
    }

    public mutating func forget() {
        guard !busy else { return }
        hasTrust = false
        connectionVerified = false
        step = address == nil ? .relay : .tablet
        activity = .idle
        code = []
    }
}
