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
    var trail: [TabletReadings] = []
    var rates = TabletReportRates()

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
                Canvas { context, size in
                    let inset = CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18)
                    let ratio = readings.aspectRatio
                    let width = min(inset.width, inset.height * ratio)
                    let height = width / ratio
                    let area = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                      width: width, height: height)
                    context.fill(Path(roundedRect: area, cornerRadius: 12), with: .color(.blue.opacity(0.10)))
                    func point(_ sample: TabletReadings) -> CGPoint {
                        CGPoint(x: area.minX + sample.normalizedX * area.width,
                                y: area.minY + sample.normalizedY * area.height)
                    }
                    for (previous, current) in zip(trail, trail.dropFirst()) {
                        if previous.tip && current.tip && previous.generation == current.generation {
                            var segment = Path()
                            segment.move(to: point(previous)); segment.addLine(to: point(current))
                            context.stroke(segment, with: .color(.blue),
                                style: StrokeStyle(lineWidth: 1 + 9 * current.normalizedPressure, lineCap: .round))
                        }
                    }
                    if readings.proximity || readings.eraser {
                        let center = point(readings)
                        let diameter = 12 + 18 * readings.normalizedPressure
                        let cursor = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                            width: diameter, height: diameter)
                        context.fill(Path(ellipseIn: cursor), with: .color(readings.tip ? .blue : .secondary))
                    }
                }.frame(maxWidth: .infinity).frame(height: 420)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Live pen position and pressure-sensitive trail")
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
                        LabeledContent("Input reports/s", value: rate(rates.input))
                        LabeledContent("Received updates/s", value: rate(rates.received))
                        Text("Move the pen continuously to compare rates. Input reports include pen, tablet buttons and touch; idle status updates are excluded from the received rate.")
                            .font(.caption).foregroundStyle(.secondary)
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

    private func rate(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "Measuring…"
    }
}

struct TabletTestingView: View {
    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var test: TabletTestReadings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Test Tablet").font(.title.bold())
                Spacer()
                Button(setup.state.activity == .observing ? "Stop Testing" : "Close") {
                    setup.stopTesting()
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
            Text(setup.state.address?.description ?? "").font(.callout).foregroundStyle(.secondary)
            if RelayTestTransport.isAvailable {
                LabeledContent(RelayConnectionLabels.requestedPreviewTitle, value: setup.testTransport.title)
            }
            LabeledContent(RelayConnectionLabels.previewTransportTitle, value: RelayConnectionLabels.previewTransport(
                active: setup.tabletTestConnection, observing: setup.state.activity == .observing))
            ScrollView {
                if let readings = test.latest {
                    TabletReadingsView(readings: readings, count: test.count, trail: test.trail, rates: test.rates)
                } else if setup.state.activity == .observing {
                    ProgressView(setup.message).frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    ContentUnavailableView("Tablet test ended", systemImage: "pencil.tip",
                        description: Text(setup.message)).frame(minHeight: 420)
                }
            }
            Text("Move, hover and press the pen to test position and pressure.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 760, height: 780)
    }
}
