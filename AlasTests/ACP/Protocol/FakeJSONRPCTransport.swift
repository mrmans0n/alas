import Foundation
@testable import Alas

/// Minimal in-process transport for `ACPStdioClient` tests.
/// Call `send(frame:)` to inject a raw JSON frame as if the agent
/// had written it to stdout.
final class FakeJSONRPCTransport: JSONRPCStdioTransporting, @unchecked Sendable {
    private let cont: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    private(set) var sentFrames: [Data] = []
    private(set) var terminateCount = 0

    init() {
        var c: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() throws {
        // No subprocess to launch.
    }

    func send(_ data: Data) throws {
        sentFrames.append(data)
    }

    /// When false, `terminate()` does not synthesise an `.exited` event —
    /// mirroring the real `JSONRPCStdioTransport`, whose SIGTERM is async and
    /// whose `.exited` is delivered later (or never, for a wedged adapter).
    var emitExitOnTerminate = true

    func terminate() {
        terminateCount += 1
        if emitExitOnTerminate {
            cont.yield(.exited(0))
        }
        cont.finish()
    }

    /// Inject an inbound JSON frame as if the agent sent it.
    func send(frame: Data) {
        cont.yield(.frame(frame))
    }

    func send(exitStatus: Int32) {
        cont.yield(.exited(exitStatus))
        cont.finish()
    }
}
