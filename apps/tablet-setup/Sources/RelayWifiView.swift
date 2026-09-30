// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct RelayWifiView: View {
    let status: RelayWifiStatus?
    let enablePending: Bool?
    let available: [RelayWifiNetwork]
    let saved: [RelayWifiNetwork]
    let moreAvailable: Bool
    let moreSaved: Bool
    let authorized: Bool
    let busy: Bool
    let message: String
    let action: (RelayWifiAction) -> Void
    let more: (Bool) -> Void
    let editing: (Bool) -> Void
    @State private var joining: RelayWifiNetwork?
    @State private var showJoin = false
    @State private var selectingNetwork = false
    @State private var canReturnToPicker = false
    @State private var forgetting: RelayWifiNetwork?
    @State private var hiddenName = ""
    @State private var hiddenSecurity = "personal"
    @State private var password = ""
    @State private var revealPassword = false
    private var editable: Bool { authorized && !busy && status?.canChange == true }
    private var wifiEnabled: Bool { authorized && status?.supported == true && status?.enabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    if let status, status.supported {
                        Toggle("Enable Wi-Fi", isOn: Binding(get: { enablePending ?? status.enabled }, set: { action(.enable($0)) }))
                            .disabled(!editable)
                            .accessibilityIdentifier("wifi-enable-control")
                    } else {
                        Label(status == nil ? "Waiting for Wi-Fi status" : "Wi-Fi unavailable",
                              systemImage: "wifi.exclamationmark")
                    }
                    if let enablePending {
                        ProgressView(enablePending ? "Enabling Wi-Fi…" : "Disabling Wi-Fi…")
                    } else if !authorized {
                        Text("Select a relay and finish tablet setup to authorize Wi-Fi controls.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if status?.applying == true {
                        ProgressView(message).controlSize(.small)
                    } else {
                        Text(status?.supported == false ? status!.message : message)
                            .font(.callout).textSelection(.enabled)
                    }
                    if status?.supported == true {
                        Text("Disabling Wi-Fi keeps saved networks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Join Network…") { openNetworkPicker() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!editable || !wifiEnabled)
                    if status?.supported == true && status?.enabled == false {
                        Text("Enable Wi-Fi to join a network.").font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            } label: { Label("Wi-Fi", systemImage: "wifi").font(.headline) }

            if !saved.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(saved) { network in
                            HStack {
                                WifiNetworkRow(network: network, connected: isConnected(network))
                                Menu {
                                    if !isConnected(network) {
                                        Button("Connect") { action(.connect(network.id)) }
                                            .disabled(!wifiEnabled)
                                    }
                                    if network.secured {
                                        Button("Update password…") { beginJoin(network, fromPicker: false) }
                                            .disabled(!wifiEnabled)
                                    }
                                    Button("Forget network", role: .destructive) { forgetting = network }
                                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Manage \(network.name)") }
                                .disabled(!editable)
                            }
                        }
                        if moreSaved { Button("More saved networks") { more(true) }.disabled(!editable) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                } label: { Text("Saved Networks").font(.headline) }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Read-only status").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Wi-Fi connection", value: status?.connectionLabel ?? "Not checked")
                    if let name = status?.name { LabeledContent("Network", value: name) }
                    if let addresses = status?.addresses, !addresses.isEmpty {
                        LabeledContent("Wi-Fi address", value: addresses.joined(separator: ", ")).textSelection(.enabled)
                    }
                }.padding(10)
            } label: { Label("Wi-Fi connection status", systemImage: "info.circle").font(.headline) }
        }
        .sheet(isPresented: $showJoin, onDismiss: { password = ""; editing(false) }) {
            if selectingNetwork {
                WifiNetworkPicker(networks: available,
                    connectedID: status?.connection == "connected" ? status?.network : nil,
                    working: busy || status?.applying == true, message: message,
                    canChoose: editable && wifiEnabled, canEnterOther: wifiEnabled,
                    moreAvailable: moreAvailable, scan: { action(.scan) }, more: { more(false) },
                    choose: { network in
                        if network.saved && network.supported {
                            showJoin = false
                            action(.connect(network.id))
                        } else { beginJoin(network, fromPicker: true) }
                    }, other: { beginJoin(nil, fromPicker: true) }, cancel: { showJoin = false })
            } else { joinSheet }
        }
        .onChange(of: showJoin) { _, value in editing(value) }
        .confirmationDialog("Forget this network?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            if let network = forgetting {
                Button("Forget \(network.name)", role: .destructive) {
                    action(.forget(network.id)); forgetting = nil
                }
            }
        } message: { Text("Its saved credentials will be removed from the relay. Bluetooth pairing is retained.") }
    }

    private func isConnected(_ network: RelayWifiNetwork) -> Bool {
        status?.network == network.id && status?.connection == "connected"
    }

    private func openNetworkPicker() {
        password = ""; joining = nil
        selectingNetwork = true
        canReturnToPicker = false
        showJoin = true
        editing(true)
        action(.scan)
    }

    private func beginJoin(_ network: RelayWifiNetwork?, fromPicker: Bool) {
        joining = network
        hiddenName = ""; hiddenSecurity = "personal"; password = ""; revealPassword = false
        selectingNetwork = false
        canReturnToPicker = fromPicker
        showJoin = true
    }

    private var joinSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(joining.map { "Join \($0.name)" } ?? "Other Network").font(.title2.bold())
            if let joining, !joining.supported {
                Text("This network requires a sign-in method that is not supported yet.")
            } else {
                if joining == nil {
                    TextField("Network name", text: $hiddenName)
                    Picker("Connection details", selection: $hiddenSecurity) {
                        Text("Password").tag("personal")
                        Text("Password (WPA3-only)").tag("sae")
                        Text("No password").tag("open")
                    }
                }
                if joining?.secured ?? (hiddenSecurity != "open") {
                    if revealPassword { TextField("Network password", text: $password) }
                    else { SecureField("Network password", text: $password) }
                    Toggle("Show password", isOn: $revealPassword)
                }
                Text("The relay will remember this network. Internet access is not required.").font(.callout).foregroundStyle(.secondary)
            }
            if busy { ProgressView(message).controlSize(.small) }
            HStack {
                if canReturnToPicker {
                    Button("Back") { password = ""; selectingNetwork = true }
                }
                Button("Cancel") { showJoin = false; password = "" }
                Spacer()
                Button("Join") {
                    let value = password
                    let ssid = joining == nil ? hiddenName : nil
                    let security = joining == nil ? hiddenSecurity : nil
                    let id = joining?.id
                    password = ""; showJoin = false
                    action(.join(network: id, ssid: ssid, security: security,
                                 password: (joining?.secured ?? (hiddenSecurity != "open")) ? value : ""))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!editable || !wifiEnabled || joining?.supported == false || (joining == nil && hiddenName.isEmpty) ||
                          ((joining?.secured ?? (hiddenSecurity != "open")) && password.isEmpty))
            }
        }.padding(30).frame(minWidth: 430, idealWidth: 540)
    }
}

struct WifiNetworkPicker: View {
    let networks: [RelayWifiNetwork]
    let connectedID: String?
    let working: Bool
    let message: String
    let canChoose: Bool
    let canEnterOther: Bool
    let moreAvailable: Bool
    let scan: () -> Void
    let more: () -> Void
    let choose: (RelayWifiNetwork) -> Void
    let other: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Join Network").font(.title2.bold())
                Spacer()
                Button { scan() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Scan Again").help("Scan again for nearby networks")
                    .disabled(!canChoose || working)
            }
            if working {
                ProgressView(message).controlSize(.small)
            } else {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(networks) { network in
                        Button { choose(network) } label: {
                            HStack(spacing: 12) {
                                WifiNetworkRow(network: network, connected: network.id == connectedID)
                                if network.id != connectedID {
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6)
                        }.buttonStyle(.bordered)
                            .disabled(!canChoose || network.id == connectedID)
                    }
                    if networks.isEmpty && !working {
                        Text(canEnterOther ? "No nearby networks found. Scan again or enter a network name below." :
                             "Wi-Fi must be available and enabled to find networks.")
                            .foregroundStyle(.secondary)
                    }
                    if moreAvailable {
                        Button("More Networks") { more() }.disabled(!canChoose || working)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 160, idealHeight: 280, maxHeight: 360)
            Divider()
            Button("Other Network…") { other() }.disabled(!canEnterOther)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }
            }
        }.padding(30).frame(minWidth: 430, idealWidth: 540)
    }
}

private struct WifiNetworkRow: View {
    let network: RelayWifiNetwork
    let connected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(network.name).lineLimit(2).multilineTextAlignment(.leading)
            if connected {
                Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("Connected")
            }
            Spacer()
            if network.secured { Image(systemName: "lock.fill").accessibilityLabel("Secured network") }
            if let signal = network.signal {
                Image(systemName: "wifi", variableValue: Double(signal) / 100)
                    .accessibilityLabel("Signal strength \(signal) percent")
            }
        }.contentShape(Rectangle())
    }
}
