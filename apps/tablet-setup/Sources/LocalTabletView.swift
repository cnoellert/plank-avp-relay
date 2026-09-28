// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit
#if os(visionOS)
import UIKit
import GameController
#endif

struct TabletAppView: View {
    @StateObject private var setup = SetupCoordinator()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TabletSetupView(setup: setup)
                .tabItem { Label("Relay", systemImage: "antenna.radiowaves.left.and.right") }.tag(0)
            LocalTabletView()
                .tabItem { Label("Local", systemImage: "pencil.tip") }.tag(1)
        }
        .onChange(of: tab) { _, _ in setup.pauseForInactivity() }
    }
}

struct LocalTabletView: View {
    @StateObject private var input = LocalTabletInput()
    @StateObject private var bluetooth = LocalBluetoothProbe()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Local tablet test").font(.largeTitle.bold())
                Text(Bundle.main.object(forInfoDictionaryKey: "PLANKSetupVersion") as? String ?? "development")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Test a tablet paired directly to this headset. No relay is used.")
                Text("Wake the tablet, start the test, then move the pen, vary its pressure and press an ExpressKey.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button(input.running ? "Stop input test" : "Start input test") {
                        if input.running { input.stop() } else { input.start() }
                    }.buttonStyle(.borderedProminent)
                    Text(input.running ? "Listening while this tab is active" : "Input test stopped")
                        .font(.callout)
                }
                GroupBox("Devices exposed by the system") {
                    VStack(alignment: .leading, spacing: 8) {
                        if input.devices.isEmpty {
                            Text(input.running ? "No pointer or stylus exposed to this app." : "Start the test to check connected devices.")
                        }
                        ForEach(Array(input.devices.enumerated()), id: \.offset) { _, name in Text(name) }
                        Text("Device updates: \(input.deviceEvents)").monospacedDigit()
                        Text(input.lastDeviceEvent).font(.callout).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Input test area") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Move the tablet pen over this area. Tap here before testing buttons.")
                            .font(.callout)
                        #if os(visionOS)
                        LocalInputSurface(enabled: input.running, report: input.surface)
                            .frame(height: 155)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        #else
                        Text("The input surface runs on Vision Pro.")
                            .frame(maxWidth: .infinity, minHeight: 155)
                        #endif
                        Text("Area events: \(input.surfaceEvents)").monospacedDigit()
                        Text(input.lastSurfaceEvent).font(.callout).textSelection(.enabled)
                        Text("Hand, mouse and tablet events may all reach this area. Pointer motion alone does not confirm pressure or ExpressKey support.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("Inspect direct Bluetooth access") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Use this if the input test shows nothing. A device can be paired in Settings without exposing a service to apps. This scan is not a list of every paired device.")
                            .font(.callout)
                        HStack {
                            Button("Scan for devices") { bluetooth.scan() }
                                .disabled(bluetooth.busy || bluetooth.connected)
                            Button("Stop Bluetooth test") { bluetooth.stop() }
                        }
                        Text(bluetooth.status).textSelection(.enabled)
                        Text("Notifications: \(bluetooth.packets) · Bytes: \(bluetooth.bytes)").monospacedDigit()
                        ForEach(bluetooth.devices) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Inspect") { bluetooth.inspect(device.id) }
                                    .disabled(bluetooth.connected || bluetooth.busy)
                            }
                        }
                        ForEach(bluetooth.channels) { channel in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Service \(channel.service)").font(.caption)
                                    Text(channel.characteristic).font(.caption.monospaced())
                                }
                                Spacer()
                                if channel.canNotify {
                                    Button(bluetooth.listening == channel.id ? "Listening" : "Listen") {
                                        bluetooth.listen(channel.id)
                                    }.disabled(bluetooth.busy || bluetooth.listening != nil)
                                } else { Text("No updates").font(.caption) }
                            }
                        }
                    }.padding(.top, 12)
                }
            }.padding(28)
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 640, idealHeight: 760)
        #if os(visionOS)
        .handlesGameControllerEvents(matching: input.running ? .stylus : [])
        #endif
        .onDisappear { stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
    }

    private func stop() { input.stop(); bluetooth.stop() }
}

#if os(visionOS)
private struct LocalInputSurface: UIViewRepresentable {
    let enabled: Bool
    let report: (String) -> Void

    func makeUIView(context: Context) -> InputSurface { InputSurface() }
    func updateUIView(_ view: InputSurface, context: Context) {
        view.enabled = enabled; view.report = report
        if !enabled { view.resignFirstResponder() }
    }
    static func dismantleUIView(_ view: InputSurface, coordinator: ()) {
        view.enabled = false; view.report = nil; view.resignFirstResponder()
    }
}

private final class InputSurface: UIView {
    var enabled = false
    var report: ((String) -> Void)?
    private var point: CGPoint?
    override var canBecomeFirstResponder: Bool { enabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground
        isMultipleTouchEnabled = true
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        accessibilityLabel = "Local tablet input test area"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard enabled else { return }
        point = gesture.location(in: self); setNeedsDisplay()
        if let point {
            report?(String(format: "Hover: x %.1f, y %.1f (window coordinates; source unverified)", point.x, point.y))
        }
    }

    private func sample(_ touches: Set<UITouch>, phase: String) {
        guard enabled else { return }
        for touch in touches {
            point = touch.location(in: self)
            let kind: String
            switch touch.type {
            case .pencil: kind = "Pen"
            case .indirectPointer: kind = "Pointer"
            case .direct: kind = "Direct touch"
            default: kind = "Other input (may be hand interaction)"
            }
            var description = String(format: "%@ %@: x %.1f, y %.1f", kind, phase, point!.x, point!.y)
            if touch.type == .pencil, touch.maximumPossibleForce > 0 {
                description += String(format: ", pressure %.3f, altitude %.3f", touch.force / touch.maximumPossibleForce, touch.altitudeAngle)
            } else { description += ", pen pressure unavailable" }
            report?(description)
        }
        setNeedsDisplay()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if enabled { becomeFirstResponder() }
        sample(touches, phase: "down")
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { sample(touches, phase: "move") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { sample(touches, phase: "up") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { sample(touches, phase: "cancel") }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if enabled {
            for press in presses {
                if let key = press.key { report?("Key down: HID usage \(key.keyCode.rawValue) (source unverified)") }
            }
        }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if enabled {
            for press in presses {
                if let key = press.key { report?("Key up: HID usage \(key.keyCode.rawValue) (source unverified)") }
            }
        }
        super.pressesEnded(presses, with: event)
    }
    override func draw(_ rect: CGRect) {
        guard let point, let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor.systemTeal.cgColor); context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
    }
}
#endif
