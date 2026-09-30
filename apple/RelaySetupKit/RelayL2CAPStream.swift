// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// CoreBluetooth supplies a byte stream with OS-managed LE credit flow control.
/// No ATT fragmentation, confirmation timer, compression or sample coalescing.
@MainActor
final class RelayL2CAPStream: NSObject, @preconcurrency StreamDelegate {
    private let input: InputStream
    private let output: OutputStream
    private let onFailure: (any Error) -> Void
    private var opening: CheckedContinuation<Void, Error>?
    private var reading: CheckedContinuation<Data, Error>?
    private var writing: CheckedContinuation<Void, Error>?
    private var opened: Set<ObjectIdentifier> = []
    private var received = Data()
    private var pending = Data()
    private var sent = 0
    private var failure: (any Error)?
    private var writeDeadline: Task<Void, Never>?
    private var started = false

    init(input: InputStream, output: OutputStream, onFailure: @escaping (any Error) -> Void) {
        self.input = input
        self.output = output
        self.onFailure = onFailure
    }

    func open() async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard !started else { throw RelaySetupError.invalidState }
        started = true
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            for stream in [input, output] as [Stream] {
                stream.delegate = self
                stream.schedule(in: .main, forMode: .common)
                stream.open()
            }
        }
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard opened.count == 2, writing == nil, data.count <= 16384 else {
            throw RelaySetupError.invalidState
        }
        if data.isEmpty { return }
        try await withCheckedThrowingContinuation { continuation in
            writing = continuation
            pending = data
            sent = 0
            writeDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.close(RelaySetupError.timedOut)
            }
            flush()
        }
    }

    func receive() async throws -> Data {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard opened.count == 2, reading == nil else { throw RelaySetupError.invalidState }
        if !received.isEmpty {
            let data = received
            received = Data()
            return data
        }
        return try await withCheckedThrowingContinuation { reading = $0 }
    }

    func close(_ error: any Error = CancellationError()) {
        guard failure == nil else { return }
        failure = error
        writeDeadline?.cancel(); writeDeadline = nil
        for stream in [input, output] as [Stream] {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .main, forMode: .common)
        }
        let open = opening, read = reading, write = writing
        opening = nil; reading = nil; writing = nil
        received = Data(); pending = Data()
        open?.resume(throwing: error)
        read?.resume(throwing: error)
        write?.resume(throwing: error)
        onFailure(error)
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        guard failure == nil else { return }
        switch event {
        case .openCompleted:
            opened.insert(ObjectIdentifier(stream))
            if opened.count == 2 {
                let waiter = opening
                opening = nil
                waiter?.resume()
            }
        case .hasSpaceAvailable: flush()
        case .hasBytesAvailable: drain()
        case .errorOccurred:
            close(stream.streamError ?? RelaySetupError.network("Bluetooth L2CAP stream failed."))
        case .endEncountered:
            close(RelaySetupError.network("Bluetooth L2CAP stream closed."))
        default: break
        }
    }

    private func flush() {
        while writing != nil && output.hasSpaceAvailable {
            let count = pending.withUnsafeBytes { buffer in
                output.write(buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: sent),
                             maxLength: pending.count - sent)
            }
            if count < 0 { close(output.streamError ?? RelaySetupError.protocolError); return }
            if count == 0 { return }
            sent += count
            if sent == pending.count {
                pending = Data(); sent = 0
                writeDeadline?.cancel(); writeDeadline = nil
                let waiter = writing
                writing = nil
                waiter?.resume()
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count < 0 { close(input.streamError ?? RelaySetupError.protocolError); return }
            if count == 0 { return }
            let data = Data(buffer.prefix(count))
            if let waiter = reading {
                reading = nil
                waiter.resume(returning: data)
            } else {
                guard received.count + count <= 16384 else {
                    close(RelaySetupError.network("Bluetooth input is not being consumed.")); return
                }
                received.append(data)
            }
        }
    }
}
