// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct BluetoothRelay: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let signal: Int
}

/// Presence comes only from this scan's advertisements, never saved pairing.
struct RelayDiscovery {
    private(set) var relays: [BluetoothRelay] = []
    private var lastSeen: [UUID: TimeInterval] = [:]
    static let lifetime: TimeInterval = 5

    mutating func observe(id: UUID, advertisedName: String?, signal: Int,
                          connectable: Bool, now: TimeInterval) {
        expire(now: now)
        guard connectable else { remove(id); return }
        let index = relays.firstIndex { $0.id == id }
        guard index != nil || relays.count < 32 else { return }
        let name = advertisedName.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
            ?? index.map { relays[$0].name } ?? "Tablet relay"
        let relay = BluetoothRelay(id: id, name: name, signal: signal)
        if let index { relays[index] = relay } else { relays.append(relay) }
        lastSeen[id] = now
    }

    mutating func expire(now: TimeInterval) {
        let expired = lastSeen.filter { now - $0.value >= Self.lifetime }.map(\.key)
        for id in expired { remove(id) }
    }

    private mutating func remove(_ id: UUID) {
        lastSeen.removeValue(forKey: id)
        relays.removeAll { $0.id == id }
    }
}
