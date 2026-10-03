// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A Setup → Relay management exchange that actually completed.
public struct RelayVerifiedConnection: Equatable, Sendable {
    public let transport: String
    public let at: Date

    public init(transport: String, at: Date) {
        self.transport = transport
        self.at = at
    }
}

/// Labels for the four distinct connections Setup shows. Each is derived from
/// what actually happened, never from what was requested or last selected:
///
/// - Setup connection: this app's management link to the Relay.
/// - Tablet → Relay: how the Wacom is attached to the Relay.
/// - Preview transport: the link that delivered the tablet test's samples.
/// - PLANK drawing connection: PLANK's own network link for the selected Relay.
public enum RelayConnectionLabels {
    public static let setupConnectionTitle = "Setup connection"
    public static let tabletToRelayTitle = "Tablet → Relay"
    public static let previewTransportTitle = "Preview transport"
    public static let requestedPreviewTitle = "Requested preview transport"
    public static let drawingConnectionTitle = "PLANK drawing connection"
    public static let drawingConnectionExplanation =
        "PLANK draws over its own network link to the selected Relay. It does not use this Setup connection or the tablet preview transport."

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Never claims a live link while idle: only an operation in progress on a
    /// verified connection is "Connected".
    public static func setupConnection(selectedTransport: String?,
                                       lastVerified: RelayVerifiedConnection?,
                                       operationConnected: Bool) -> String {
        if operationConnected, let lastVerified {
            return "Connected over \(lastVerified.transport)"
        }
        if let lastVerified {
            return "Last verified over \(lastVerified.transport) at \(time(lastVerified.at))"
        }
        if let selectedTransport {
            return "\(selectedTransport) · not verified yet"
        }
        return "No relay selected"
    }

    public static func tabletToRelay(usb: Bool, bluetoothSelected: Bool) -> String {
        if usb { return "USB" }
        if bluetoothSelected { return "Bluetooth" }
        return "No tablet selected"
    }

    /// The transport of the connection that supplied the samples on screen.
    public static func previewTransport(active: String?, observing: Bool) -> String {
        if let active { return active }
        return observing ? "Connecting…" : "Not running"
    }

    /// A completed diagnostic is a previous result, stated with its context.
    public static func lastResultTitle(_ kind: String, transport: String?, finished: Date) -> String {
        [kind, transport, time(finished)].compactMap { $0 }.joined(separator: " · ")
    }
}
