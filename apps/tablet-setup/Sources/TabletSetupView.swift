// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct TabletSetupView: View {
    @StateObject private var setup = SetupCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmForget = false
    @State private var tabletToRemove: ManagedTablet?

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
                    Text(setup.state.activity == .managingTablets ? "Set up your tablet" :
                         setup.state.activity == .testingBluetooth ? "Test Bluetooth connection" :
                         setup.state.step == .authorize &&
                         setup.state.busy && setup.approval == nil ? "Connect to your relay" :
                         setup.state.step.title).font(.largeTitle.bold())
                    if setup.state.activity == .managingTablets {
                        tabletManagementPage
                    } else if setup.state.activity == .testingBluetooth {
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
                    if setup.state.address != nil &&
                        setup.state.activity != .testingBluetooth && setup.state.activity != .managingTablets {
                        Divider()
                        DisclosureGroup("Connection diagnostics") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Check Bluetooth communication without a tablet or a saved pairing. Stop live readings before running this test.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Test Bluetooth connection") { setup.testBluetooth() }
                                    .disabled(setup.state.busy)
                                if let result = setup.bluetoothTestResult {
                                    Label("Bluetooth test passed", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(result).font(.callout)
                                }
                            }.padding(.top, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            }
            HStack(alignment: .top, spacing: 10) {
                if setup.state.busy && !setup.state.connectionVerified { ProgressView().controlSize(.small) }
                Text(setup.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup-status")
            }
            HStack {
                Text("No workstation connection required").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if setup.state.busy && setup.state.activity != .observing { Button("Cancel") { setup.cancel() } }
                else if !setup.state.busy && setup.state.step != .relay { Button("Back") { setup.back() } }
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
            Text("This removes this app's saved relay identity. Pairing again requires fresh approval on the tablet.")
        }
        .confirmationDialog("Remove this tablet from the relay?", isPresented: Binding(
            get: { tabletToRemove != nil }, set: { if !$0 { tabletToRemove = nil } })) {
            if let tablet = tabletToRemove {
                Button("Remove \(tablet.name)", role: .destructive) {
                    setup.tabletOperation("remove", tablet: tablet.id)
                    tabletToRemove = nil
                }
            }
        } message: {
            Text("This removes this tablet's Bluetooth bond. To use it again, put it into pairing mode and add it again. Headset approvals are retained.")
        }
    }

    private var relayPage: some View {
        BluetoothRelayPicker(scanner: setup.scanner, selected: setup.selectBluetoothRelay)
    }

    private var tabletPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent("Relay", value: setup.state.address?.description ?? "")
            Button("Set up a tablet") { setup.manageTablets() }
            Text("Keep your tablet connected to the relay. Tap Pair, then press and release its Home or center button three times.")
            Text("If your tablet has no Home or center button, use the same tablet button for all three presses.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Pair") { setup.pairSelectedRelay() }.buttonStyle(.borderedProminent)
        }
    }

    private var tabletManagementPage: some View {
        TabletManagementView(status: setup.tabletStatus, trusted: setup.state.hasTrust,
            pending: setup.tabletCommandPending,
            operation: { setup.tabletOperation($0, tablet: $1) },
            finish: { setup.finishTabletSetup(approveHeadset: $0) },
            remove: { tabletToRemove = $0 })
    }

    @ViewBuilder private var authorizePage: some View {
        if setup.state.busy {
            if let approval = setup.approval {
                ButtonApprovalView(approval: approval)
            } else {
                ProgressView("Opening the relay connection…")
                Text("Wait for the three numbered circles before pressing the tablet button.")
            }
        } else {
            Text("Tap Pair to start a new approval request.")
            Button("Pair") { setup.startButtonApproval() }.buttonStyle(.borderedProminent)
        }
    }

    private var completePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Pairing saved", systemImage: "checkmark.shield.fill")
                .font(.title2).foregroundStyle(.green)
            LabeledContent("Relay", value: setup.state.address?.description ?? "")
            if setup.state.activity == .observing {
                Button(setup.state.connectionVerified ? "Stop readings" : "Cancel connection") {
                    setup.cancel()
                }.buttonStyle(.borderedProminent)
            } else {
                Button("Start live readings") { setup.startReadings() }
                    .buttonStyle(.borderedProminent).disabled(setup.state.busy)
            }
            if let readings = setup.readings {
                TabletReadingsView(readings: readings, count: setup.readingCount)
            } else if setup.state.activity == .observing {
                Text("Connecting and verifying the saved relay identity…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Manage pairing") {
                HStack {
                    Button("Manage tablets") { setup.manageTablets() }.disabled(setup.state.busy)
                    Button("Check saved pairing") { setup.checkConnection() }.disabled(setup.state.busy)
                    Button("Forget local pairing", role: .destructive) { confirmForget = true }
                        .disabled(setup.state.busy)
                }.padding(.top, 12)
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

struct TabletManagementView: View {
    let status: TabletSetupStatus?
    let trusted: Bool
    let pending: Bool
    let operation: (String, String?) -> Void
    let finish: (Bool) -> Void
    let remove: (ManagedTablet) -> Void
    @ViewBuilder var body: some View {
        if let status = status {
            LabeledContent("Relay", value: status.hostname)
            if status.tablets.isEmpty && !status.attached {
                Text("No tablet paired").font(.title2.bold())
            }
            ForEach(status.tablets) { tablet in
                VStack(alignment: .leading, spacing: 8) {
                    Text(tablet.name).font(.headline)
                    Text(tablet.connected ? "Connected" : "Saved · offline — wake the tablet to reconnect")
                        .font(.callout).foregroundStyle(.secondary)
                    if trusted {
                        HStack {
                            Button(tablet.connected ? "Use this tablet" : "Connect") {
                                operation("connect", tablet.id)
                            }
                            Button("Remove", role: .destructive) { remove(tablet) }
                        }.disabled(status.operating || pending)
                    }
                }
            }
            if status.operating {
                ProgressView(status.message)
                Text("\(status.secondsRemaining) seconds remaining").font(.callout)
            } else if status.canManage {
                Button(status.phase == "scanning" ? "Scan again" : "Add tablet") {
                    operation("scan", nil)
                }.buttonStyle(.borderedProminent).disabled(pending)
                if status.phase == "scanning" {
                    Text("Put your tablet into Bluetooth pairing mode, then choose it below.")
                    Text("Scanning · \(status.secondsRemaining) seconds remaining")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(status.candidates) { tablet in
                        Button {
                            operation("pair", tablet.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(tablet.name)
                                Text(tablet.id).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(pending)
                    }
                    if status.candidates.isEmpty { Text("No candidate tablets found yet.") }
                }
            } else if !trusted && !status.attached {
                Text("Wake the saved tablet to approve this headset. If neither the tablet nor an approved headset is available, use the relay’s SSH recovery command.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !status.operating {
                if !trusted && status.attached {
                    Button("Continue to headset approval") { finish(true) }
                        .buttonStyle(.borderedProminent)
                } else if trusted {
                    Button("Done") { finish(false) }
                }
            }
        } else {
            ProgressView("Checking the relay’s tablets…")
        }
    }

}
