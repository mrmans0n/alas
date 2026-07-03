import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPMessage stable identity")
struct ACPMessageStableIdTests {
    @Test("user/agent rows get distinct stable ids on append")
    func distinctIds() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.recordUserPrompt(text: "hi", attachments: [])
        s.apply(.agentMessageChunk(.text("hello")))
        #expect(s.transcript.messages.count == 2)
        #expect(s.transcript.messages[0].stableId != s.transcript.messages[1].stableId)
    }

    @Test("appending a new agent chunk to an existing agent row keeps the same stable id")
    func chunkPreservesId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.agentMessageChunk(.text("hello ")))
        let id1 = s.transcript.messages[0].stableId
        s.apply(.agentMessageChunk(.text("world")))
        #expect(s.transcript.messages.count == 1)
        #expect(s.transcript.messages[0].stableId == id1)
    }

    @Test("agent chunks with messageId use it as stable id and append by id")
    func agentChunksUseMessageId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text("hello"))))
        s.apply(.agentThoughtChunk(.init(messageId: "thought-1", content: .text("thinking"))))
        s.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text(" world"))))

        #expect(s.transcript.messages.count == 2)
        #expect(s.transcript.messages[0].stableId == "agent-1")
        if case .agent(_, _, let text) = s.transcript.messages[0] {
            #expect(text.value == "hello world")
        } else {
            Issue.record("expected agent message")
        }
    }

    @Test("different messageIds create separate transcript rows")
    func differentMessageIdsCreateRows() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text("one"))))
        s.apply(.agentMessageChunk(.init(messageId: "agent-2", content: .text("two"))))

        #expect(s.transcript.messages.map(\.stableId) == ["agent-1", "agent-2"])
    }

    @Test("user chunks with messageId use it as stable id and append by id")
    func userChunksUseMessageId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("hello"))))
        s.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text("reply"))))
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text(" world"))))

        #expect(s.transcript.messages.map(\.stableId) == ["user-1", "agent-1"])
        if case .user(_, _, let text, let attachments) = s.transcript.messages[0] {
            #expect(text == "hello world")
            #expect(attachments.isEmpty)
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("toolCall row stable id matches its toolCallId")
    func toolCallId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.toolCall(.init(toolCallId: "tc-1", title: "t", kind: nil, status: "in_progress", content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        guard case .toolCall(let tc) = s.transcript.messages[0] else { Issue.record("expected tool call")
        return }
        #expect(s.transcript.messages[0].stableId == "tc-\(tc.toolCallId)")
    }
}
