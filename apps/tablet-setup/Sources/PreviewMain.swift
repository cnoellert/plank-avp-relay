// SPDX-License-Identifier: GPL-3.0-or-later
// Offscreen macOS preview fixtures; no capture/TCC or device access.
import AppKit
import SwiftUI
import RelaySetupKit

@main
@MainActor
enum SetupPreview {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected output directory") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for page in ["relay", "readings", "offline", "wifi-networks", "wifi-disabled", "wifi-joining", "network-bridge", "network-router", "network-disconnected", "network-changing", "network-unavailable", "tablets-empty", "tablets-scan", "tablets-saved", "tablets-pairing", "tablets-replacement", "tablets-recovery"] {
            let content: AnyView
            if page.hasPrefix("wifi-") {
                let id = String(repeating: "a", count: 32)
                let status = try RelayWifiStatus.decode(JSONSerialization.data(withJSONObject: [
                    "version": 1, "id": 1, "ok": true, "supported": true, "enabled": page != "wifi-disabled",
                    "phase": page == "wifi-joining" ? "applying" : "idle",
                    "connection": page == "wifi-disabled" ? "disabled" : page == "wifi-joining" ? "associating" : "connected",
                    "message": page == "wifi-joining" ? "Connecting to the selected network…" : "Saved networks are retained when Wi-Fi is disabled.",
                    "network": page == "wifi-disabled" ? NSNull() : id as Any,
                    "name": page == "wifi-disabled" ? NSNull() : "Studio" as Any,
                    "addresses": page == "wifi-disabled" ? [] : ["192.168.1.42"], "requestID": NSNull()]), request: 1)
                let rows: [[String: Any]] = [["id": id, "name": "Studio", "secured": true, "supported": true, "saved": true, "hidden": false, "signal": 85],
                    ["id": String(repeating: "b", count: 32), "name": "Guest", "secured": false, "supported": true, "saved": false, "hidden": false, "signal": 60]]
                let networks = try RelayWifiPage.decode(JSONSerialization.data(withJSONObject: ["version": 1, "id": 1, "ok": true,
                    "networks": rows, "generation": UUID().uuidString, "next": NSNull()]), request: 1).networks
                content = AnyView(RelayWifiView(status: status, enablePending: nil, available: networks, saved: [networks[0]],
                    moreAvailable: false, moreSaved: false, authorized: true, busy: page == "wifi-joining",
                    message: status.message, action: { _ in }, more: { _ in }, editing: { _ in }).padding(30))
            } else if page.hasPrefix("network-") {
                let status = try RelayNetworkStatus.decode(JSONSerialization.data(withJSONObject: [
                    "version": 1, "id": 1, "ok": true, "supported": page != "network-unavailable",
                    "mode": page == "network-router" ? "router" : "bridge", "targetMode": "bridge",
                    "phase": page == "network-changing" ? "applying" : page == "network-unavailable" ? "unavailable" : "idle",
                    "message": "USB networking follows the Ethernet link.",
                    "ethernet": page == "network-disconnected" ? "disconnected" : "connected",
                    "usb": page == "network-disconnected" ? "waiting" : page == "network-unavailable" ? "unavailable" : "connected",
                    "addresses": ["192.168.1.42"], "requestID": NSNull()]), request: 1)
                content = AnyView(RelayNetworkSettingsView(status: status, authorized: true, busy: page == "network-changing",
                    message: page == "network-changing" ? "Changing network mode… Reconnecting to the same relay." : status.message,
                    refresh: {}, apply: { _ in }).padding(30))
            } else if page.hasPrefix("tablets-") {
                let tablet: [String: Any] = ["id": "AA:BB:CC:DD:EE:01", "name": "Wacom Intuos Pro M",
                    "connected": false, "paired": page == "tablets-saved"]
                var secondTablet = tablet
                secondTablet["id"] = "AA:BB:CC:DD:EE:02"
                secondTablet["connected"] = page == "tablets-saved"
                let data = try JSONSerialization.data(withJSONObject: ["version": 1, "id": 1, "ok": true,
                    "hostname": "plank-avp-relay-02", "phase": page == "tablets-pairing" ? "pairing" : page == "tablets-scan" ? "scanning" : "idle",
                    "message": "Pairing the selected tablet…", "canManage": page != "tablets-recovery", "initialSetup": !["tablets-saved", "tablets-replacement", "tablets-recovery"].contains(page),
                    "attached": false, "secondsRemaining": 45,
                    "selected": page == "tablets-saved" ? "AA:BB:CC:DD:EE:02" : NSNull(),
                    "tablets": page == "tablets-saved" ? [tablet, secondTablet] : [],
                    "candidates": page == "tablets-scan" ? [tablet, secondTablet] : []])
                let status = try TabletSetupStatus.decode(data, request: 1)
                content = AnyView(VStack(alignment: .leading, spacing: 20) {
                    TabletManagementView(status: status, relayName: status.hostname, message: status.message, trusted: ["tablets-saved", "tablets-replacement"].contains(page), pending: false,
                        operation: { _, _ in }, finish: {}, remove: { _ in })
                }.padding(30))
            } else if page == "readings" || page == "offline" {
                var sample = Data(repeating: 0, count: 80)
                sample[0] = 1; sample[1] = page == "offline" ? 0 : 7
                sample[2] = 4; sample[3] = 1 // Includes a ninth button.
                for (offset, value) in [(16, 4500), (20, 3000), (24, 4096),
                                        (32, 10000), (40, 7000), (48, 8192), (52, -12), (56, 15)] {
                    let bits = UInt32(bitPattern: Int32(value))
                    for byte in 0..<4 { sample[offset+byte] = UInt8(truncatingIfNeeded: bits >> (8*byte)) }
                }
                content = AnyView(VStack(alignment: .leading, spacing: 20) {
                    Text("Input readout preview — synthetic data").font(.title2)
                    TabletReadingsView(readings: try! TabletReadings(data: sample), count: 120)
                }.padding(30))
            } else { content = AnyView(TabletSetupView()) }
            let view = content
                .frame(width: 820, height: 820)
                .environment(\.colorScheme, .dark)
                .environment(\.scenePhase, .inactive) // Never scan in offscreen previews.
                .background(Color(red: 0.10, green: 0.12, blue: 0.15))
            // ImageRenderer substitutes placeholders for AppKit-backed controls
            // and scroll views. Render the actual native hierarchy offscreen.
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 820),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 820, height: 820)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                fatalError("No preview for \(page)")
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("PNG encoding failed")
            }
            try png.write(to: directory.appendingPathComponent("\(page).png"))
        }
    }
}
