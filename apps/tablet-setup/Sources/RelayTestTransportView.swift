// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

/// Temporary test UI, isolated so the qualification control can be removed.
struct RelayTestTransportPicker: View {
    @Binding var selection: RelayTestTransport
    let busy: Bool

    var body: some View {
        if RelayTestTransport.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview and test transport (Relay → headset)").font(.headline)
                Picker("Relay to headset connection", selection: $selection) {
                    ForEach(RelayTestTransport.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.segmented).disabled(busy)
                Text(selection == .bluetoothOnly
                     ? "Tablet testing and connection diagnostics use Bluetooth only. Network fallback is disabled."
                     : "Tests choose an available connection automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
