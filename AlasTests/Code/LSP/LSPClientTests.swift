import Foundation
import Testing
@testable import Alas

final class FakeTransport: LSPTransporting, @unchecked Sendable {
    var incoming: AsyncStream<LSPTransport.Incoming>
    private let cont: AsyncStream<LSPTransport.Incoming>.Continuation
    private let sentLock = NSLock()
    private var sentStorage: [String] = []
    var sent: [String] { sentLock.withLock { sentStorage } }
    private(set) var terminateCount = 0
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
        sentLock.withLock { sentStorage.append(s) }
        onSend?(s)
    }
    func terminate() { terminateCount += 1 }
    func deliverFrame(_ json: String) {
        cont.yield(.frame(json.data(using: .utf8)!))
    }
    func deliverStderr(_ text: String) {
        cont.yield(.stderr(Data(text.utf8)))
    }
    /// Mirrors the live transport: report the exit status, then end the stream.
    func deliverExit(_ code: Int32) {
        cont.yield(.exited(code))
        cont.finish()
    }
    /// Finish the incoming stream so LSPClient.consume() exits and the
    /// actor's background Task drains. Call at the end of each test.
    func finish() {
        cont.finish()
    }
}

private func withTimeout<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw LSPError.requestTimedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Polls `condition` on the main actor until it holds or five seconds pass.
@MainActor
func eventually(_ description: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition(), "Timed out waiting for \(description)")
}

enum ExitScenario: String, Sendable, CaseIterable {
    case serverExits, streamEndsWithoutStatus, exitAfterShutdown
}

struct OutputTailCase: Sendable, CustomTestStringConvertible {
    let name: String
    let chunks: [String]
    let expected: [String]
    var testDescription: String { name }
}

@Suite("LSPClient.lifecycle", .serialized)
struct LSPClientLifecycleTests {
    @Test("exits are reported with the stderr tail unless the client shut the server down", arguments: ExitScenario.allCases)
    func exitReporting(_ scenario: ExitScenario) async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#)
            } else if sent.contains(#""method":"shutdown""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":null}"#)
            }
        }
        try await client.initialize()
        transport.deliverStderr("boot\npanicked at foo\n")
        switch scenario {
        case .serverExits: transport.deliverExit(101)
        case .streamEndsWithoutStatus: transport.finish()
        case .exitAfterShutdown:
            await client.shutdown()
            transport.deliverExit(0)
        }
        let events = client.lifecycleEvents
        let exits = try await withTimeout(nanoseconds: 2_000_000_000) {
            var collected: [LSPClient.ExitDetail] = []
            for await event in events {
                if case .exited(let detail) = event { collected.append(detail) }
            }
            return collected
        }
        switch scenario {
        case .serverExits:
            #expect(exits.map(\.exitCode) == [101])
            #expect(exits.first?.outputTail == ["boot", "panicked at foo"])
        case .streamEndsWithoutStatus:
            #expect(exits.map(\.exitCode) == [nil])
        case .exitAfterShutdown:
            #expect(exits.isEmpty)
        }
    }

    @Test("output tail keeps the last complete lines within its bounds", arguments: [
        OutputTailCase(name: "line split across chunks", chunks: ["pan", "icked\nnext\n"], expected: ["panicked", "next"]),
        OutputTailCase(name: "CRLF and blank lines", chunks: ["a\r\n\r\nb\r\n"], expected: ["a", "b"]),
        OutputTailCase(name: "unterminated final line", chunks: ["a\nb"], expected: ["a", "b"]),
        OutputTailCase(name: "last 20 lines", chunks: [(1...25).map { "l\($0)\n" }.joined()], expected: (6...25).map { "l\($0)" }),
        OutputTailCase(
            name: "8 KB cap drops oldest lines",
            chunks: [String(repeating: "x", count: 5000) + "\n" + String(repeating: "y", count: 5000) + "\n"],
            expected: [String(repeating: "y", count: 5000)]
        ),
    ])
    func outputTail(_ testCase: OutputTailCase) {
        var tail = LSPOutputTail()
        for chunk in testCase.chunks { tail.append(Data(chunk.utf8)) }
        #expect(tail.finish() == testCase.expected)
    }

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

    @Test("formatting request sends document URI and options")
    func formatting() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"documentFormattingProvider":true}}}"#)
            } else if sent.contains(#""method":"textDocument/formatting""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"let"}]}"#)
            }
        }
        try await client.initialize()
        #expect((transport.sent.first ?? "").contains(#""formatting":{"dynamicRegistration":false}"#))
        let edits = try await client.formatting(
            uri: "file:///tmp/x.swift",
            options: LSPFormattingOptions(tabSize: 2, insertSpaces: true)
        )
        let request = transport.sent.last ?? ""
        #expect(request.contains(#""method":"textDocument/formatting""#))
        #expect(request.contains(#""uri":"file:///tmp/x.swift""#))
        #expect(request.contains(#""tabSize":2"#))
        #expect(request.contains(#""insertSpaces":true"#))
        #expect(edits == [
            LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 3)
                ),
                newText: "let"
            )
        ])
        transport.finish()
    }

    @Test("completion request sends document position and context")
    func completion() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#)
            } else if sent.contains(#""method":"textDocument/completion""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":{"isIncomplete":false,"items":[{"label":"openEditor","kind":2}]}}"#)
            }
        }

        try await client.initialize()
        #expect((transport.sent.first ?? "").contains(#""completion":{"dynamicRegistration":false"#))

        let result = try await client.completion(
            uri: "file:///tmp/AppState.swift",
            position: LSPPosition(line: 4, character: 12),
            context: LSPCompletionContext(triggerKind: .invoked, triggerCharacter: nil)
        )

        let request = transport.sent.last ?? ""
        #expect(request.contains(#""method":"textDocument/completion""#))
        #expect(request.contains(#""uri":"file:///tmp/AppState.swift""#))
        #expect(request.contains(#""line":4"#))
        #expect(request.contains(#""character":12"#))
        #expect(request.contains(#""triggerKind":1"#))
        #expect(result.items.map(\.label) == ["openEditor"])
        transport.finish()
    }

    @Test("initialize stores completion trigger characters")
    func completionTriggerCharacters() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "cpp", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"completionProvider":{"triggerCharacters":[".","->","::"]}}}}"#)
            }
        }

        try await client.initialize()

        #expect(await client.completionTriggerCharacters == [".", "->", "::"])
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

    @Test("shutdown terminates even when the server never replies")
    func shutdownTerminatesUnresponsiveServer() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#)
            }
        }
        try await client.initialize()

        try await withTimeout(nanoseconds: 3_000_000_000) {
            await client.shutdown()
        }

        #expect(transport.terminateCount == 1)
        transport.finish()
    }

    @Test("incremental text sync sends concrete edit ranges")
    func incrementalTextSyncUsesConcreteEditRanges() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":2}}}"#)
            }
        }
        try await client.initialize()
        try await client.didChange(
            uri: "file:///tmp/x.swift",
            version: 2,
            text: "let xy = 1\n",
            previousText: "let x = 1\n",
            edits: [EditorTextEdit(location: 5, oldLength: 0, replacementText: "y")]
        )
        let change = transport.sent.last ?? ""
        #expect(change.contains(#""start":{"#))
        #expect(change.contains(#""end":{"#))
        #expect(change.contains(#""line":0"#))
        #expect(change.contains(#""character":5"#))
        #expect(change.contains(#""rangeLength":0"#))
        #expect(change.contains(#""text":"y""#))
        #expect(!change.contains(#""text":"let xy = 1\n""#))
        transport.finish()
    }

    @Test("decode capabilities extracts pull diagnostics support")
    func decodeCapabilitiesExtractsPullDiagnostics() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "kotlin", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"diagnosticProvider":{"identifier":null,"interFileDependencies":true,"workspaceDiagnostics":false}}}}"#)
            }
        }
        try await client.initialize()
        let supportsPull = await client.supportsPullDiagnostics
        #expect(supportsPull)
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

    @Test("requestDiagnostics decodes full report")
    func requestDiagnosticsDecodesFullReport() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "kotlin", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"diagnosticProvider":{}}}}"#)
            } else if sent.contains("\"method\":\"textDocument/diagnostic\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":{"kind":"full","items":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"message":"error"}]}}"#)
            }
        }
        try await client.initialize()
        let diags = try await client.requestDiagnostics(uri: "file:///tmp/x.kt", previousResultId: nil)
        #expect(diags?.count == 1)
        #expect(diags?.first?.message == "error")
        transport.finish()
    }

    @Test("requestDiagnostics returns nil on unchanged report")
    func requestDiagnosticsUnchangedReport() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "kotlin", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"diagnosticProvider":{}}}}"#)
            } else if sent.contains("\"method\":\"textDocument/diagnostic\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":{"kind":"unchanged","resultId":"abc"}}"#)
            }
        }
        try await client.initialize()
        let diags = try await client.requestDiagnostics(uri: "file:///tmp/x.kt", previousResultId: nil)
        #expect(diags == nil)
        transport.finish()
    }

    @Test("requestDiagnostics includes previousResultId when non-nil")
    func requestDiagnosticsIncludesPreviousResultId() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "kotlin", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("\"method\":\"initialize\"") {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"diagnosticProvider":{}}}}"#)
            } else if sent.contains("\"method\":\"textDocument/diagnostic\"") {
                #expect(sent.contains("\"previousResultId\":\"prev123\""))
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":{"kind":"full","items":[]}}"#)
            }
        }
        try await client.initialize()
        _ = try await client.requestDiagnostics(uri: "file:///tmp/x.kt", previousResultId: "prev123")
        transport.finish()
    }

    @Test("work-done progress yields ordered snapshots, ignores malformed updates, and acknowledges create")
    func workDoneProgress() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "rust", rootURI: "file:///tmp", progressCoalescing: .zero)
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#)
            }
        }
        try await client.initialize()
        #expect((transport.sent.first ?? "").contains(#""window":{"workDoneProgress":true}"#))

        transport.deliverFrame(#"{"jsonrpc":"2.0","id":"p1","method":"window/workDoneProgress/create","params":{"token":"idx"}}"#)
        // Ignored: report for an unknown token, and a progress notification without a value.
        transport.deliverFrame(#"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"ghost","value":{"kind":"report","percentage":5}}}"#)
        transport.deliverFrame(#"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"idx"}}"#)
        transport.deliverFrame(#"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"idx","value":{"kind":"begin","title":"Indexing","percentage":0}}}"#)
        transport.deliverFrame(#"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"idx","value":{"kind":"report","message":"412/980","percentage":42}}}"#)
        transport.deliverFrame(#"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"idx","value":{"kind":"end"}}}"#)

        let events = client.lifecycleEvents
        let snapshots = try await withTimeout(nanoseconds: 2_000_000_000) {
            var collected: [[LSPClient.ProgressTask]] = []
            for await event in events {
                if case .progress(let tasks) = event { collected.append(tasks) }
                if collected.count == 3 { break }
            }
            return collected
        }
        #expect(snapshots == [
            [LSPClient.ProgressTask(token: "idx", title: "Indexing", message: nil, percentage: 0)],
            [LSPClient.ProgressTask(token: "idx", title: "Indexing", message: "412/980", percentage: 42)],
            [],
        ])
        let ack = transport.sent.first { $0.contains(#""id":"p1""#) } ?? ""
        #expect(ack.contains(#""result":null"#))
        transport.finish()
    }

    @Test("oversized progress percentages clamp to 100 instead of trapping")
    func oversizedProgressPercentage() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "rust", rootURI: "file:///tmp", progressCoalescing: .zero)
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#)
            }
        }
        try await client.initialize()
        transport.deliverFrame(#"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"idx","value":{"kind":"begin","title":"Indexing","percentage":1e100}}}"#)
        let events = client.lifecycleEvents
        let first = try await withTimeout(nanoseconds: 2_000_000_000) {
            for await event in events {
                if case .progress(let tasks) = event { return tasks }
            }
            return []
        }
        #expect(first.map(\.percentage) == [100])
        transport.finish()
    }
}
