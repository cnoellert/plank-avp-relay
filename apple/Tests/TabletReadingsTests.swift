// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelaySetupKit

@main
enum TabletReadingsTests {
    static func main() throws {
        var sample = Data(repeating: 0, count: 80)
        sample[0] = 1
        let offline = try TabletReadings(data: sample)
        precondition(!offline.attached && offline.normalizedPressure == 0)
        func set(_ offset: Int, _ value: Int32) {
            let unsigned = UInt32(bitPattern: value)
            for i in 0..<4 { sample[offset+i] = UInt8(truncatingIfNeeded: unsigned >> (8*i)) }
        }
        sample[1] = 7
        set(16, 100); set(20, 200); set(24, 4096)
        set(32, 1000); set(40, 2000); set(48, 8192)
        set(52, -21); set(56, 15)
        let live = try TabletReadings(data: sample)
        precondition(live.attached && live.proximity && live.tip)
        precondition(live.normalizedPressure == 0.5 && live.normalizedX == 0.1)
        precondition(live.tiltX == -21 && live.tiltY == 15)
        precondition(live.aspectRatio == 0.5)
        var rates = TabletReportRates()
        set(8, 1_000_000); set(68, 100)
        rates.accept(try TabletReadings(data: sample), at: 100)
        for number in 1...200 {
            set(8, 1_000_000 + Int32(number) * 5000)
            set(68, 100 + Int32(number))
            rates.accept(try TabletReadings(data: sample), at: 100 + Double(number) / 200)
        }
        precondition(abs(rates.input! - 200) < 0.1 && abs(rates.received! - 200) < 0.1)
        // A separate source clock and 20 received snapshots still expose the
        // old 200-input/20-update reduction without claiming one-way latency.
        rates = TabletReportRates()
        set(8, 5_000_000); set(68, 0)
        rates.accept(try TabletReadings(data: sample), at: 700)
        for number in 1...20 {
            set(8, 5_000_000 + Int32(number) * 50000); set(68, Int32(number) * 10)
            rates.accept(try TabletReadings(data: sample), at: 700 + Double(number) / 20)
        }
        precondition(abs(rates.input! - 200) < 0.1 && abs(rates.received! - 20) < 0.1)
        set(8, 7_000_000)
        rates.accept(try TabletReadings(data: sample), at: 702)
        precondition(rates.input == 0 && rates.received == 0)
        set(64, 2)
        rates.accept(try TabletReadings(data: sample), at: 703)
        precondition(rates.input == nil && rates.received == nil)
        set(24, Int32.max)
        let saturated = try TabletReadings(data: sample)
        precondition(saturated.normalizedPressure == 1)
        func reject(_ data: Data) {
            do { _ = try TabletReadings(data: data); fatalError("Accepted invalid snapshot") }
            catch { }
        }
        reject(sample.dropLast())
        sample[78] = 1; reject(sample); sample[78] = 0
        set(32, 0); reject(sample)
        print("PASS: input reports, timestamps, rates, normalization, offline state and malformed payloads")
    }
}
