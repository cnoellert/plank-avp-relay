// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelaySetupKit

@MainActor
final class Fixture {
    let process = Process()
    let address: RelayAddress
    init(mode: String, directory: URL) throws {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = [mode, directory.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.availableData
        let port = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = RelayAddress(host: "127.0.0.1", port: port) else {
            process.terminate()
            throw RelaySetupError.invalidState
        }
        self.address = address
    }
    func stop() {
        // The fixture has its own bounded lifetime. Do not kill it here and
        // accidentally hide an assertion failure in its protocol checks.
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Socket fixture failed")
    }
}

@main
@MainActor
enum PairingNetworkTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected fixture executable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plank-setup-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Deliberately fixed TEST key. Never stored in the application Keychain.
        let privateKey = Data((1...32).map(UInt8.init))
        let client = RelayPairingClient()

        let pairing = try Fixture(mode: "pair", directory: directory)
        let relayKey: Data
        do {
            relayKey = try await client.pair(address: pairing.address, code: [1, 2, 3, 4, 5], privateKey: privateKey)
        } catch { pairing.stop(); throw error }
        pairing.stop()
        precondition(relayKey.count == 32)
        print("PASS: real Swift/C pairing over fragmented TCP")

        let check = try Fixture(mode: "check", directory: directory)
        do {
            let version = try await client.check(address: check.address, privateKey: privateKey, relayKey: relayKey)
            precondition(version == "0.1.1")
        } catch { check.stop(); throw error }
        check.stop()
        print("PASS: pinned Noise reconnect without SESSION_READY")

        let mismatch = try Fixture(mode: "check", directory: directory)
        do {
            _ = try await client.check(address: mismatch.address, privateKey: privateKey,
                                       relayKey: Data(repeating: 0x55, count: 32))
            fatalError("Wrong relay identity was accepted")
        } catch { mismatch.stop() }
        print("PASS: wrong relay identity rejected")

        let rejected = try Fixture(mode: "pair", directory: directory)
        do {
            _ = try await client.pair(address: rejected.address, code: [5, 5, 5, 5, 5],
                                      privateKey: Data(repeating: 0x39, count: 32))
            fatalError("Wrong pairing sequence was accepted")
        } catch { rejected.stop() }
        print("PASS: wrong ExpressKey sequence rejected")

        let stalled = try Fixture(mode: "stall", directory: directory)
        let operation = Task {
            try await client.pair(address: stalled.address, code: [1, 2, 3, 4, 5], privateKey: privateKey)
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        operation.cancel()
        do { _ = try await operation.value; fatalError("Cancellation was ignored") }
        catch is CancellationError {}
        catch { stalled.stop(); throw error }
        stalled.stop()
        precondition(Date().timeIntervalSince(start) < 2, "Cancellation waited for handshake deadline")
        print("PASS: cancellation interrupts a stalled real connection promptly")
    }
}
