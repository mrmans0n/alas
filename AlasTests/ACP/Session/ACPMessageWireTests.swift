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
        guard case let .user(_, text, attachments) = wire else {
            #expect(Bool(false), "expected .user, got \(wire)")
            return
        }
        #expect(text == "hello")
        #expect(attachments == [.init(uri: "file:///x.txt", name: "x.txt")])
    }

    @Test("decode round-trips agent text")
    func agentRoundTrip() throws {
        let original: ACPMessage = .agent(id: UUID(), messageId: "agent-1", StreamingText("agent prose"))
        let payload = try ACPMessageCodec.encode(original)
        let wire = try ACPMessageWire.decode(kind: "agent", payload: payload)
        guard case let .agent(messageId, text) = wire else {
            #expect(Bool(false), "expected .agent, got \(wire)")
            return
        }
        #expect(messageId == "agent-1")
        #expect(text == "agent prose")
        #expect(wire.toMessage().stableId == "acp-agent:agent-1")
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

    @Test("tool call decodes missing content language as nil")
    func toolCallMissingContentLanguageDecodesAsNil() throws {
        let payload = """
        {
          "toolCallId": "tc1",
          "title": "read",
          "kind": "fs.read",
          "status": "completed",
          "content": "abc",
          "preview": "abc",
          "locations": ["/a"],
          "terminalIds": []
        }
        """.data(using: .utf8)!
        let wire = try ACPMessageWire.decode(kind: "tool_call", payload: payload)
        guard case let .toolCall(decoded) = wire else {
            #expect(Bool(false), "expected .toolCall, got \(wire)")
            return
        }
        #expect(decoded.contentLanguage == nil)
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
        let wire: ACPMessageWire = .agent(messageId: nil, text: "x")
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
