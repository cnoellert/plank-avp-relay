// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelaySetupKit

private final class Input: InputStream {
    private weak var eventDelegate: (any StreamDelegate)?
    override var delegate: (any StreamDelegate)? {
        get { eventDelegate }
        set { eventDelegate = newValue }
    }
    var bytes = Data()
    var didOpen = false
    var didClose = false
    init() { super.init(data: Data()) }
    override var hasBytesAvailable: Bool { !bytes.isEmpty }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        let count = min(len, bytes.count)
        bytes.copyBytes(to: buffer, count: count)
        bytes.removeFirst(count)
        return count
    }
    override func open() { didOpen = true }
    override func close() { didClose = true }
    override func schedule(in runLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from runLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}

private final class Output: OutputStream {
    private weak var eventDelegate: (any StreamDelegate)?
    override var delegate: (any StreamDelegate)? {
        get { eventDelegate }
        set { eventDelegate = newValue }
    }
    var bytes = Data()
    var allowance = 0
    var maximum = 7
    var didOpen = false
    var didClose = false
    override init(toMemory: ()) { super.init(toMemory: ()) }
    override var hasSpaceAvailable: Bool { allowance > 0 }
    override func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        let count = min(len, maximum, allowance)
        bytes.append(buffer, count: count)
        allowance -= count
        return count
    }
    override func open() { didOpen = true }
    override func close() { didClose = true }
    override func schedule(in runLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from runLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}

@main
enum RelayL2CAPStreamTests {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Stream operation did not reach its expected state")
    }

    @MainActor static func main() async throws {
        let input = Input(), output = Output(toMemory: ())
        var failures = 0, isOpen = false
        let stream = RelayL2CAPStream(input: input, output: output) { _ in failures += 1 }
        let opening = Task { try await stream.open(); isOpen = true }
        await wait { input.didOpen && output.didOpen }
        stream.stream(input, handle: .openCompleted)
        await Task.yield()
        precondition(!isOpen, "Both halves must open before sending the protocol preface")
        stream.stream(output, handle: .openCompleted)
        try await opening.value

        let expected = Data((0..<8192).map { UInt8($0 % 251) })
        var sent = false
        output.allowance = 13
        let sending = Task { try await stream.send(expected); sent = true }
        await wait { output.bytes.count == 13 }
        precondition(!sent)
        // Multiple partial writes and a credit stall must not replay or drop data.
        output.allowance = 10000
        stream.stream(output, handle: .hasSpaceAvailable)
        try await sending.value
        precondition(output.bytes == expected && sent)

        // Input may arrive before receive() or while its continuation is pending.
        input.bytes = expected
        stream.stream(input, handle: .hasBytesAvailable)
        let queued = try await stream.receive()
        precondition(queued == expected)
        let reading = Task { try await stream.receive() }
        await Task.yield()
        input.bytes = Data([10, 11, 12])
        stream.stream(input, handle: .hasBytesAvailable)
        let delivered = try await reading.value
        precondition(delivered == Data([10, 11, 12]))

        // Disconnect during pending read/write completes both exactly once.
        output.allowance = 0
        let blockedWrite = Task { try await stream.send(Data([1])) }
        let blockedRead = Task { try await stream.receive() }
        await Task.yield()
        stream.stream(input, handle: .endEncountered)
        do { try await blockedWrite.value; fatalError("Closed write succeeded") } catch {}
        do { _ = try await blockedRead.value; fatalError("Closed read succeeded") } catch {}
        stream.close()
        stream.stream(input, handle: .hasBytesAvailable)
        precondition(failures == 1 && input.didClose && output.didClose)

        let earlyInput = Input(), earlyOutput = Output(toMemory: ())
        let early = RelayL2CAPStream(input: earlyInput, output: earlyOutput) { _ in }
        let canceled = Task { try await early.open() }
        await wait { earlyInput.didOpen }
        early.close()
        do { try await canceled.value; fatalError("Canceled open succeeded") } catch is CancellationError {}

        let slowInput = Input(), slowOutput = Output(toMemory: ())
        var overflow = false
        let slow = RelayL2CAPStream(input: slowInput, output: slowOutput) { _ in overflow = true }
        let slowOpen = Task { try await slow.open() }
        await wait { slowInput.didOpen }
        slow.stream(slowInput, handle: .openCompleted)
        slow.stream(slowOutput, handle: .openCompleted)
        try await slowOpen.value
        slowInput.bytes = Data(repeating: 42, count: 16385)
        slow.stream(slowInput, handle: .hasBytesAvailable)
        precondition(overflow, "An unconsumed stream must remain bounded")
        print("L2CAP partial writes, credit stalls, input ordering, disconnect, cancellation and bounds passed")
    }
}
