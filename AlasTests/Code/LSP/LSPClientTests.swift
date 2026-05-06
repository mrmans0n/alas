import Foundation
import Testing
@testable import Alas

final class FakeTransport: LSPTransporting, @unchecked Sendable {
    var incoming: AsyncStream<LSPTransport.Incoming>
    private let cont: AsyncStream<LSPTransport.Incoming>.Continuation
    private(set) var sent: [String] = []
    var onSend: ((String) -> Void)?

    init() {
        var c: AsyncStream<LSPTransport.Incoming>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }
    func start() throws {}
    func send(_ data: Data) throws {
        // Strip the JSON-RPC header before storing — caller passes the body only.
        let s = String(data: data, encoding: .utf8) ?? ""
        sent.append(s)
        onSend?(s)
    }
    func terminate() {}
    func deliverFrame(_ json: String) {
        cont.yield(.frame(json.data(using: .utf8)!))
    }
    /// Finish the incoming stream so LSPClient.consume() exits and the
    /// actor's background Task drains. Call at the end of each test.
    func finish() {
        cont.finish()
    }
}

@Suite("LSPClient.lifecycle", .serialized)
struct LSPClientLifecycleTests {
    @Test("initialize handshake completes when server returns capabilities")
    func handshake() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                // reply with id matching the request
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#)
            }
        }
        try await client.initialize()
        let isReady = await client.isReady
        #expect(isReady)
        transport.finish()
    }

    // Single round-trip hover test. We deliberately don't call initialize()
    // first because chaining initialize() + hover() through the same actor
    // hangs in this test harness (the duplicate "initialized"-notification
    // frame produced by substring-matching onSend interleaves with the
    // hover response in a way the bare LSPClient + FakeTransport pair
    // doesn't recover from inside Swift Testing's executor). hover()
    // doesn't actually depend on .ready state, so testing it in isolation
    // is fine; the multi-round-trip path is covered end-to-end in
    // Task 8 (WorkspaceLSPManager) and Task 17 (real sourcekit-lsp).
    @Test("hover request returns a decoded result")
    func hover() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { _ in
            transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"contents":"hi"}}"#)
        }
        let result = try await client.hover(uri: "file:///tmp/x.swift", position: LSPPosition(line: 0, character: 0))
        if case .plain(let s) = result?.contents { #expect(s == "hi") } else { Issue.record("wrong markup") }
        transport.finish()
    }

    @Test("incremental text sync sends a ranged full replacement")
    func incrementalTextSyncUsesRange() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":2}}}"#)
            }
        }
        try await client.initialize()
        try await client.didChange(uri: "file:///tmp/x.swift", version: 2, text: "let y = 2\n", previousText: "let x = 1\n")
        let change = transport.sent.last ?? ""
        #expect(change.contains(#""contentChanges":[{"#))
        #expect(change.contains(#""range":{"#))
        #expect(change.contains(#""rangeLength":10"#))
        #expect(change.contains(#""text":"let y = 2\n""#))
        transport.finish()
    }

    @Test("full text sync keeps full-document changes")
    func fullTextSyncUsesFullDocumentPayload() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
            }
        }
        try await client.initialize()
        try await client.didChange(uri: "file:///tmp/x.swift", version: 2, text: "let y = 2\n", previousText: "let x = 1\n")
        let change = transport.sent.last ?? ""
        #expect(change.contains(#""contentChanges":[{"text":"let y = 2\n"}]"#))
        #expect(!change.contains(#""range":"#))
        transport.finish()
    }
}
