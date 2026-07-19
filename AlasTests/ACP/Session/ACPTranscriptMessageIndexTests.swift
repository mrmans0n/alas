import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscript message indices")
struct ACPTranscriptMessageIndexTests {
    @Test("direct replacement rebuilds text and tool-call indices")
    func directReplacementRebuildsIndices() {
        let transcript = ACPTranscript()
        let toolCall = ACPMessage.ToolCall(
            toolCallId: "tool-1",
            title: "Read",
            status: "in_progress",
            content: "",
            preview: "",
            locations: []
        )

        transcript.messages = [
            .systemNotice(id: UUID(), text: "before"),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("answer")),
            .thought(id: UUID(), messageId: "thought-1", StreamingText("reasoning")),
            .user(id: UUID(), messageId: "user-1", text: "prompt", attachments: []),
            .toolCall(toolCall)
        ]

        #expect(transcript.messageIndex(messageId: "agent-1", kind: .agent) == 1)
        #expect(transcript.messageIndex(messageId: "thought-1", kind: .thought) == 2)
        #expect(transcript.messageIndex(messageId: "user-1", kind: .user) == 3)
        #expect(transcript.toolCallIndex(toolCallId: "tool-1") == 4)
    }

    @Test("append and same-identity replacement update indices without rebuilding")
    func productionMutationsStayIncremental() {
        let transcript = ACPTranscript()
        let rebuildCount = transcript.messageIndexCacheRebuildCountForTests
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "tool-1",
            title: "Read",
            status: "in_progress",
            content: "",
            preview: "",
            locations: []
        )

        transcript.appendMessage(.agent(
            id: UUID(),
            messageId: "agent-1",
            StreamingText("first")
        ))
        transcript.replaceMessage(at: 0, with: .agent(
            id: UUID(),
            messageId: "agent-1",
            StreamingText("updated")
        ))
        transcript.appendMessage(.toolCall(toolCall))
        toolCall.content = "updated"
        transcript.replaceMessage(at: 1, with: .toolCall(toolCall))

        #expect(transcript.messageIndex(messageId: "agent-1", kind: .agent) == 0)
        #expect(transcript.toolCallIndex(toolCallId: "tool-1") == 1)
        #expect(transcript.messageIndexCacheRebuildCountForTests == rebuildCount)
    }

    @Test("streamed chunks reuse the cached message index")
    func streamedChunksReuseIndex() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        for chunk in 0..<100 {
            session.apply(.agentMessageChunk(.init(
                messageId: "agent-1",
                content: .text("\(chunk) ")
            )))
        }

        #expect(session.transcript.messages.count == 1)
        #expect(session.transcript.messageIndex(messageId: "agent-1", kind: .agent) == 0)
        #expect(session.transcript.messageIndexCacheRebuildCountForTests == 0)
    }

    @Test("prepending shifts cached indices")
    func prependRebuildsShiftedIndices() {
        let transcript = ACPTranscript()
        transcript.appendMessage(.agent(
            id: UUID(),
            messageId: "agent-1",
            StreamingText("answer")
        ))
        let rebuildCount = transcript.messageIndexCacheRebuildCountForTests

        transcript.prependMessages([
            .user(id: UUID(), messageId: "user-1", text: "prompt", attachments: [])
        ])

        #expect(transcript.messageIndex(messageId: "user-1", kind: .user) == 0)
        #expect(transcript.messageIndex(messageId: "agent-1", kind: .agent) == 1)
        #expect(transcript.messageIndexCacheRebuildCountForTests == rebuildCount + 1)
    }
}
