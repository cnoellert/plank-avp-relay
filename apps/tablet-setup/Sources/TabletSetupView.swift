// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct TabletSetupView: View {
    @StateObject private var setup = SetupCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmForget = false

    init(setup: SetupCoordinator = SetupCoordinator()) {
        _setup = StateObject(wrappedValue: setup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("PLANK Tablet Setup").font(.title2.bold())
                Text(Bundle.main.object(forInfoDictionaryKey: "PLANKSetupVersion") as? String ?? "development")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(setup.state.activity == .testingBluetooth ? "Test Bluetooth connection" :
                         setup.state.step == .authorize && setup.state.usesButtonApproval &&
                         setup.state.busy && setup.approval == nil ? "Connect to your relay" :
                         setup.state.step.title).font(.largeTitle.bold())
                    if setup.state.activity == .testingBluetooth {
                        ProgressView("Testing communication in both directions…")
                        Text("The tablet can be powered off. No button presses are needed.")
                    } else {
                        switch setup.state.step {
                        case .relay: relayPage
                        case .tablet: tabletPage
                        case .authorize: authorizePage
                        case .complete: completePage
                        }
                    }
                    if setup.state.mode == .live && setup.state.address?.bluetoothIdentifier != nil {
                        Divider()
                        Text("Test the headset-to-relay Bluetooth link without a tablet or pairing.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Test Bluetooth connection") { setup.testBluetooth() }
                            .disabled(setup.state.busy)
                        if let result = setup.bluetoothTestResult {
                            Label("Bluetooth test passed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(result).font(.callout)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            }
            HStack(alignment: .top, spacing: 10) {
                if setup.state.busy { ProgressView().controlSize(.small) }
                Text(setup.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup-status")
            }
            HStack {
                Text("No workstation connection required").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if setup.state.busy { Button("Cancel") { setup.cancel() } }
                else if setup.state.step != .relay { Button("Back") { setup.back() } }
            }
        }
        .padding(28)
        .frame(minWidth: 680, idealWidth: 820, minHeight: 640, idealHeight: 760)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { setup.pauseForInactivity() }
        }
        .onDisappear { setup.pauseForInactivity() }
        .confirmationDialog("Forget this relay on this app?", isPresented: $confirmForget) {
            Button("Forget local pairing", role: .destructive) { setup.forget() }
        } message: {
            Text("This removes this app's saved relay identity. The relay still retains its approval; it may need to be removed there before pairing again.")
        }
    }

    private var relayPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            BluetoothRelayPicker(scanner: setup.scanner, selected: setup.selectBluetoothRelay)
            if let saved = setup.savedBluetoothRelay {
                Button("Use saved relay: \(saved.name)") { setup.selectBluetoothRelay(saved) }
            }
            DisclosureGroup("Connect by network address") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Relay hostname or IP address", text: $setup.host)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    TextField("TCP port", text: $setup.port).textFieldStyle(.roundedBorder).frame(width: 160)
                    Button("Continue") { setup.selectRelay() }
                }.padding(.top, 12)
            }
        }
    }

    private var tabletPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent("Relay", value: setup.state.address?.description ?? "")
            if setup.state.usesButtonApproval {
                Text("Keep your tablet connected to the relay. Tap Pair, then press and release its Home or center button three times.")
                Text("If your tablet has no Home or center button, use the same tablet button for all three presses.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Pair") { setup.pairSelectedRelay() }.buttonStyle(.borderedProminent)
            } else {
                Text("Connect the tablet by USB. This network relay uses the existing five-ExpressKey pairing procedure; its operator must start pairing on the relay first.")
                Button("Pair") { setup.pairSelectedRelay() }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var authorizePage: some View {
        if setup.state.usesButtonApproval {
            if setup.state.busy {
                if let approval = setup.approval {
                    ButtonApprovalView(approval: approval)
                } else {
                    ProgressView("Opening the relay connection…")
                    Text("Wait for the three numbered circles before pressing the tablet button.")
                }
            } else {
                Text("Tap Pair to start a new approval request.")
                Button("Pair") { setup.startPairing() }.buttonStyle(.borderedProminent)
            }
        } else {
            if setup.state.code.isEmpty {
                Button("Generate pairing sequence") { setup.startPairing() }.buttonStyle(.borderedProminent)
            } else {
                Text("Press and release the five displayed ExpressKeys on the tablet, in order.")
                HStack(spacing: 16) {
                    ForEach(Array(setup.state.code.enumerated()), id: \.offset) { _, digit in
                        Text(String(digit)).font(.system(size: 38, weight: .semibold, design: .rounded))
                            .frame(width: 68, height: 72)
                            .background(.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                ProgressView("Waiting for the relay to verify the sequence…")
            }
        }
    }

    private var completePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Pairing saved", systemImage: "checkmark.shield.fill")
                .font(.title2).foregroundStyle(.green)
            LabeledContent("Relay", value: setup.state.address?.description ?? "")
            if setup.state.address?.bluetoothIdentifier != nil {
                if setup.state.activity == .observing {
                    Button("Stop readings") { setup.cancel() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Start live readings") { setup.startReadings() }
                        .buttonStyle(.borderedProminent).disabled(setup.state.busy)
                }
                if let readings = setup.readings {
                    TabletReadingsView(readings: readings, count: setup.readingCount)
                }
            } else {
                Text("Start serve mode on the network relay, then check the saved connection.")
            }
            HStack {
                Button("Check connection") { setup.checkConnection() }.disabled(setup.state.busy)
                Button("Forget local pairing", role: .destructive) { confirmForget = true }
                    .disabled(setup.state.busy)
            }
        }
    }
}

struct ButtonApprovalView: View {
    let approval: ButtonApproval
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(approval.tabletReady ? "Press the Home or center button three times" : "Wake your tablet")
                .font(.title2.bold())
            Text(approval.tabletReady
                 ? "Use short presses, releasing between each. If your tablet has no Home button, use the same tablet button three times."
                 : "Wait for the tablet to reconnect before entering the three presses.")
            HStack(spacing: 18) {
                ForEach(1...3, id: \.self) { number in
                    Image(systemName: number <= approval.presses ? "checkmark.circle.fill" : "\(number).circle")
                        .font(.system(size: 44)).foregroundStyle(number <= approval.presses ? Color.green : Color.secondary)
                }
            }.accessibilityLabel("\(approval.presses) of 3 presses received")
            Text("\(approval.secondsRemaining) seconds remaining").font(.callout).foregroundStyle(.secondary)
        }
    }
}
