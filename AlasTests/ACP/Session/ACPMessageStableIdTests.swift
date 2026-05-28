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

    @Test("toolCall row stable id matches its toolCallId")
    func toolCallId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.toolCall(.init(toolCallId: "tc-1", title: "t", kind: nil, status: "in_progress", content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        guard case .toolCall(let tc) = s.transcript.messages[0] else { Issue.record("expected tool call")
        return }
        #expect(s.transcript.messages[0].stableId == "tc-\(tc.toolCallId)")
    }
}
