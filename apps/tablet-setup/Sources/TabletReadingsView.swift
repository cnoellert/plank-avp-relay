// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

struct BluetoothRelayPicker: View {
    @ObservedObject var scanner: RelayBLEScanner
    let selected: (BluetoothRelay) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find the relay beside your tablet.")
            Button(scanner.scanning ? "Scan again" : "Scan for relays") { scanner.start() }
                .buttonStyle(.borderedProminent)
            Text(scanner.message).font(.callout).foregroundStyle(.secondary)
            ForEach(scanner.relays) { relay in
                Button { selected(relay) } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(relay.name)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(10)
                }
            }
        }
    }
}

struct TabletReadingsView: View {
    let readings: TabletReadings
    let count: Int

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
                HStack {
                    Text("X \(readings.x)   Y \(readings.y)")
                    Spacer()
                    Text("Tilt \(readings.tiltX), \(readings.tiltY)")
                }.font(.callout.monospacedDigit())
                HStack(spacing: 12) {
                    ForEach(0..<8) { index in
                        Text(String(index + 1)).font(.callout.bold())
                            .frame(width: 36, height: 36)
                            .background((readings.buttons & (1 << index) != 0 ? Color.blue : Color.gray).opacity(0.3),
                                        in: Circle())
                    }
                    Spacer()
                    Text("Touch: \(readings.touches)").font(.callout)
                }
                Text("\(readings.tip ? "Tip down" : "Tip up") · Side buttons: \(readings.sideButton1 ? "1" : "–") \(readings.sideButton2 ? "2" : "–") · \(count) updates")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if readings.dropped > 0 {
                Text("The relay resynchronized input after \(readings.dropped) overflow notifications.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }
}
