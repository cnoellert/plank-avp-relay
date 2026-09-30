// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

/// One completed evdev report, or an idle/attachment status update.
public struct TabletReadings: Equatable, Sendable {
    public let attached: Bool
    public let proximity: Bool
    public let tip: Bool
    public let eraser: Bool
    public let sideButton1: Bool
    public let sideButton2: Bool
    public let buttons: UInt16
    public let sequence: UInt32
    public let timestampMicroseconds: UInt64
    public let x: Int32, y: Int32, pressure: Int32
    public let xMinimum: Int32, xMaximum: Int32, yMinimum: Int32, yMaximum: Int32
    public let pressureMinimum: Int32, pressureMaximum: Int32
    public let tiltX: Int32, tiltY: Int32, distance: Int32
    public let generation: UInt32, reports: UInt32, dropped: UInt32
    public let touches: UInt16

    public init(data: Data) throws {
        guard data.count == 80 else { throw RelaySetupError.protocolError }
        let bytes = [UInt8](data)
        guard bytes[0] == 1, bytes[1] & 0xc0 == 0, bytes[78] == 0, bytes[79] == 0 else {
            throw RelaySetupError.protocolError
        }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset+$1]) << (8*$1) }
        }
        func i32(_ offset: Int) -> Int32 { Int32(bitPattern: u32(offset)) }
        attached = bytes[1] & 1 != 0
        proximity = bytes[1] & 2 != 0
        tip = bytes[1] & 4 != 0
        eraser = bytes[1] & 8 != 0
        sideButton1 = bytes[1] & 16 != 0
        sideButton2 = bytes[1] & 32 != 0
        buttons = u16(2); sequence = u32(4)
        timestampMicroseconds = (0..<8).reduce(0) { $0 | UInt64(bytes[8+$1]) << (8*$1) }
        x = i32(16); y = i32(20); pressure = i32(24)
        xMinimum = i32(28); xMaximum = i32(32)
        yMinimum = i32(36); yMaximum = i32(40)
        pressureMinimum = i32(44); pressureMaximum = i32(48)
        tiltX = i32(52); tiltY = i32(56); distance = i32(60)
        generation = u32(64); reports = u32(68); dropped = u32(72); touches = u16(76)
        if attached && (xMaximum <= xMinimum || yMaximum <= yMinimum || pressureMaximum <= pressureMinimum) {
            throw RelaySetupError.protocolError
        }
    }

    private func fraction(_ value: Int32, _ minimum: Int32, _ maximum: Int32) -> Double {
        guard attached, maximum > minimum else { return 0 }
        return min(1, max(0, (Double(value)-Double(minimum)) / (Double(maximum)-Double(minimum))))
    }
    public var normalizedX: Double { fraction(x, xMinimum, xMaximum) }
    public var normalizedY: Double { fraction(y, yMinimum, yMaximum) }
    public var normalizedPressure: Double { fraction(pressure, pressureMinimum, pressureMaximum) }

    public var aspectRatio: Double {
        guard attached else { return 1 }
        return (Double(xMaximum) - Double(xMinimum)) / (Double(yMaximum) - Double(yMinimum))
    }
}

/// Source rate uses only the relay clock; receipt rate uses only the app clock.
/// Reports include pen, pad and touch. Heartbeats do not count as input updates.
public struct TabletReportRates: Sendable {
    public private(set) var input: Double?
    public private(set) var received: Double?
    private var baseline: TabletReadings?
    private var lastReports: UInt32 = 0
    private var started: Double = 0
    private var updates = 0

    public init() {}

    public mutating func accept(_ sample: TabletReadings, at now: Double) {
        guard let first = baseline, first.generation == sample.generation,
              sample.attached else {
            baseline = sample.attached ? sample : nil
            lastReports = sample.reports
            started = now; updates = 0
            input = nil; received = nil
            return
        }
        if sample.reports != lastReports { updates += 1 }
        lastReports = sample.reports
        let elapsed = now - started
        guard elapsed >= 1, sample.timestampMicroseconds > first.timestampMicroseconds else { return }
        let sourceElapsed = Double(sample.timestampMicroseconds - first.timestampMicroseconds) / 1_000_000
        input = Double(sample.reports &- first.reports) / sourceElapsed
        received = Double(updates) / elapsed
        baseline = sample; started = now; updates = 0
    }
}

/// Only the test surface observes these frequent updates, not the setup pages.
@MainActor
public final class TabletTestReadings: ObservableObject {
    @Published public private(set) var latest: TabletReadings?
    public private(set) var count = 0
    public private(set) var trail: [TabletReadings] = []
    public private(set) var rates = TabletReportRates()

    public init() {}

    public func reset() {
        count = 0; trail.removeAll(); rates = TabletReportRates()
        latest = nil
    }

    public func accept(_ sample: TabletReadings) {
        if !sample.attached || sample.generation != latest?.generation { trail.removeAll() }
        if sample.attached, sample.reports != latest?.reports {
            trail.append(sample)
            if trail.count > 256 { trail.removeFirst(trail.count - 256) }
        }
        count += 1
        rates.accept(sample, at: ProcessInfo.processInfo.systemUptime)
        latest = sample
    }
}
