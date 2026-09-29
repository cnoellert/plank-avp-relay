// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct TabletSetupView: View {
    @StateObject private var setup = SetupCoordinator()
    @Environment(\.scenePhase) private var scenePhase
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
        .confirmationDialog("Remove this tablet from the relay?", isPresented: Binding(
            get: { tabletToRemove != nil }, set: { if !$0 { tabletToRemove = nil } })) {
            if let tablet = tabletToRemove {
                Button("Remove \(tablet.name) (\(tablet.id))", role: .destructive) {
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
            Text("Pair or reconnect a tablet. The relay will save this headset automatically once the tablet is verified.")
            Button("Set up a tablet") { setup.manageTablets() }
                .buttonStyle(.borderedProminent).disabled(setup.state.busy)
            OwnershipRecoveryView()
        }
    }

    private var tabletManagementPage: some View {
        TabletManagementView(status: setup.tabletStatus, trusted: setup.state.hasTrust,
            pending: setup.tabletCommandPending,
            operation: { setup.tabletOperation($0, tablet: $1) },
            finish: { setup.finishTabletSetup() },
            remove: { tabletToRemove = $0 })
    }

    private var completePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Headset authorized", systemImage: "checkmark.shield.fill")
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
            Button("Manage tablets") { setup.manageTablets() }.disabled(setup.state.busy)
            DisclosureGroup("Headset authorization") {
                HStack {
                    Button("Check authorization") { setup.checkConnection() }.disabled(setup.state.busy)

                }.padding(.top, 12)
                OwnershipRecoveryView()
            }
        }
    }
}

struct OwnershipRecoveryView: View {
    var body: some View {
        DisclosureGroup("Lost or replaced headset?") {
            VStack(alignment: .leading, spacing: 10) {
                Text("An existing headset can restore access using its saved identity. To transfer the relay to a replacement headset, run this command over SSH on the relay:")
                Text("sudo plank-tablet-relay-admin reset-headsets --yes")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text("This clears headset approvals and keeps the relay identity and tablet bonds. Then reopen tablet setup and select the tablet to finish setup with the replacement headset.")
            }.font(.callout).padding(.top, 10)
        }
    }
}

struct TabletManagementView: View {
    let status: TabletSetupStatus?
    let trusted: Bool
    let pending: Bool
    let operation: (String, String?) -> Void
    let finish: () -> Void
    let remove: (ManagedTablet) -> Void
    @ViewBuilder var body: some View {
        if let status = status {
            LabeledContent("Relay", value: status.hostname)
            if status.tablets.isEmpty && !status.attached {
                Text("No tablet paired").font(.title2.bold())
                if status.canManage {
                    Text("Put your tablet into Bluetooth pairing mode, then find and select it below.")
                    if trusted {
                        Text("This headset is still authorized. You can add a tablet without approving the headset again.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(status.tablets) { tablet in
                VStack(alignment: .leading, spacing: 8) {
                    Text(tablet.name).font(.headline)
                    Text(tablet.id).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    Text(tablet.connected ? "Connected" : "Saved · offline — wake the tablet to reconnect")
                        .font(.callout).foregroundStyle(.secondary)
                    if status.canManage {
                        HStack {
                            Button(tablet.connected ? "Use this tablet" : "Connect") {
                                operation("connect", tablet.id)
                            }
                            if trusted { Button("Remove", role: .destructive) { remove(tablet) } }
                        }.disabled(status.operating || pending)
                    }
                }
            }
            if status.operating {
                ProgressView(status.message)
                Text("\(status.secondsRemaining) seconds remaining").font(.callout)
            } else if status.canManage {
                Button(status.phase == "scanning" ? "Scan again" : "Find tablets to pair") {
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
                                Text("Pair \(tablet.name)")
                                Text(tablet.id).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }.disabled(pending)
                    }
                    if status.candidates.isEmpty { Text("No candidate tablets found yet.") }
                }
            } else if status.needsHeadsetRecovery {
                Text("This relay needs its approved headset or an ownership reset.")
                OwnershipRecoveryView()
            }
            if !trusted && status.canManage {
                Text("Pairing or reconnecting the tablet also saves this headset’s authorization. No tablet-button confirmation is needed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if trusted && !status.operating {
                Button("Done") { finish() }.disabled(pending)
            }
        } else {
            ProgressView("Checking the relay’s tablets…")
        }
    }

}
