// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A coalesced diagnostic snapshot, not a raw-HID forwarding stream.
public struct TabletReadings: Equatable, Sendable {
    public let attached: Bool
    public let proximity: Bool
    public let tip: Bool
    public let eraser: Bool
    public let sideButton1: Bool
    public let sideButton2: Bool
    public let buttons: UInt16
    public let sequence: UInt32
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
}
