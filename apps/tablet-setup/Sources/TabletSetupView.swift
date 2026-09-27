// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct TabletSetupView: View {
    @StateObject private var setup = SetupCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmForget = false
    @State private var liveWindowReady = false

    init(setup: SetupCoordinator = SetupCoordinator()) {
        _setup = StateObject(wrappedValue: setup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            modeBanner
            stepIndicator
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(setup.state.step.title).font(.largeTitle.bold())
                    switch setup.state.step {
                    case .relay: relayPage
                    case .tablet: tabletPage
                    case .authorize: authorizePage
                    case .complete: completePage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            }
            status
            footer
        }
        .padding(28)
        .frame(minWidth: 680, idealWidth: 820, minHeight: 640, idealHeight: 760)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { setup.pauseForInactivity() }
        }
        .onChange(of: setup.state.mode) { _, _ in liveWindowReady = false }
        .confirmationDialog("Forget this relay on this app?", isPresented: $confirmForget) {
            Button("Forget local pairing", role: .destructive) { setup.forget() }
        } message: {
            Text("This removes only this app's saved relay identity. The current daemon also requires relay-side removal of its Client approval before pairing again. It does not affect the full PLANK Client.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("PLANK Tablet Setup").font(.title2.bold())
                Text("Standalone workflow lab · \(Bundle.main.object(forInfoDictionaryKey: "PLANKSetupVersion") as? String ?? "development")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Connection mode", selection: Binding(
                get: { setup.state.mode }, set: { setup.changeMode($0) })) {
                ForEach(SetupMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
    }

    private var modeBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(setup.state.mode == .simulation ? "SIMULATION — no devices are connected" : "LIVE — real pairing and saved trust")
                    .font(.headline)
                Text(setup.state.mode == .simulation
                     ? "Explore USB and Bluetooth setup without a relay. Nothing is saved to Keychain."
                     : "USB pairing only. Automatic enrollment, discovery and Bluetooth are not yet available in the relay daemon.")
                    .font(.callout)
            }
        } icon: {
            Image(systemName: setup.state.mode == .simulation ? "theatermasks" : "network.badge.shield.half.filled")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((setup.state.mode == .simulation ? Color.orange : Color.blue).opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var stepIndicator: some View {
        HStack {
            ForEach(SetupStep.allCases, id: \.self) { step in
                HStack(spacing: 6) {
                    Image(systemName: step.rawValue < setup.state.step.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle")
                    Text(["Relay", "Tablet", "Authorize", "Ready"][step.rawValue])
                        .font(.callout.weight(step == setup.state.step ? .bold : .regular))
                }
                .foregroundStyle(step == setup.state.step ? Color.primary : Color.secondary)
                if step != .complete { Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary); Spacer() }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var relayPage: some View {
        if setup.state.mode == .simulation {
            Text("Your relay lives next to the tablet. Pick a demonstration device to begin.")
            Button { setup.selectDemoRelay() } label: {
                relayRow("Desk relay", detail: "Unpaired · demonstration device", symbol: "desktopcomputer")
            }
            Button { setup.selectDemoRelay(second: true) } label: {
                relayRow("Studio relay", detail: "Unpaired · second-device selection test", symbol: "network")
            }
            .buttonStyle(.bordered)
            scenarioPicker
        } else {
            Text("Enter the relay's address. Discovery is not advertised by the current relay build.")
            VStack(alignment: .leading, spacing: 10) {
                Text("Relay hostname or IP address").font(.headline)
                TextField("relay.example", text: $setup.host).textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Text("TCP port").font(.headline)
                TextField("28990", text: $setup.port).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            Text("Only connect to a relay you own. An address or advertised device name is not proof of identity.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Continue") { setup.selectRelay() }.buttonStyle(.borderedProminent)
        }
    }

    private func relayRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var tabletPage: some View {
        Text("How does the tablet connect to \(setup.state.address?.description ?? "your relay")?")
        Picker("Tablet connection", selection: Binding(
            get: { setup.state.connection }, set: { setup.chooseConnection($0) })) {
            Text("USB cable").tag(TabletConnection.usb)
            Text("Bluetooth").tag(TabletConnection.bluetooth)
                .disabled(setup.state.mode == .live)
        }
        .pickerStyle(.segmented)
        if setup.state.connection == .usb {
            Label("Connect the tablet's USB cable to the relay, not to the headset.", systemImage: "cable.connector")
            if setup.state.mode == .simulation {
                Label("Simulated Wacom pad · 8 ExpressKeys", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Tablet detection is not exposed by the current pairing protocol.", systemImage: "info.circle")
                Text("The current relay daemon still limits pairing to PTH-660 and requires its manual pair command. This app does not remove those restrictions.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("The relay's manual pairing window is ready", isOn: $liveWindowReady)
            }
        } else {
            Label("Put the tablet into its Bluetooth pairing mode.", systemImage: "antenna.radiowaves.left.and.right")
            Text("Bluetooth connects the tablet to the relay. The headset still reaches the relay over the network.")
            Button { setup.selectBluetoothTablet() } label: {
                relayRow("Wacom tablet — simulated", detail: setup.bluetoothSelected ? "Provisional connection ready" : "Tap to simulate selecting a discovered tablet",
                         symbol: setup.bluetoothSelected ? "checkmark.circle.fill" : "wave.3.right")
            }
            Text("No Bluetooth scan or bond is performed. The ExpressKey step authorizes the headset separately.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Button("Continue to authorization") { setup.preparePairing() }
            .buttonStyle(.borderedProminent)
            .disabled(setup.state.connection == .bluetooth && !setup.bluetoothSelected ||
                      setup.state.mode == .live && !liveWindowReady)
    }

    @ViewBuilder private var authorizePage: some View {
        Text("Press the five displayed ExpressKeys on your tablet, in order. Repeated numbers mean press and release that key again.")
        if setup.state.code.isEmpty {
            Button("Generate pairing sequence") { setup.startPairing() }
                .buttonStyle(.borderedProminent)
        } else {
            HStack(spacing: 16) {
                ForEach(Array(setup.state.code.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit)).font(.system(size: 38, weight: .semibold, design: .rounded))
                        .frame(width: 68, height: 72)
                        .background(.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Key \(digit)")
                }
            }
            .frame(maxWidth: .infinity)
            if setup.state.mode == .simulation {
                Divider()
                Text("SIMULATED EXPRESSKEYS").font(.caption.bold()).foregroundStyle(.orange)
                HStack {
                    ForEach(1...8, id: \.self) { number in
                        Button(String(number)) { setup.pressSimulatedKey(UInt8(number)) }
                            .frame(minWidth: 42, minHeight: 44)
                    }
                }
                Text("\(setup.simulatedKeys.count) of 5 simulated presses entered")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView("Waiting for the relay to verify the sequence…")
                Text("Physical button order varies. This prototype uses the existing relay's logical numbering; a model-independent button guide is still required.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        if setup.state.mode == .simulation { scenarioPicker.disabled(setup.state.busy) }
    }

    @ViewBuilder private var completePage: some View {
        Label(setup.state.mode == .simulation ? "Simulated pairing complete" : "Relay trust saved",
              systemImage: "checkmark.shield.fill")
            .font(.title2).foregroundStyle(.green)
        LabeledContent("Relay", value: setup.state.address?.description ?? "")
        LabeledContent("Identity", value: setup.state.connectionVerified ? "Verified this operation" : "Saved; not currently verified")
        if let version = setup.peerVersion { LabeledContent("Relay version", value: version) }
        Text(setup.state.mode == .simulation
             ? "Try a connection failure below, then switch back to Successful pairing and check again. Saved pairing should survive the interruption."
             : "Pairing is independent of a workstation session. This app never starts remote desktop or forwards tablet input.")
        if setup.state.mode == .live {
            Text("Connection check requires the relay's serve mode and occupies its single connection briefly. Do not run it during an active desktop session.")
                .font(.callout).foregroundStyle(.secondary)
        } else { scenarioPicker.disabled(setup.state.busy) }
        HStack {
            Button("Check connection") { setup.checkConnection() }
                .buttonStyle(.borderedProminent).disabled(setup.state.busy)
            Button("Forget local pairing", role: .destructive) { confirmForget = true }
                .disabled(setup.state.busy)
        }
    }

    private var scenarioPicker: some View {
        Picker("Test scenario", selection: $setup.scenario) {
            ForEach(SimulationScenario.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 10) {
            if setup.state.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: statusSymbol).foregroundStyle(statusColor) }
            Text(setup.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup-status")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusSymbol: String {
        if case .failed = setup.state.activity { return "exclamationmark.triangle.fill" }
        return "info.circle"
    }
    private var statusColor: Color {
        if case .failed = setup.state.activity { return .orange }
        return .secondary
    }

    private var footer: some View {
        HStack {
            Text("No workstation connection required").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if setup.state.busy {
                Button("Cancel") { setup.cancel() }
            } else if setup.state.step != .relay {
                Button("Back") { setup.back() }
            }
        }
    }
}
