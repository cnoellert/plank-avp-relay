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
    @State private var testingTablet = false

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
                          if setup.state.activity == .observing || setup.state.activity == .stoppingObservation {
                              ProgressView("Stopping tablet test…")
                          } else if setup.state.busy {
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
                    if setup.state.activity == .managingTablets {
                        tabletManagementPage
                    } else {
                        Text(setup.state.step.title).font(.largeTitle.bold())
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
                    if setup.state.address != nil && setup.state.activity != .managingTablets {
                        Divider()
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Check relay communication without a tablet or a saved pairing. The tablet can be powered off. Stop tablet testing before running diagnostics.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Test Relay Connection") { setup.testRelayConnection() }
                                    .disabled(setup.state.busy)
                                DiagnosticResultView(result: setup.connectionDiagnostic)
                                Divider()
                                Text("Verify that the relay still has this headset’s saved approval.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Check Headset Authorization") { setup.checkAuthorization() }
                                    .disabled(setup.state.busy || !setup.state.hasTrust)
                                if !setup.state.hasTrust {
                                    Text("Headset authorization is saved automatically during tablet setup.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                DiagnosticResultView(result: setup.authorizationDiagnostic)
                                OwnershipRecoveryView()
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        } label: { Label("Connection Diagnostics", systemImage: "stethoscope").font(.headline) }
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
                      Text(setup.networkConnectionMessage).font(.callout).foregroundStyle(.secondary)
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
            .onChange(of: selectedTab != "tablet" && setup.state.activity == .observing) { _, shouldStop in
                if shouldStop { testingTablet = false; setup.stopTesting() }
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
            if setup.state.activity != .managingTablets {
              HStack(alignment: .top, spacing: 10) {
                if setup.state.busy && !setup.state.connectionVerified { ProgressView().controlSize(.small) }
                Text(selectedTab == "network" ? "Configure USB networking and Wi-Fi above. Connection status is read-only." : setup.message)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup-status")
              }
            }
            HStack {
                Text("No workstation connection required").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if setup.state.activity == .managingNetwork { Button("Stop waiting") { setup.cancel() } }
                else if setup.state.busy && setup.state.activity != .observing && setup.state.activity != .stoppingObservation && setup.state.activity != .managingTablets { Button("Cancel") { setup.cancel() } }
            }
        }
        .padding(28)
        .frame(minWidth: 680, idealWidth: 820, minHeight: 640, idealHeight: 760)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { setup.pauseForInactivity() }
        }
        .onDisappear { setup.pauseForInactivity() }
        .sheet(isPresented: $testingTablet, onDismiss: { setup.stopTesting() }) {
            TabletTestingView(setup: setup, test: setup.tabletTest)
        }
        .confirmationDialog("Remove this tablet from the relay?", isPresented: Binding(
            get: { tabletToRemove != nil }, set: { if !$0 { tabletToRemove = nil } }), titleVisibility: .visible) {
            if let tablet = tabletToRemove {
                Button("Remove Tablet", role: .destructive) {
                    setup.tabletOperation("remove", tablet: tablet.id)
                    tabletToRemove = nil
                }
            }
        } message: {
            if let tablet = tabletToRemove {
                Text("\(tablet.name)\n\(tablet.id)\n\nThis forgets the tablet’s Bluetooth pairing on the relay. To use it again, put it into pairing mode and add it again. This headset remains authorized.")
            }
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
            Text("Connect a tablet by USB or pair it over Bluetooth. The relay saves this headset’s authorization once the tablet is verified.")
            Button("Set up a tablet") { setup.manageTablets() }
                .buttonStyle(.borderedProminent).disabled(setup.state.busy)
        }
    }

    private var tabletManagementPage: some View {
        TabletManagementView(status: setup.tabletStatus, relayName: setup.state.address?.description ?? "",
            message: setup.message, trusted: setup.state.hasTrust,
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
            if let tablet = setup.tabletStatus?.activeUSBTablet {
                LabeledContent("Tablet", value: tablet.name)
                LabeledContent("Tablet connection", value: "USB")
                if let serial = tablet.serial { LabeledContent("Serial number", value: serial).textSelection(.enabled) }
            }
            if setup.state.activity == .stoppingObservation {
                ProgressView("Stopping tablet test…")
            } else if setup.state.activity == .observing {
                Button(setup.state.connectionVerified ? "Stop Testing" : "Cancel connection") {
                    setup.stopTesting()
                }.buttonStyle(.borderedProminent)
            } else {
                Button("Test Tablet") {
                    setup.startReadings()
                    testingTablet = setup.state.activity == .observing
                }
                    .buttonStyle(.borderedProminent).disabled(!setup.state.canObserve)
                if !setup.state.hasTablet {
                    Text(setup.state.activity == .checking ? "Checking the relay’s tablets…" :
                         "Connect a USB tablet, or pair and select a Bluetooth tablet before testing.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !setup.state.busy {
                        Button("Check tablet status") { setup.refreshTabletStatus() }
                    }
                }
            }
            Button("Manage Tablets") { setup.manageTablets() }.disabled(setup.state.busy)
        }
    }
}

struct DiagnosticResultView: View {
    let result: RelayDiagnostic

    @ViewBuilder var body: some View {
        switch result {
        case .idle: EmptyView()
        case .running(let message): ProgressView(message)
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .canceled: Text("Check canceled.").foregroundStyle(.secondary)
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
    let relayName: String
    let message: String
    let trusted: Bool
    let pending: Bool
    let operation: (String, String?) -> Void
    let finish: () -> Void
    let remove: (ManagedTablet) -> Void
    @State private var closing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(trusted ? "Manage Tablets" : "Set Up Your Tablet").font(.largeTitle.bold())
                    Text(status?.hostname ?? relayName).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    closing = true
                    finish()
                }.disabled(closing || pending)
            }
            if closing {
                ProgressView("Closing tablet setup…")
            } else if let status {
                if status.operating {
                    ProgressView(status.message)
                    Text("\(status.secondsRemaining) seconds remaining").font(.callout).foregroundStyle(.secondary)
                } else if pending {
                    ProgressView("Updating tablets…")
                } else if status.phase == "failed" {
                    Label(status.message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
                if let tablets = status.usbTablets, !tablets.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(tablets) { tablet in
                                if tablet.id != tablets.first?.id { Divider() }
                                HStack(alignment: .top, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(tablet.name).font(.headline)
                                        Text(tablet.serial.map { "Serial: \($0)" } ?? "USB port: \(tablet.port)")
                                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        Text(tablet.active ? "Selected · USB connected" : "USB connected")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if status.canManage && (!trusted || !tablet.active) {
                                        Button(trusted ? "Select Tablet" : "Finish Setup") { operation("use-usb", tablet.id) }
                                            .disabled(status.operating || pending)
                                    }
                                }
                            }
                            Text("A single USB tablet is used automatically. Unplug the cable to disconnect; Bluetooth pairings stay saved.")
                                .font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } label: { Label("USB Tablets", systemImage: "cable.connector").font(.headline) }
                }
                if !status.tablets.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(status.tablets) { tablet in
                                if tablet.id != status.tablets.first?.id { Divider() }
                                savedTabletRow(tablet, status: status)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } label: { Text("Saved Bluetooth Tablets").font(.headline) }
                } else if !status.attached && (status.usbTablets ?? []).isEmpty {
                    Text("No tablet connected").font(.headline)
                }
                if status.canManage && status.bluetoothAvailable != false {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Connect a tablet by USB, or put it into Bluetooth pairing mode and find it below.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button(status.phase == "scanning" ? "Scan Again" : "Find Tablets") {
                                operation("scan", nil)
                            }.buttonStyle(.borderedProminent).disabled(status.operating || pending)
                            if status.phase == "scanning" {
                                ProgressView("Scanning · \(status.secondsRemaining) seconds remaining")
                                ForEach(status.candidates) { tablet in
                                    HStack(alignment: .top, spacing: 16) {
                                        tabletIdentity(tablet)
                                        Button("Pair") { operation("pair", tablet.id) }
                                            .disabled(pending)
                                            .accessibilityLabel("Pair \(tablet.name), \(tablet.id)")
                                    }
                                }
                                if status.candidates.isEmpty {
                                    Text("No tablets found yet.").foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } label: { Label("Add Tablet", systemImage: "plus.circle").font(.headline) }
                    if !trusted {
                        Text("Pairing or reconnecting a tablet also authorizes this headset automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if status.canManage && status.bluetoothAvailable == false {
                    Text("Bluetooth pairing is unavailable without an adapter. USB tablets can still be used.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if status.needsHeadsetRecovery {
                    Text("This relay needs its approved headset or an ownership reset.")
                    OwnershipRecoveryView()
                }
            } else {
                ProgressView(message)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabletIdentity(_ tablet: ManagedTablet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tablet.name).font(.headline)
            Text(tablet.id).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedTabletRow(_ tablet: ManagedTablet, status: TabletSetupStatus) -> some View {
        let selected = status.selected == tablet.id && status.activeUSBTablet == nil
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                tabletIdentity(tablet)
                Text((selected ? "Selected · " : "") + (tablet.connected ? "Connected" : "Offline — wake tablet to reconnect"))
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if status.canManage {
                Menu {
                    if !trusted && status.bluetoothAvailable != false {
                        Button("Finish Setup") { operation("connect", tablet.id) }
                    } else if trusted && !selected && status.activeUSBTablet == nil {
                        Button("Select Tablet") { operation("connect", tablet.id) }
                            .disabled(status.bluetoothAvailable == false)
                    } else if trusted && !tablet.connected && status.activeUSBTablet == nil {
                        Button("Reconnect") { operation("connect", tablet.id) }
                            .disabled(status.bluetoothAvailable == false)
                    }
                    if trusted {
                        Button("Remove Tablet…", role: .destructive) { remove(tablet) }
                            .disabled(status.bluetoothAvailable == false)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Manage \(tablet.name), \(tablet.id)")
                }.disabled(status.operating || pending)
            }
        }
    }
}
