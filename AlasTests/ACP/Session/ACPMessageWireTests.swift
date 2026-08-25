import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPMessageWire")
struct ACPMessageWireTests {
    @Test("decode round-trips user payload")
    func userRoundTrip() throws {
        let original: ACPMessage = .user(
            id: UUID(),
            text: "hello",
            attachments: [.init(uri: "file:///x.txt", name: "x.txt")])
        let payload = try ACPMessageCodec.encode(original)
        let wire = try ACPMessageWire.decode(kind: "user", payload: payload)
        guard case let .user(_, text, attachments, source) = wire else {
            #expect(Bool(false), "expected .user, got \(wire)")
            return
        }
        #expect(text == "hello")
        #expect(attachments == [.init(uri: "file:///x.txt", name: "x.txt")])
        #expect(source == nil)
    }

    @Test("delegated user provenance round-trips through the wire payload")
    func delegatedUserRoundTrip() throws {
        let source = ACPDelegatedPromptSource(sessionId: "parent", messageId: "message-1")
        let original: ACPMessage = .user(
            id: UUID(), messageId: "message-1", text: "delegate", attachments: [], delegatedSource: source)
        let wire = try ACPMessageWire.decode(kind: "user", payload: try ACPMessageCodec.encode(original))
        guard case let .user(messageId, text, _, decodedSource) = wire else {
            Issue.record("expected user wire payload")
            return
        }
        #expect(messageId == "message-1")
        #expect(text == "delegate")
        #expect(decodedSource == source)
    }

    @Test("decode round-trips agent text")
    func agentRoundTrip() throws {
        let original: ACPMessage = .agent(id: UUID(), messageId: "agent-1", StreamingText("agent prose"))
        let payload = try ACPMessageCodec.encode(original)
        let wire = try ACPMessageWire.decode(kind: "agent", payload: payload)
        guard case let .agent(messageId, text, _, _) = wire else {
            #expect(Bool(false), "expected .agent, got \(wire)")
            return
        }
        #expect(messageId == "agent-1")
        #expect(text == "agent prose")
        #expect(wire.toMessage().stableId == "acp-agent:agent-1")
    }

    @Test("agent phase and metadata survive persistence")
    func agentPhaseRoundTrip() throws {
        let metadata = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("commentary")]), "future": AnyCodable(true)])
        let original: ACPMessage = .agent(
            id: UUID(), messageId: "commentary-1",
            StreamingText("working", phase: .commentary, metadata: metadata))

        let wire = try ACPMessageWire.decode(kind: "agent", payload: ACPMessageCodec.encode(original))
        guard case .agent(let messageId, let text, let phase, let decodedMetadata) = wire else {
            Issue.record("expected agent wire payload")
            return
        }
        #expect(messageId == "commentary-1")
        #expect(text == "working")
        #expect(phase == .commentary)
        #expect(decodedMetadata == metadata)
        guard case .agent(_, _, let buffer) = wire.toMessage() else {
            Issue.record("expected agent message")
            return
        }
        #expect(buffer.phase == .commentary)
        #expect(buffer.metadata == metadata)
    }

    @Test("legacy agent payload still decodes without a phase")
    func legacyAgentPayload() throws {
        let wire = try ACPMessageWire.decode(kind: "agent", payload: Data(#"{"messageId":"agent-1","text":"answer"}"#.utf8))
        guard case .agent(_, _, let phase, let metadata) = wire else {
            Issue.record("expected agent wire payload")
            return
        }
        #expect(phase == nil)
        #expect(metadata == nil)
    }

    @Test("decode round-trips tool call")
    func toolCallRoundTrip() throws {
        let tc = ACPMessage.ToolCall(
            toolCallId: "tc1", title: "read",
            kind: "fs.read", status: "completed",
            content: "abc", preview: "abc",
            locations: ["/a"])
        let original: ACPMessage = .toolCall(tc)
        let payload = try ACPMessageCodec.encode(original)
        let wire = try ACPMessageWire.decode(kind: "tool_call", payload: payload)
        guard case let .toolCall(decoded) = wire else {
            #expect(Bool(false), "expected .toolCall, got \(wire)")
            return
        }
        #expect(decoded == tc)
    }

    @Test("tool call decodes missing enriched fields as nil/empty")
    func toolCallMissingEnrichedFieldsDecodeAsDefault() throws {
        let payload = """
        {
          "toolCallId": "tc1",
          "title": "read",
          "kind": "fs.read",
          "status": "completed",
          "content": "abc",
          "preview": "abc",
          "locations": ["/a"]
        }
        """.data(using: .utf8)!
        let wire = try ACPMessageWire.decode(kind: "tool_call", payload: payload)
        guard case let .toolCall(decoded) = wire else {
            #expect(Bool(false), "expected .toolCall, got \(wire)")
            return
        }
        #expect(decoded.contentLanguage == nil)
        #expect(decoded.rawOutput == nil)
        #expect(decoded.metadata == nil)
        #expect(decoded.assets == [])
        #expect(decoded.terminalIds.isEmpty)
    }

    @Test("tool call decodes enriched fields from wire payload")
    func toolCallWireDecodesEnrichedFields() throws {
        let payload = """
        {
          "toolCallId": "tc2",
          "title": "read",
          "kind": "fs.read",
          "status": "completed",
          "content": "raw",
          "preview": "raw",
          "contentLanguage": "plaintext",
          "rawInput": "{\\\"command\\\":\\\"read_file\\\"}",
          "rawOutput": "{\\\"status\\\":\\\"ok\\\"}",
          "metadata": {
            "is_mcp_tool_call": true
          },
          "assets": [
            {
              "kind": "image",
              "data": "aGVsbG8=",
              "uri": "file:///tmp/screenshot.png",
              "mimeType": "image/png",
              "name": "screenshot.png"
            },
            {
              "kind": "resource",
              "uri": "file:///tmp/resource.txt",
              "mimeType": "text/plain",
              "name": "resource.txt"
            }
          ],
          "locations": ["/a", "/b"],
          "terminalIds": ["term-1", "term-2"]
        }
        """.data(using: .utf8)!

        let wire = try ACPMessageWire.decode(kind: "tool_call", payload: payload)
        guard case let .toolCall(decoded) = wire else {
            #expect(Bool(false), "expected .toolCall, got \(wire)")
            return
        }

        #expect(decoded.contentLanguage == "plaintext")
        #expect(decoded.rawInput == #"{"command":"read_file"}"#)
        #expect(decoded.rawOutput == #"{"status":"ok"}"#)
        #expect(decoded.metadata?.value as? [String: AnyCodable] != nil)
        #expect((decoded.metadata?.value as? [String: AnyCodable])?["is_mcp_tool_call"]?.value as? Bool == true)
        #expect(decoded.assets.count == 2)
        #expect(decoded.assets[0].kind == .image)
        #expect(decoded.assets[0].name == "screenshot.png")
        #expect(decoded.assets[1].kind == .resource)
        #expect(decoded.assets[1].name == "resource.txt")
        #expect(decoded.locations == ["/a", "/b"])
        #expect(decoded.terminalIds == ["term-1", "term-2"])
    }

    @Test("unknown kind decodes to system notice")
    func unknownKind() throws {
        let wire = try ACPMessageWire.decode(kind: "mystery", payload: Data())
        guard case let .systemNotice(text) = wire else {
            #expect(Bool(false), "expected .systemNotice, got \(wire)")
            return
        }
        #expect(text.contains("unknown message kind"))
    }

    @Test("toMessage produces ACPMessage with fresh ids")
    func toMessage() throws {
        let wire: ACPMessageWire = .agent(messageId: nil, text: "x", phase: nil, metadata: nil)
        let m1 = wire.toMessage()
        let m2 = wire.toMessage()
        // Same wire, different UUIDs each call (matches existing decode behavior).
        guard case let .agent(id1, _, _) = m1, case let .agent(id2, _, _) = m2 else {
            #expect(Bool(false))
            return
        }
        #expect(id1 != id2)
    }
}
