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
    @State private var forgetting: RelayWifiNetwork?
    @State private var hiddenName = ""
    @State private var hiddenSecurity = "personal"
    @State private var password = ""
    @State private var revealPassword = false
    private var editable: Bool { authorized && !busy && status?.canChange == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Enable Wi-Fi", isOn: Binding(get: { enablePending ?? status?.enabled ?? false }, set: { action(.enable($0)) }))
                        .disabled(!editable)
                        .accessibilityIdentifier("wifi-enable-control")
                    if let enablePending {
                        ProgressView(enablePending ? "Enabling Wi-Fi…" : "Disabling Wi-Fi…")
                    } else if !authorized {
                        Text("Select a relay and finish tablet setup to authorize Wi-Fi controls.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if busy {
                        Text("Finish the current relay operation before changing Wi-Fi.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(message).font(.callout).textSelection(.enabled)
                    }
                    Text("Disabling Wi-Fi keeps saved networks. Bluetooth remains available.")
                        .font(.caption).foregroundStyle(.secondary)
                    if status?.enabled == true {
                        HStack {
                            Button("Refresh networks") { action(.scan) }.disabled(!editable)
                            Button("Join hidden network…") { beginJoin(nil) }.disabled(!editable)
                        }
                        if available.isEmpty {
                            Text("Refresh to find networks near the relay.").foregroundStyle(.secondary)
                        }
                        ForEach(available) { network in
                            Button {
                                if network.saved && network.supported { action(.connect(network.id)) }
                                else { beginJoin(network) }
                            } label: { networkRow(network) }
                                .buttonStyle(.plain).disabled(!editable)
                        }
                        if moreAvailable { Button("More networks") { more(false) }.disabled(!editable) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            } label: { Label("Wi-Fi", systemImage: "wifi").font(.headline) }

            if !saved.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(saved) { network in
                            HStack {
                                networkRow(network)
                                Menu {
                                    Button("Connect") { action(.connect(network.id)) }
                                        .disabled(status?.enabled != true)
                                    if network.secured {
                                        Button("Update password…") { beginJoin(network) }
                                            .disabled(status?.enabled != true)
                                    }
                                    Button("Forget network", role: .destructive) { forgetting = network }
                                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Manage \(network.name)") }
                                .disabled(!editable)
                            }
                        }
                        if moreSaved { Button("More saved networks") { more(true) }.disabled(!editable) }
                    }.padding(10)
                } label: { Text("Saved networks").font(.headline) }
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
            if status?.applying == true { ProgressView(message) }
            else { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $showJoin, onDismiss: { password = ""; editing(false) }) { joinSheet }
        .onChange(of: showJoin) { _, value in editing(value) }
        .confirmationDialog("Forget this network?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            if let network = forgetting {
                Button("Forget \(network.name)", role: .destructive) {
                    action(.forget(network.id)); forgetting = nil
                }
            }
        } message: { Text("Its saved credentials will be removed from the relay. Bluetooth pairing is retained.") }
    }

    private func networkRow(_ network: RelayWifiNetwork) -> some View {
        HStack(spacing: 12) {
            Text(network.name).lineLimit(2).multilineTextAlignment(.leading)
            if status?.network == network.id, status?.connection == "connected" {
                Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("Connected")
            }
            Spacer()
            if network.secured { Image(systemName: "lock.fill").accessibilityLabel("Secured network") }
            if let signal = network.signal {
                Image(systemName: "wifi", variableValue: Double(signal) / 100)
                    .accessibilityLabel("Signal strength \(signal) percent")
            }
        }
        .contentShape(Rectangle())
    }

    private func beginJoin(_ network: RelayWifiNetwork?) {
        joining = network
        hiddenName = ""; hiddenSecurity = "personal"; password = ""; revealPassword = false
        showJoin = true
    }

    private var joinSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(joining.map { "Join \($0.name)" } ?? "Join hidden network").font(.title2.bold())
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
            HStack {
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
                .disabled(!editable || joining?.supported == false || (joining == nil && hiddenName.isEmpty) ||
                          ((joining?.secured ?? (hiddenSecurity != "open")) && password.isEmpty))
            }
        }.padding(30).frame(minWidth: 430, idealWidth: 500)
    }
}
