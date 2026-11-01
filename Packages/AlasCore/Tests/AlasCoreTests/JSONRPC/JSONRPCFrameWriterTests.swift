import Foundation
import Darwin
import Synchronization
import Testing
import AlasCore
@testable import AlasFoundation

struct JSONRPCFrameWriterTests {
    @Test func authorizationAndPoisonPreventUnwrittenFramesFromReachingIO() async throws {
        let bytes = Mutex(Data())
        let writer = JSONRPCFrameWriter { frame in
            bytes.withLock { $0.append(frame.prefix(1)) }
            throw WriterFailure.injected
        }
        #expect(await writer.writeFrame(Data("ignored".utf8), authorize: { false }) == .notWritten)
        #expect(bytes.withLock { $0.isEmpty })
        let failed = await writer.writeFrame(Data("reply".utf8), authorize: { true })
        if case .writeUncertain = failed {} else { Issue.record("A partial write lost uncertainty") }
        #expect(await writer.writeFrame(Data("later".utf8), authorize: { true }) == .notWritten)
        #expect(throws: (any Error).self) { try writer.send(Data("ordinary".utf8)) }
        #expect(bytes.withLock { $0 } == Data("r".utf8))
    }

    @Test func closingDoesNotWaitForIOAndDisarmsQueuedOrdinaryAndExactWrites() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = Mutex(false)
        let bytes = Mutex<[Data]>([])
        let writer = JSONRPCFrameWriter { frame in
            entered.withLock { $0 = true }
            gate.wait()
            bytes.withLock { $0.append(frame) }
        }
        let first = Task { await writer.writeFrame(Data("first".utf8), authorize: { true }) }
        defer { gate.signal() }
        try await eventually { entered.withLock { $0 } }
        let ordinary = Task.detached { Result { try writer.send(Data("ordinary".utf8)) } }
        let next = Task { await writer.writeFrame(Data("next".utf8), authorize: { true }) }
        writer.close()
        gate.signal()
        #expect(await first.value == .written)
        #expect(await next.value == .notWritten)
        if case .success = await ordinary.value { Issue.record("Closed writer accepted an ordinary frame") }
        #expect(bytes.withLock { $0 } == [Data("first".utf8)])
    }

    @Test func concreteNewlineTransportWritesTheOriginalBodyExactly() async throws {
        let transport = JSONRPCStdioTransport(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: nil, framing: .newline)
        try transport.start()
        defer { transport.terminate() }
        let body = Data(#" {"jsonrpc":"2.0","id":7,"result":{"n":1e999}} "#.utf8)
        #expect(await transport.writeFrame(body, authorize: { true }) == .written)
        let echoed = Mutex<Data?>(nil)
        let reading = Task {
            for await event in transport.incoming {
                if case .frame(let frame, _) = event { echoed.withLock { $0 = frame }
                break }
            }
        }
        defer { reading.cancel() }
        try await eventually { echoed.withLock { $0 != nil } }
        #expect(echoed.withLock { $0 } == body)
    }
    @Test func concreteShutdownInterruptsABlockedReplyAndWaitingOrdinaryWrite() async throws {
        let fixture = try GatedPipeFixture()
        let transport = fixture.transport
        defer { fixture.cleanup() }
        try transport.start()
        let ready = Mutex(false)
        let finished = Mutex(false)
        let reading = Task {
            for await event in transport.incoming {
                if case .frame = event { ready.withLock { $0 = true } }
            }
            finished.withLock { $0 = true }
        }
        defer { reading.cancel() }
        try await eventually { ready.withLock { $0 } }
        let claimed = Mutex(false)
        let completed = Mutex<JSONRPCFrameWriteResult?>(nil)
        let reply = Task {
            let result = await transport.writeFrame(Data(repeating: 120, count: 512 * 1024), authorize: { claimed.withLock { $0 = true }
            return true })
            completed.withLock { $0 = result }
        }
        defer { reply.cancel() }
        try await eventually { claimed.withLock { $0 } }
        let ordinaryStarted = Mutex(false)
        let ordinaryFinished = Mutex(false)
        let ordinary = Task.detached {
            ordinaryStarted.withLock { $0 = true }
            let result = Result { try transport.send(Data("ordinary".utf8)) }
            ordinaryFinished.withLock { $0 = true }
            return result
        }
        defer { ordinary.cancel() }
        try await eventually { ordinaryStarted.withLock { $0 } }
        let terminated = Mutex(false)
        let stopping = Task.detached { transport.terminate()
        terminated.withLock { $0 = true } }
        defer { stopping.cancel() }
        try await eventually { terminated.withLock { $0 } && finished.withLock { $0 } && completed.withLock { $0 != nil } && ordinaryFinished.withLock { $0 } }
        if case .writeUncertain? = completed.withLock({ $0 }) {} else { Issue.record("Interrupted pipe write was not uncertain") }
        if case .success = await ordinary.value { Issue.record("Queued write reached a terminated adapter") }
    }

    @Test func ordinaryPipeFailureEndsObservationInsteadOfLeavingAPoisonedAdapterAlive() async throws {
        let fixture = try GatedPipeFixture(closeInput: true)
        let transport = fixture.transport
        defer { fixture.cleanup() }
        try transport.start()
        let ready = Mutex(false)
        let finished = Mutex(false)
        let reading = Task {
            for await event in transport.incoming {
                if case .frame = event { ready.withLock { $0 = true } }
            }
            finished.withLock { $0 = true }
        }
        defer { reading.cancel() }
        try await eventually { ready.withLock { $0 } }
        #expect(throws: (any Error).self) { try transport.send(Data("ordinary".utf8)) }
        try await eventually { finished.withLock { $0 } }
    }
    @Test func stdoutClosureInvalidatesWriterAndPreservesActualExitStatus() async throws {
        let fixture = try GatedPipeFixture(closeOutput: true, exitAfterRelease: 255)
        let transport = fixture.transport
        defer { fixture.cleanup() }
        try transport.start()
        let finished = Mutex(false)
        let observationLost = Mutex(false)
        let exitStatus = Mutex<Int32?>(nil)
        let reading = Task {
            for await event in transport.incoming {
                if case .observationLost = event { observationLost.withLock { $0 = true } }
                if case .exited(let status) = event { exitStatus.withLock { $0 = status } }
            }
            finished.withLock { $0 = true }
        }
        defer { reading.cancel() }
        // EOF closes the writer even while the child is alive and withholding
        // its actual exit. Ignoring TERM makes this ordering deterministic.
        try await eventually { observationLost.withLock { $0 } }
        #expect(!finished.withLock { $0 })
        #expect(await transport.writeFrame(Data("late".utf8), authorize: { true }) == .notWritten)
        try await eventually { fixture.release() }
        try await eventually { finished.withLock { $0 } }
        #expect(exitStatus.withLock { $0 } == 255)
    }
}

private enum WriterFailure: Error { case injected }

private struct GatedPipeFixture {
    let root: URL
    let fifo: String
    let transport: JSONRPCStdioTransport
    init(closeInput: Bool = false, closeOutput: Bool = false, exitAfterRelease: Int32? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-stdio-write-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fifo = root.appendingPathComponent("gate").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let script = (exitAfterRelease != nil ? "trap '' TERM; " : "") + (closeInput ? "exec 0<&-; " : "") + "printf 'ready\\n'; " + (closeOutput ? "exec 1>&-; " : "") + "IFS= read -r gate < \"$1\"; exit \(exitAfterRelease ?? 0)"
        transport = JSONRPCStdioTransport(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "fixture", fifo], environment: nil, framing: .newline)
    }
    @discardableResult
    func release() -> Bool {
        let fd = open(fifo, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { _ = "release\n".withCString { Darwin.write(fd, $0, 8) }
        Darwin.close(fd) }
        return fd >= 0
    }
    func cleanup() {
        release()
        transport.terminate()
        try? FileManager.default.removeItem(at: root)
    }
}
