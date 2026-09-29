// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct RelayPicker: View {
    @ObservedObject var scanner: RelayScanner
    @Environment(\.scenePhase) private var scenePhase
    let selected: (AvailableRelay) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find a relay on your network or nearby over Bluetooth.")
            Button(scanner.scanning ? "Scan again" : "Scan for relays") { scanner.start() }
                .buttonStyle(.borderedProminent)
            Text(scanner.message).font(.callout).foregroundStyle(.secondary)
            ForEach(scanner.relays) { relay in
                Button { selected(relay) } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        VStack(alignment: .leading) {
                            Text(relay.name)
                            Text(relay.transports).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(10)
                }
            }
        }
        .onAppear { if scenePhase == .active { scanner.start() } }
        .onDisappear { scanner.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { scanner.start() } else { scanner.stop() }
        }
    }
}

struct TabletReadingsView: View {
    let readings: TabletReadings
    let count: Int

    private var pressedButtons: String {
        let indices = (0..<16).filter { readings.buttons & (1 << $0) != 0 }
        return indices.isEmpty ? "None" : indices.map { String($0 + 1) }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(readings.attached ? "Tablet connected" : "Tablet offline — wake it to resume",
                  systemImage: readings.attached ? "checkmark.circle.fill" : "moon.zzz")
                .foregroundStyle(readings.attached ? Color.green : Color.orange)
            if readings.attached {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 12).fill(.blue.opacity(0.10))
                        if readings.proximity || readings.eraser {
                            Circle().fill(readings.tip ? Color.blue : Color.secondary)
                                .frame(width: 14 + 22 * readings.normalizedPressure,
                                       height: 14 + 22 * readings.normalizedPressure)
                                .position(x: 18 + readings.normalizedX * max(0, geometry.size.width - 36),
                                          y: 18 + readings.normalizedY * max(0, geometry.size.height - 36))
                        }
                    }
                }.frame(height: 150).accessibilityLabel("Live pen position")
                ProgressView(value: readings.normalizedPressure) {
                    Text("Pressure: \(readings.pressure) / \(readings.pressureMaximum)")
                }
                LabeledContent("Tablet buttons pressed", value: pressedButtons)
                    .monospacedDigit()
                Text(readings.eraser ? "Eraser in range" : readings.tip ? "Pen touching tablet" :
                     readings.proximity ? "Pen hovering" : "Pen out of range")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Reading details") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Position", value: "X \(readings.x) · Y \(readings.y)")
                        LabeledContent("Tilt", value: "\(readings.tiltX), \(readings.tiltY)")
                        LabeledContent("Pen buttons", value: "\(readings.sideButton1 ? "1" : "–") \(readings.sideButton2 ? "2" : "–")")
                        LabeledContent("Touch contacts", value: String(readings.touches))
                        LabeledContent("Updates received", value: String(count))
                        Text("Button numbers identify relay input slots; their physical layout varies by tablet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.callout.monospacedDigit()).padding(.top, 10)
                }
            } else {
                Text("Press the tablet's wake button. Your headset's pairing is saved.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if readings.dropped > 0 {
                Text("The relay resynchronized input after \(readings.dropped) overflow notifications.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }
}
