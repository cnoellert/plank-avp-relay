// SPDX-License-Identifier: GPL-3.0-or-later
// Offscreen macOS preview: simulation only, no capture/TCC or device access.
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
        for page in ["relay", "usb", "bluetooth", "authorize", "complete", "readings", "offline"] {
            let setup = SetupCoordinator(mode: .simulation)
            if page != "relay" { setup.selectDemoRelay() }
            if page == "bluetooth" {
                setup.chooseConnection(.bluetooth)
                setup.selectBluetoothTablet()
            }
            if page == "authorize" || page == "complete" {
                setup.preparePairing()
                setup.startPairing()
            }
            if page == "complete" {
                for _ in 0..<3 { setup.pressPreviewButton() }
            }
            if page == "authorize" { setup.pressPreviewButton() }
            let content: AnyView
            if page == "readings" || page == "offline" {
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
            } else { content = AnyView(TabletSetupView(setup: setup)) }
            let view = content
                .frame(width: 820, height: 820)
                .environment(\.colorScheme, .dark)
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
