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
        for page in ["relay", "usb", "bluetooth", "authorize", "complete"] {
            let setup = SetupCoordinator()
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
                for key in setup.state.code { setup.pressSimulatedKey(key) }
            }
            let view = TabletSetupView(setup: setup)
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
