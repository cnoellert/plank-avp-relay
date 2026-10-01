// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Temporary qualification control. Disable PLANK_ENABLE_TRANSPORT_TESTING to
/// hide its UI and ignore its saved preference without changing normal routing.
public enum RelayTestTransport: String, CaseIterable, Sendable {
    case automatic, bluetoothOnly

    public static var isAvailable: Bool {
        #if PLANK_TRANSPORT_TESTING
        true
        #else
        false
        #endif
    }

    private static let preferenceKey = "temporary.relayTestTransport"
    public var title: String { self == .automatic ? "Automatic" : "Bluetooth only" }
    var effective: Self { Self.isAvailable ? self : .automatic }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        (Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .automatic).effective
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(effective.rawValue, forKey: Self.preferenceKey)
    }

    /// Filter after normal route ordering so a previously successful Wi-Fi
    /// route cannot override the restriction. Call before probing or retrying.
    func candidates(_ ordered: [RelayAddress]) throws -> [RelayAddress] {
        let allowed = effective == .bluetoothOnly ? ordered.filter { $0.linkType == 1 } : ordered
        guard !allowed.isEmpty else {
            throw RelaySetupError.network(effective == .bluetoothOnly
                ? "This relay was not found over Bluetooth. Return to Select Relay and scan again. Bluetooth-only testing will not use the network."
                : "No connection is available for this relay. Return to Select Relay and scan again.")
        }
        return allowed
    }
}
