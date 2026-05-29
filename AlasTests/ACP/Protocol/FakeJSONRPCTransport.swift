import Foundation
@testable import Alas

/// Minimal in-process transport for `ACPStdioClient` tests.
/// Call `send(frame:)` to inject a raw JSON frame as if the agent
/// had written it to stdout.
final class FakeJSONRPCTransport: JSONRPCStdioTransporting, @unchecked Sendable {
    private let cont: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>

    init() {
        var c: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() throws {
        // No subprocess to launch.
    }

    func send(_ data: Data) throws {
        // Discard outbound bytes in tests (we only care about inbound dispatch).
    }

    func terminate() {
        cont.yield(.exited(0))
        cont.finish()
    }

    /// Inject an inbound JSON frame as if the agent sent it.
    func send(frame: Data) {
        cont.yield(.frame(frame))
    }
}
