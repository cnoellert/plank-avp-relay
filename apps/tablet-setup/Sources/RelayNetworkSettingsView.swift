// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct RelayNetworkSettingsView: View {
    let status: RelayNetworkStatus?
    let authorized: Bool
    let busy: Bool
    let message: String
    let refresh: () -> Void
    let apply: (RelayNetworkMode) -> Void
    @State private var selectedMode: RelayNetworkMode = .bridge

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Relay network").font(.largeTitle.bold())
            Text("USB Ethernet is available while the relay’s Ethernet cable has a network link. Internet access is not required.")
                .foregroundStyle(.secondary)
            if status != nil {
              GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("USB network mode", selection: $selectedMode) {
                        ForEach(RelayNetworkMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!authorized || busy || status?.canChange != true)
                    .accessibilityIdentifier("network-mode-control")
                    Text(selectedMode == .bridge ?
                         "Bridge connects the headset directly to the wired LAN. The LAN assigns its address. This is the default mode." :
                         "Router gives the headset a private address and sends its traffic through the relay’s wired connection. The LAN sees the relay’s address.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if let status { Text("Current mode: \(status.mode.title)").font(.callout) }
                        Spacer()
                        Button("Apply changes") { apply(selectedMode) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!authorized || busy || status?.canChange != true || status?.mode == selectedMode)
                            .accessibilityIdentifier("apply-network-mode")
                    }
                    Text("Changing mode briefly interrupts USB networking. Tablet and headset pairings are retained.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
              } label: { Label("Network mode", systemImage: "slider.horizontal.3").font(.headline) }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Read-only status").font(.caption).foregroundStyle(.secondary)
                    statusRow("Ethernet cable", value: status?.ethernetLabel ?? "Not checked",
                              connected: status?.ethernet == "connected")
                    statusRow("USB Ethernet", value: status?.usbLabel ?? "Not checked",
                              connected: status?.usb == "connected")
                    if let status, !status.addresses.isEmpty {
                        LabeledContent("Relay addresses", value: status.addresses.joined(separator: ", "))
                            .textSelection(.enabled)
                    }
                    Button("Refresh status", action: refresh).disabled(!authorized || busy)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            } label: { Label("Connection status", systemImage: "info.circle").font(.headline) }
            .accessibilityIdentifier("network-readonly-status")

            if !authorized {
                Text("Select a relay and finish tablet setup to authorize this headset. Then its network settings are available here.")
                    .foregroundStyle(.secondary)
            }
            if busy { ProgressView(message) }
            else { Text(message).font(.callout).textSelection(.enabled) }
        }
        .onAppear { selectedMode = status?.mode ?? .bridge }
        .onChange(of: status?.mode) { _, mode in if let mode { selectedMode = mode } }
    }

    private func statusRow(_ title: String, value: String, connected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(value, systemImage: connected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(connected ? Color.green : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
