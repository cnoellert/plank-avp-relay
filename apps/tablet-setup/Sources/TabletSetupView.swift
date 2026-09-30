// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct TabletSetupView: View {
    @StateObject private var setup = SetupCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tabletToRemove: ManagedTablet?
    @State private var selectedTab = "relay"
    @State private var editingWifi = false
    @State private var forgettingRelay = false

    init(setup: SetupCoordinator = SetupCoordinator()) {
        _setup = StateObject(wrappedValue: setup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("PLANK AVP Relay Setup").font(.title2.bold())
                Text(Bundle.main.object(forInfoDictionaryKey: "PLANKSetupVersion") as? String ?? "development")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TabView(selection: $selectedTab) {
              Tab("Select Relay", systemImage: "antenna.radiowaves.left.and.right", value: "relay") {
                  ScrollView {
                      VStack(alignment: .leading, spacing: 20) {
                          Text("Select your relay").font(.largeTitle.bold())
                          if let address = setup.state.address {
                              LabeledContent("Selected relay", value: address.description)
                          }
                          if setup.state.busy {
                              Text("Stop the current operation before selecting another relay.")
                              Button("Stop current operation") { setup.cancel() }
                          } else {
                              relayPage
                          }
                      }.padding(22)
                  }
              }
              Tab("Tablet", systemImage: "pencil.tip", value: "tablet") {
              ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(setup.state.activity == .managingTablets ? "Set up your tablet" :
                         setup.state.activity == .testingBluetooth ? "Test relay connection" :
                         setup.state.step.title).font(.largeTitle.bold())
                    if setup.state.activity == .managingTablets {
                        tabletManagementPage
                    } else if setup.state.activity == .testingBluetooth {
                        ProgressView("Testing communication in both directions…")
                        Text("The tablet can be powered off. No button presses are needed.")
                    } else {
                        switch setup.state.step {
                        case .relay: Text("Select a relay to set up your tablet.")
                        case .tablet: tabletPage
                        case .complete: completePage
                        }
                    }
                    if setup.relayIdentityChanged {
                        Text("A fresh OS install creates a new relay pairing identity. Confirm that you reinstalled or replaced this relay before forgetting its saved identity.")
                            .font(.callout)
                        Button("Forget saved relay") { forgettingRelay = true }
                            .disabled(setup.state.busy)
                    }
                    if setup.state.address != nil &&
                        setup.state.activity != .testingBluetooth && setup.state.activity != .managingTablets {
                        Divider()
                        DisclosureGroup("Connection diagnostics") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Check relay communication without a tablet or a saved pairing. Stop live readings before running this test.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Test relay connection") { setup.testBluetooth() }
                                    .disabled(setup.state.busy)
                                if let result = setup.bluetoothTestResult {
                                    Label("Connection test passed", systemImage: "checkmark.circle.fill")
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
              }.disabled(setup.state.address == nil)
              Tab("Network", systemImage: "network", value: "network") {
              ScrollView {
                  VStack(alignment: .leading, spacing: 16) {
                      if let address = setup.state.address {
                          LabeledContent("Relay", value: address.description)
                      }
                      if !setup.state.hasTrust {
                          ContentUnavailableView {
                              Label("Finish tablet setup", systemImage: "lock.shield")
                          } description: {
                              Text("Set up a tablet to authorize network controls for this relay.")
                          } actions: {
                              Button("Set up tablet") { selectedTab = "tablet" }
                          }
                      } else {
                      if setup.state.activity == .stoppingObservation {
                          ProgressView("Stopping tablet test…")
                      } else if setup.state.busy && setup.state.activity != .managingNetwork {
                          Text("Stop the current tablet operation before changing network settings.")
                          Button("Stop current operation") { setup.cancel() }
                      }
                      RelayNetworkSettingsView(status: setup.networkStatus, authorized: setup.state.hasTrust,
                          busy: setup.state.busy, message: setup.networkMessage,
                          refresh: setup.refreshNetworkSettings, apply: setup.applyNetworkMode)
                      Divider()
                      RelayWifiView(status: setup.wifiStatus, enablePending: setup.wifiEnablePending, available: setup.wifiAvailable, saved: setup.wifiSaved,
                          moreAvailable: setup.wifiAvailableNext != nil, moreSaved: setup.wifiSavedNext != nil,
                          authorized: setup.state.hasTrust, busy: setup.state.busy, message: setup.wifiMessage,
                          action: setup.performWifi, more: { setup.moreWifiNetworks(saved: $0) },
                          editing: { editingWifi = $0 })
                      }
                  }.padding(22)
              }
              }.disabled(setup.state.address == nil)
            }
            .onChange(of: selectedTab == "network" && setup.state.activity == .observing) { _, shouldStop in
                if shouldStop { setup.stopTesting() }
            }
            .onChange(of: setup.state.address) { _, address in
                if address == nil { selectedTab = "relay" }
            }
            .task(id: "\(selectedTab)-\(scenePhase)-\(editingWifi)-\(setup.state.busy)-\(setup.state.hasTrust)-\(String(describing: setup.state.address))") {
                guard selectedTab == "network", scenePhase == .active, !editingWifi, !setup.state.busy, setup.state.hasTrust else { return }
                while !Task.isCancelled {
                    if setup.state.hasTrust, !setup.state.busy, !editingWifi { await setup.pollNetworkSettings() }
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                if setup.state.busy && !setup.state.connectionVerified { ProgressView().controlSize(.small) }
                Text(selectedTab == "network" ? "Configure USB networking and Wi-Fi above. Connection status is read-only." : setup.message)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup-status")
            }
            HStack {
                Text("No workstation connection required").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if setup.state.activity == .managingNetwork { Button("Stop waiting") { setup.cancel() } }
                else if setup.state.busy && setup.state.activity != .observing && setup.state.activity != .stoppingObservation { Button("Cancel") { setup.cancel() } }
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
        .confirmationDialog("Forget the saved pairing for \(setup.state.address?.description ?? "this relay")?",
                            isPresented: $forgettingRelay) {
            Button("Forget saved relay", role: .destructive) { setup.forgetSelectedRelay() }
        } message: {
            Text("Use this after reinstalling or replacing the relay. You will need to set up a tablet on it again. Other saved relays are retained.")
        }
    }

    private var relayPage: some View {
        RelayPicker(scanner: setup.scanner) { relay in
            setup.selectRelay(relay)
            if setup.state.address != nil { selectedTab = "tablet" }
        }
    }

    private var tabletPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent("Relay", value: setup.state.address?.description ?? "")
            LabeledContent("Connection", value: setup.state.address?.transportName ?? "")
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
            Label(setup.tabletStatus?.headsetAuthorized == true ? "Headset authorized" : "Saved headset pairing",
                  systemImage: setup.tabletStatus?.headsetAuthorized == true ? "checkmark.shield.fill" : "key.fill")
                .font(.title2).foregroundStyle(setup.tabletStatus?.headsetAuthorized == true ? Color.green : Color.secondary)
            LabeledContent("Relay", value: setup.state.address?.description ?? "")
            LabeledContent("Connection", value: setup.state.address?.transportName ?? "")
            if setup.state.activity == .stoppingObservation {
                ProgressView("Stopping tablet test…")
            } else if setup.state.activity == .observing {
                Button(setup.state.connectionVerified ? "Stop Testing" : "Cancel connection") {
                    setup.stopTesting()
                }.buttonStyle(.borderedProminent)
            } else {
                Button("Test Tablet") { setup.startReadings() }
                    .buttonStyle(.borderedProminent).disabled(!setup.state.canObserve)
                if !setup.state.hasTablet {
                    Text(setup.state.activity == .checking ? "Checking the relay’s tablets…" :
                         "Pair or select a tablet before starting live readings.")
                        .font(.callout).foregroundStyle(.secondary)
                    if setup.tabletStatus == nil && !setup.state.busy {
                        Button("Check tablet status") { setup.refreshTabletStatus() }
                    }
                }
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
                Text("sudo plank-avp-relay-admin reset-headsets --yes")
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
