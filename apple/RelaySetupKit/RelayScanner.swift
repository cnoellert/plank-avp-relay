// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation
@preconcurrency import Network

public struct AvailableRelay: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var addresses: [RelayAddress]
    public var transports: String { addresses.map(\.transportName).joined(separator: " · ") }
}

enum RelayListings {
    static func combine(network: [RelayAddress], bluetooth: [BluetoothRelay], known: [UUID: Data]) -> [AvailableRelay] {
        var rows: [AvailableRelay] = []
        for address in network.sorted(by: { $0.description < $1.description }) {
            guard !rows.contains(where: { $0.id == address.keychainAccount }) else { continue }
            rows.append(AvailableRelay(id: address.keychainAccount, name: address.description, addresses: [address]))
        }
        for relay in bluetooth {
            let address = RelayAddress(bluetoothIdentifier: relay.id, name: relay.name)
            let matches = rows.indices.filter { index in
                if let key = known[relay.id] { return rows[index].addresses.first?.advertisedKey == key }
                // A unique name groups discovery hints only. A fallback must
                // prove the selected/pinned key before any operation is sent.
                return rows[index].name == relay.name && bluetooth.filter { $0.name == relay.name }.count == 1
            }
            if matches.count == 1 { rows[matches[0]].addresses.append(address) }
            else { rows.append(AvailableRelay(id: address.keychainAccount, name: relay.name, addresses: [address])) }
        }
        return rows
    }
}

@MainActor
public final class RelayScanner: ObservableObject {
    @Published public private(set) var relays: [AvailableRelay] = []
    @Published public private(set) var message = "Looking for relays on your network and nearby…"
    @Published public private(set) var scanning = false
    private let bluetooth = RelayBLEScanner()
    private let client = RelayPairingClient()
    private let keys = RelayKeyStore()
    private var browser: NWBrowser?
    private var candidates: [String: RelayAddress] = [:]
    private var reachable: [String: RelayAddress] = [:]
    private var probes: [String: Task<Void, Never>] = [:]
    private var lastSeen: [String: ContinuousClock.Instant] = [:]
    private var timer: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = UUID()
    private var networkMessage: String?

    public init() {
        bluetooth.$relays.sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }.store(in: &subscriptions)
        bluetooth.$message.sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }.store(in: &subscriptions)
    }

    public func start() {
        stop()
        scanning = true
        let current = generation
        bluetooth.start()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_plank-tablet._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.scanning, self.generation == current else { return }
                switch state {
                case .ready: self.networkMessage = nil
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == -65570 {
                        self.networkMessage = "Allow Local Network access in Settings to find network relays."
                    } else { self.networkMessage = "Network discovery unavailable. Bluetooth discovery is still available." }
                default: break
                }
                self.publish()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.scanning, self.generation == current else { return }
                self.update(results)
            }
        }
        browser.start(queue: .main)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, self.scanning else { return }
                self.reachable = self.reachable.filter { id, _ in
                    self.lastSeen[id].map { ContinuousClock.now - $0 < .seconds(8) } ?? false
                }
                self.probe()
                self.publish()
            }
        }
    }

    public func stop() {
        generation = UUID()
        scanning = false
        browser?.cancel(); browser = nil
        timer?.cancel(); timer = nil
        for task in probes.values { task.cancel() }
        probes.removeAll(); candidates.removeAll(); reachable.removeAll(); lastSeen.removeAll()
        bluetooth.stop()
        relays = []
        networkMessage = nil
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [String: RelayAddress] = [:]
        for result in results.prefix(32) {
            guard case let .service(service, _, domain, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata,
                  txt.getEntry(for: "protocol") == .string("1"),
                  case let .string(hex)? = txt.getEntry(for: "id"),
                  let key = Self.key(hex) else { continue }
            let hostname: String
            if case let .string(value)? = txt.getEntry(for: "hostname"), !value.isEmpty { hostname = value }
            else { hostname = service }
            let address = RelayAddress(service: service, domain: domain, name: hostname, key: key)
            found[domain + "/" + service] = address
        }
        candidates = found
        reachable = reachable.filter { candidates[$0.key] == $0.value }
        for (id, task) in probes where candidates[id] == nil { task.cancel(); probes.removeValue(forKey: id) }
        probe()
        publish()
    }

    private func probe() {
        let current = generation
        for (id, address) in candidates where probes[id] == nil && probes.count < 4 {
            probes[id] = Task { [weak self] in
                guard let self else { return }
                do {
                    let status = try await self.client.setupStatus(address) { _ in }
                    try Task.checkCancellation()
                    guard self.generation == current, self.candidates[id] == address else { return }
                    guard status.enrollmentIdentity == address.advertisedKey else { throw RelaySetupError.identityChanged }
                    self.reachable[id] = address
                    self.lastSeen[id] = .now
                } catch {
                    guard self.generation == current else { return }
                    self.reachable.removeValue(forKey: id)
                }
                self.probes.removeValue(forKey: id)
                self.publish()
            }
        }
    }

    private func publish() {
        guard scanning else { return }
        var known: [UUID: Data] = [:]
        for relay in bluetooth.relays {
            if let key = try? keys.relayKey(RelayAddress(bluetoothIdentifier: relay.id, name: relay.name)) { known[relay.id] = key }
        }
        relays = RelayListings.combine(network: Array(reachable.values), bluetooth: bluetooth.relays, known: known)
        message = networkMessage ?? (relays.isEmpty ? "Looking for relays on your network and nearby…" : "Choose an available relay.")
        if !bluetooth.scanning { message += " " + bluetooth.message }
    }

    static func key(_ text: String) -> Data? {
        guard text.utf8.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let bytes = Array(text.utf8)
        return Data(stride(from: 0, to: 64, by: 2).map { UInt8(String(decoding: bytes[$0..<$0+2], as: UTF8.self), radix: 16)! })
    }
}
