// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation
@preconcurrency import GameController

/// Observes only public input APIs. A paired Bluetooth device need not appear here.
@MainActor
final class LocalTabletInput: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var devices: [String] = []
    @Published private(set) var deviceEvents = 0
    @Published private(set) var lastDeviceEvent = "No device input received"
    @Published private(set) var surfaceEvents = 0
    @Published private(set) var lastSurfaceEvent = "No input in the test area"
    private var monitor: Task<Void, Never>?
    private var mice: [GCMouse] = []
    private var timestamps: [ObjectIdentifier: TimeInterval] = [:]

    func start() {
        guard !running else { return }
        running = true
        deviceEvents = 0; surfaceEvents = 0
        lastDeviceEvent = "No device input received"
        lastSurfaceEvent = "No input in the test area"
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    func stop() {
        running = false
        monitor?.cancel(); monitor = nil
        for mouse in mice { mouse.mouseInput?.mouseMovedHandler = nil }
        mice = []; timestamps = [:]; devices = []
    }

    func surface(_ description: String) {
        guard running else { return }
        surfaceEvents += 1
        lastSurfaceEvent = description
    }

    private func record(_ description: String) {
        guard running else { return }
        deviceEvents += 1
        lastDeviceEvent = description
    }

    private func poll() {
        guard running else { return }
        let current = GCMouse.mice()
        for mouse in mice where !current.contains(where: { $0 === mouse }) {
            mouse.mouseInput?.mouseMovedHandler = nil
            timestamps.removeValue(forKey: ObjectIdentifier(mouse))
        }
        for mouse in current where !mice.contains(where: { $0 === mouse }) {
            let name = String((mouse.vendorName ?? "Pointer").prefix(80))
            mouse.handlerQueue = .main
            mouse.mouseInput?.mouseMovedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated {
                    self?.record(String(format: "%@: pointer Δx %.2f, Δy %.2f", name, x, y))
                }
            }
            timestamps[ObjectIdentifier(mouse)] = mouse.mouseInput?.lastEventTimestamp
        }
        mice = current
        var names = current.map { "Pointer: \($0.vendorName ?? "Unnamed")" }
        for mouse in current {
            guard let input = mouse.mouseInput else { continue }
            let id = ObjectIdentifier(mouse)
            if input.lastEventTimestamp != timestamps[id] {
                timestamps[id] = input.lastEventTimestamp
                let pressed = input.buttons.filter { $0.value.isPressed }.keys.sorted().joined(separator: ", ")
                record("\(mouse.vendorName ?? "Pointer"): buttons \(pressed.isEmpty ? "released" : pressed)")
            }
        }
        #if os(visionOS)
        for stylus in GCStylus.styli {
            names.append("Stylus: \(stylus.vendorName ?? "Unnamed") (\(stylus.productCategory))")
            guard let input = stylus.input else { continue }
            let state = input.capture()
            let id = ObjectIdentifier(stylus)
            if let previous = timestamps[id], state.lastEventTimestamp != previous {
                let pressure = state.buttons[.stylusTip]?.pressedInput.value
                let primary = state.buttons[.stylusPrimaryButton]?.pressedInput.isPressed ?? false
                let secondary = state.buttons[.stylusSecondaryButton]?.pressedInput.isPressed ?? false
                record("\(stylus.vendorName ?? "Stylus"): tip \(pressure.map { String(format: "%.3f", $0) } ?? "unavailable"), buttons \(primary ? "1" : "0")/\(secondary ? "1" : "0")")
            }
            timestamps[id] = state.lastEventTimestamp
        }
        #endif
        devices = names.map { String($0.prefix(160)) }
    }
}
