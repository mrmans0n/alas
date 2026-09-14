import Foundation
import Testing
@testable import Alas

private final class SemanticControlledTransport: LSPTransporting, @unchecked Sendable {
    let incoming: AsyncStream<LSPTransport.Incoming>
    private let continuation: AsyncStream<LSPTransport.Incoming>.Continuation
    private let lock = NSLock()
    private var frames: [LSPJSONValue] = []

    init() {
        let stream = AsyncStream<LSPTransport.Incoming>.makeStream()
        incoming = stream.stream
        continuation = stream.continuation
    }

    var semanticRequests: [LSPJSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return frames.filter { $0["method"]?.stringValue?.hasPrefix("textDocument/semanticTokens/") == true }
    }

    func start() throws {}
    func terminate() { continuation.finish() }
    func send(_ data: Data) throws {
        let frame = try LSPJSONValue.decode(from: data)
        lock.lock()
        frames.append(frame)
        lock.unlock()
        if frame["method"] == .string("initialize"), let id = frame["id"] {
            let capabilities = try LSPJSONValue.decode(from: Data(#"{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["function"],"tokenModifiers":[]},"range":true,"full":true}}}"#.utf8))
            reply(id: id, result: capabilities)
        }
    }

    func reply(id: LSPJSONValue, result: LSPJSONValue) {
        let frame = try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encodedData()
        continuation.yield(.frame(frame))
    }
}

@MainActor
struct SemanticTokensCoalescingTests {
    @Test func clientRetainsOnlyLatestPendingRequestAcrossConsumers() async throws {
        let transport = SemanticControlledTransport()
        defer { transport.terminate() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        try await client.initialize()
        func range(_ line: Int) -> LSPRange { .init(start: .init(line: line, character: 0), end: .init(line: line, character: 2)) }
        let a = Task { try await client.semanticTokens(uri: "file:///tmp/a", range: range(0)) }
        defer { a.cancel() }
        for _ in 0..<100 where transport.semanticRequests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(transport.semanticRequests.count == 1)
        let b = Task { try await client.semanticTokens(uri: "file:///tmp/a", range: range(1)) }
        defer { b.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        let c = Task { try await client.semanticTokens(uri: "file:///tmp/a", range: range(2)) }
        defer { c.cancel() }
        do {
            _ = try await b.value
            Issue.record("Superseded pending request should be cancelled")
        } catch { #expect(error is CancellationError) }
        #expect(transport.semanticRequests.count == 1)
        transport.reply(id: try #require(transport.semanticRequests.first?["id"]), result: .object(["data": .array([])]))
        #expect(try await a.value.isEmpty)
        for _ in 0..<100 where transport.semanticRequests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let latest = try #require(transport.semanticRequests.last)
        #expect(transport.semanticRequests.count == 2)
        #expect(latest["params"]?["range"]?["start"]?["line"] == .number("2"))
        transport.reply(id: try #require(latest["id"]), result: .object(["data": .array([])]))
        #expect(try await c.value.isEmpty)
    }

    @Test func transportExitEndsRefreshSubscriptions() async throws {
        let transport = SemanticControlledTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        try await client.initialize()
        let stream = await client.subscribeSemanticRefreshes()
        let reader = Task {
            for await _ in stream {}
            return true
        }
        transport.terminate()
        #expect(await reader.value)
    }
}
