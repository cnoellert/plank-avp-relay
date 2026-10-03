// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

/// Labels must describe what happened, not what was requested or selected.
@main
enum RelayConnectionLabelsTests {
    static func main() {
        let verified = RelayVerifiedConnection(transport: "Bluetooth", at: Date(timeIntervalSince1970: 0))
        typealias L = RelayConnectionLabels

        // Setup connection: idle never claims a live link.
        precondition(L.setupConnection(selectedTransport: "Wi-Fi", lastVerified: nil,
                                       operationConnected: false) == "Wi-Fi · not verified yet")
        let idle = L.setupConnection(selectedTransport: "Wi-Fi", lastVerified: verified, operationConnected: false)
        precondition(idle.hasPrefix("Last verified over Bluetooth at "), idle)
        precondition(!idle.contains("Connected"), "idle must not say Connected")
        // The verified transport wins over the merely selected one.
        precondition(!idle.contains("Wi-Fi"), "selection is not evidence")
        precondition(L.setupConnection(selectedTransport: "Wi-Fi", lastVerified: verified,
                                       operationConnected: true) == "Connected over Bluetooth")
        precondition(L.setupConnection(selectedTransport: nil, lastVerified: nil,
                                       operationConnected: true) == "No relay selected")

        // Tablet → Relay is separate from Setup → Relay.
        precondition(L.tabletToRelay(usb: true, bluetoothSelected: true) == "USB")
        precondition(L.tabletToRelay(usb: false, bluetoothSelected: true) == "Bluetooth")
        precondition(L.tabletToRelay(usb: false, bluetoothSelected: false) == "No tablet selected")
        precondition(L.tabletToRelayTitle != L.setupConnectionTitle)

        // Preview shows the transport that supplied samples, not the request.
        precondition(L.previewTransport(active: "Wi-Fi", observing: true) == "Wi-Fi")
        precondition(L.previewTransport(active: nil, observing: true) == "Connecting…")
        precondition(L.previewTransport(active: nil, observing: false) == "Not running")
        precondition(L.previewTransportTitle != L.requestedPreviewTitle)

        // PLANK's drawing connection is named and explained as distinct.
        precondition(L.drawingConnectionExplanation.contains("network"))
        precondition(L.drawingConnectionExplanation.contains("Setup connection"))

        // Completed diagnostics are labelled as previous results with context.
        let title = L.lastResultTitle("Last connection test", transport: "Bluetooth", finished: verified.at)
        precondition(title.hasPrefix("Last connection test · Bluetooth · "), title)
        print("RelayConnectionLabelsTests passed")
    }
}
