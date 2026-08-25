import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPMessage")
struct ACPMessageTests {
    @Test("user message round-trips through JSON")
    func userRoundtrip() throws {
        let m = ACPMessage.user(id: UUID(), text: "hello", attachments: [.init(uri: "file:///a.swift", name: "a.swift")])
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        guard case .user(_, _, let text, let atts, _) = back else {
            Issue.record("expected user message")
            return
        }
        #expect(text == "hello")
        #expect(atts.count == 1)
        #expect(atts[0].uri == "file:///a.swift")
    }
    @Test("agent message round-trips")
    func agentRoundtrip() throws {
        let m = ACPMessage.agent(id: UUID(), messageId: "agent-1", StreamingText("world"))
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        guard case .agent(_, let messageId, let buf) = back else {
            Issue.record("expected agent message")
            return
        }
        #expect(messageId == "agent-1")
        #expect(back.stableId == "acp-agent:agent-1")
        #expect(buf.value == "world")
    }
    @Test("tool call round-trips")
    func toolRoundtrip() throws {
        let m = ACPMessage.toolCall(.init(
            toolCallId: "tc-1", title: "read_file", kind: "read",
            status: "completed", content: "8.2k bytes", preview: "8.2k",
            locations: ["file://x"]))
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        #expect(back == m)
    }

    @Test("tool call content revision advances only when displayed content changes")
    func toolCallContentRevisionTracksDisplayedContentChanges() {
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "tc-revision",
            title: "run",
            kind: "execute",
            status: "in_progress",
            content: "first")

        #expect(toolCall.contentRevision == 0)
        toolCall.replaceContent("first")
        #expect(toolCall.contentRevision == 0)
        toolCall.replaceContent("second")
        #expect(toolCall.content == "second")
        #expect(toolCall.contentRevision == 1)
    }

    @Test("tool call truncation advances content revision when displayed content is shortened")
    func toolCallTruncationAdvancesContentRevisionWhenContentChanges() {
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "tc-truncated-revision",
            title: "run",
            kind: "execute",
            status: "completed",
            content: String(repeating: "x", count: ACPMessage.ToolCall.truncatedTailBytes + 8))

        toolCall.truncateForOffWindow()

        #expect(toolCall.content.count == ACPMessage.ToolCall.truncatedTailBytes)
        #expect(toolCall.contentRevision == 1)
    }

    @Test("tool call enriched fields round-trip")
    func toolCallEnrichedRoundtrip() throws {
        let metadata = AnyCodable([
            "is_mcp_tool_call": AnyCodable(true),
            "tool": AnyCodable("read_file")
        ])
        let assets: [ACPMessage.ToolCallAsset] = [
            .image(
                data: "aGVsbG8=",
                uri: "file:///tmp/screenshot.png",
                mimeType: "image/png",
                name: "screenshot.png"
            ),
            .resource(uri: "file:///tmp/result.txt", name: nil, mimeType: "text/plain"),
            .resource(uri: "file:///tmp/result-named.txt", name: "result.txt", mimeType: "text/plain")
        ]
        let m = ACPMessage.toolCall(.init(
            toolCallId: "tc-2",
            title: "read_file",
            kind: "read",
            status: "completed",
            content: "response text",
            preview: "response text",
            rawInput: #"{\"command\":\"read_file\"}"#,
            rawOutput: #"{\"status\":\"ok\"}"#,
            metadata: metadata,
            assets: assets,
            locations: ["file://x"],
            terminalIds: ["term-1"]))
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        #expect(back == m)
    }

    @Test("context compaction facts persist with a tool call")
    func contextCompactionRoundtrip() throws {
        let message = ACPMessage.toolCall(.init(
            toolCallId: "context-compaction:compact-1",
            title: "Compacting context",
            kind: "context_compaction",
            status: "completed",
            metadata: AnyCodable([
                "contextCompaction": [
                    "version": 1,
                    "trigger": "automatic",
                    "preTokens": 128_000,
                    "postTokens": 16_000,
                    "durationMs": 950
                ]
            ])))

        let payload = try ACPMessageCodec.encode(message)
        guard case .toolCall(let restored) = try ACPMessageCodec.decode(kind: message.kind, payload: payload),
              let compaction = ACPContextCompaction(toolCall: restored) else {
            Issue.record("expected persisted context compaction")
            return
        }
        #expect(compaction.tokensBefore == 128_000)
        #expect(compaction.tokensAfter == 16_000)
        #expect(compaction.durationMs == 950)
    }

    @Test("legacy contentSummary decode keeps backward-compatible preview")
    func toolCallLegacyContentSummary() throws {
        let payload = """
        {
          "toolCallId": "tc-legacy-summary",
          "title": "read_file",
          "kind": "read",
          "status": "completed",
          "content": "raw output",
          "contentSummary": "legacy summary",
          "locations": ["/x"]
        }
        """.data(using: .utf8)!
        let back = try ACPMessageCodec.decode(kind: "tool_call", payload: payload)
        guard case .toolCall(let tc) = back else {
            Issue.record("expected toolCall")
            return
        }
        #expect(tc.preview == "legacy summary")
        #expect(tc.rawOutput == nil)
        #expect(tc.metadata == nil)
        #expect(tc.assets == [])
    }

    @Test("tool call equality differs on terminalIds")
    func toolCallTerminalIdAffectsEquality() throws {
        let a = ACPMessage.ToolCall(
            toolCallId: "tc-1", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            terminalIds: ["term-a"])
        let b = ACPMessage.ToolCall(
            toolCallId: "tc-1", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            terminalIds: ["term-b"])
        #expect(a != b)
    }

    @Test("tool call equality and hash align for same metadata")
    func toolCallMetadataEqualityAndHash() throws {
        let metadata = AnyCodable(["is_mcp_tool_call": AnyCodable(true)])
        let a = ACPMessage.ToolCall(
            toolCallId: "tc-2", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            rawOutput: #"{\"ok\":true}"#,
            metadata: metadata)
        let b = ACPMessage.ToolCall(
            toolCallId: "tc-2", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            rawOutput: #"{\"ok\":true}"#,
            metadata: metadata)
        #expect(a == b)

        var ha = Hasher()
        a.hash(into: &ha)
        var hb = Hasher()
        b.hash(into: &hb)
        #expect(ha.finalize() == hb.finalize())
    }

    @Test("tool call metadata order does not affect equality or hash")
    func toolCallMetadataDictionaryOrderIsDeterministic() throws {
        var first: [String: AnyCodable] = [:]
        first["first"] = AnyCodable("value")
        first["second"] = AnyCodable(99)

        var second: [String: AnyCodable] = [:]
        second["second"] = AnyCodable(99)
        second["first"] = AnyCodable("value")

        #expect(AnyCodable(first) == AnyCodable(second))

        let a = ACPMessage.ToolCall(
            toolCallId: "tc-order", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            metadata: AnyCodable(first))
        let b = ACPMessage.ToolCall(
            toolCallId: "tc-order", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            metadata: AnyCodable(second))
        #expect(a == b)

        var ha = Hasher()
        a.hash(into: &ha)
        var hb = Hasher()
        b.hash(into: &hb)
        #expect(ha.finalize() == hb.finalize())
    }

    @Test("AnyCodable supports raw Swift dictionary literals")
    func anyCodableSupportsRawSwiftDictionaries() throws {
        let prewrapped: [String: AnyCodable] = [
            "tool": AnyCodable("read"),
            "is_mcp_tool_call": AnyCodable(true),
            "args": AnyCodable([AnyCodable(1), AnyCodable("two"), AnyCodable(["nested": AnyCodable(false)])])
        ]
        let a = AnyCodable(prewrapped)
        let b = AnyCodable(["is_mcp_tool_call": true, "args": [1, "two", ["nested": false]], "tool": "read"])
        #expect(a == b)

        var ha = Hasher()
        a.hash(into: &ha)
        var hb = Hasher()
        b.hash(into: &hb)
        #expect(ha.finalize() == hb.finalize())

        let payload = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: payload)
        #expect(decoded == a)
        #expect(decoded == b)

        let arrayPayload = try JSONEncoder().encode(AnyCodable([1, "two", ["nested": false]]))
        let decodedArray = try JSONDecoder().decode(AnyCodable.self, from: arrayPayload)
        #expect(decodedArray == AnyCodable([1, "two", ["nested": false]]))

        var hc = Hasher()
        a.hash(into: &hc)
        var hd = Hasher()
        decoded.hash(into: &hd)
        #expect(hc.finalize() == hd.finalize())
    }

    @Test("AnyCodable keeps distinct dictionaries from comparing equal")
    func anyCodableDistinctDictionariesAreDistinct() throws {
        let a = AnyCodable(["a": 1, "b": 2])
        let b = AnyCodable(["a": 1, "b": 3])
        #expect(a != b)
    }

    @Test("AnyCodable preserves numeric NSNumbers")
    func anyCodablePreservesNumericNSNumbers() throws {
        let value = AnyCodable([
            "exit_code": NSNumber(value: 1),
            "ok": NSNumber(value: true)
        ])

        let payload = try JSONEncoder().encode(value)
        let json = try #require(String(data: payload, encoding: .utf8))
        #expect(json.contains(#""exit_code":1"#))
        #expect(json.contains(#""ok":true"#))
    }

    @Test("tool call equality differs on rawOutput")
    func toolCallRawOutputAffectsEquality() throws {
        let a = ACPMessage.ToolCall(
            toolCallId: "tc-3", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            rawOutput: #"{\"ok\":true}"#)
        let b = ACPMessage.ToolCall(
            toolCallId: "tc-3", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            rawOutput: #"{\"ok\":false}"#)
        #expect(a != b)
    }

    @Test("tool call equality differs on assets")
    func toolCallAssetsAffectEquality() throws {
        let a = ACPMessage.ToolCall(
            toolCallId: "tc-4", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            assets: [.image(data: "aGVsbG8=", uri: "file:///a.png", mimeType: "image/png", name: "a.png")])
        let b = ACPMessage.ToolCall(
            toolCallId: "tc-4", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output",
            assets: [.resource(uri: "file:///a.txt", name: "a.txt")])
        #expect(a != b)
    }

    @Test("tool call truncation flag is excluded from equality and hashing")
    func toolCallTruncatedFlagExcludedFromEqualityAndHash() throws {
        var a = ACPMessage.ToolCall(
            toolCallId: "tc-5", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output")
        var b = ACPMessage.ToolCall(
            toolCallId: "tc-5", title: "read", kind: "read",
            status: "completed", content: "output", preview: "output")
        b.isContentTruncated = true

        #expect(a == b)

        var ha = Hasher()
        a.hash(into: &ha)
        var hb = Hasher()
        b.hash(into: &hb)
        #expect(ha.finalize() == hb.finalize())
    }

    @Test("file edit round-trips")
    func editRoundtrip() throws {
        let m = ACPMessage.fileEdit(id: UUID(), .init(
            path: "x.swift", added: 4, removed: 1,
            oldText: "abc\ndef\n", newText: "abc\nGHI\ndef\n"
        ))
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        guard case .fileEdit(_, let edit) = back else {
            Issue.record("expected file edit")
            return
        }
        #expect(edit.path == "x.swift")
        #expect(edit.added == 4)
        #expect(edit.removed == 1)
        #expect(edit.oldText == "abc\ndef\n")
        #expect(edit.newText == "abc\nGHI\ndef\n")
    }

    @Test("file edit decodes with nil oldText for backward compat")
    func editRoundtripBackwardCompat() throws {
        let payload = try JSONEncoder().encode(OldFormat(path: "y.swift", added: 1, removed: 0))
        let back = try ACPMessageCodec.decode(kind: "file_edit", payload: payload)
        guard case .fileEdit(_, let edit) = back else {
            Issue.record("expected file edit")
            return
        }
        #expect(edit.path == "y.swift")
        #expect(edit.oldText == nil)
        #expect(edit.newText == "")
    }

    private struct OldFormat: Codable {
        let path: String
        let added: Int
        let removed: Int
    }
}
