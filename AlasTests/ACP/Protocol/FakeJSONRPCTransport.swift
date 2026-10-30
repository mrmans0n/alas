import Foundation
@testable import Alas

/// Minimal in-process transport for `ACPStdioClient` tests.
/// Call `send(frame:)` to inject a raw JSON frame as if the agent
/// had written it to stdout.
final class FakeJSONRPCTransport: JSONRPCStdioTransporting, @unchecked Sendable {
    private let cont: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    private struct State {
        var requestIDPrefix: String?
        var sentFrames: [Data] = []
        var terminateCount = 0
        var deferWriteCompletions = false
        var pendingWriteCompletions: [@Sendable () -> Void] = []
        var emitExitOnTerminate = true
    }
    private let lock = NSLock()
    private var state = State()
    var requestIDPrefix: String? {
        get { lock.withLock { state.requestIDPrefix } }
        set { lock.withLock { state.requestIDPrefix = newValue } }
    }
    var sentFrames: [Data] { lock.withLock { state.sentFrames } }
    var terminateCount: Int { lock.withLock { state.terminateCount } }
    var deferWriteCompletions: Bool {
        get { lock.withLock { state.deferWriteCompletions } }
        set { lock.withLock { state.deferWriteCompletions = newValue } }
    }
    private let responseForRequest: (@Sendable (Data) -> JSONRPCStdioTransport.Incoming?)?

    init(responseForRequest: (@Sendable (Data) -> JSONRPCStdioTransport.Incoming?)? = nil) {
        self.responseForRequest = responseForRequest
        var c: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() throws {
        // No subprocess to launch.
    }

    func send(_ data: Data) throws {
        lock.withLock { state.sentFrames.append(data) }
        if let response = responseForRequest?(data) { cont.yield(response) }
    }

    func send(_ data: Data, onWritten: @escaping @Sendable () -> Void) throws {
        try send(data)
        let deferred = lock.withLock {
            guard state.deferWriteCompletions else { return false }
            state.pendingWriteCompletions.append(onWritten)
            return true
        }
        if !deferred { onWritten() }
    }

    func completePendingWrites() {
        let completions = lock.withLock {
            let completions = state.pendingWriteCompletions
            state.pendingWriteCompletions.removeAll()
            return completions
        }
        for completion in completions {
            completion()
        }
    }

    /// When false, `terminate()` does not synthesise an `.exited` event —
    /// mirroring the real `JSONRPCStdioTransport`, whose SIGTERM is async and
    /// whose `.exited` is delivered later (or never, for a wedged adapter).
    var emitExitOnTerminate: Bool {
        get { lock.withLock { state.emitExitOnTerminate } }
        set { lock.withLock { state.emitExitOnTerminate = newValue } }
    }

    func terminate() {
        let emitExit = lock.withLock { state.terminateCount += 1
        return state.emitExitOnTerminate }
        if emitExit {
            cont.yield(.exited(0))
        }
        cont.finish()
    }

    /// Inject an inbound JSON frame as if the agent sent it.
    func send(frame: Data) {
        cont.yield(.frame(frame))
    }

    func send(frame: Data, onConsumed: @escaping @Sendable () -> Void) {
        cont.yield(.frame(frame, onConsumed: onConsumed))
    }

    func send(exitStatus: Int32, finish: Bool = true) {
        cont.yield(.exited(exitStatus))
        if finish { cont.finish() }
    }
}
