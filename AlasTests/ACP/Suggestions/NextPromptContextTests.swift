import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("NextPromptContext")
struct NextPromptContextTests {
    private func session(_ messages: [ACPMessage]) -> ACPSession {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = messages
        return session
    }

    @Test func snapshotKeepsOnlyCompleteTypedTurnsThroughOwningUser() {
        let oldID = UUID(), latestID = UUID()
        let huge = String(repeating: "x", count: 2_000_000)
        let rows: [ACPMessage] = [
            .systemNotice(id: UUID(), text: huge),
            .user(id: oldID, text: "First request", attachments: []),
            .thought(id: UUID(), StreamingText(huge)),
            .agent(id: UUID(), StreamingText("First answer")),
            .toolCall(.init(toolCallId: "tool", title: "Run", status: "completed", content: huge)),
            .user(id: latestID, text: "Latest request", attachments: []),
            .agent(id: UUID(), StreamingText("Latest answer")),
            .systemNotice(id: UUID(), text: "status")
        ]
        #expect(NextPromptContext.snapshot(session: session(rows), completedUserID: latestID) == [
            .init(user: "First request", assistant: "First answer"),
            .init(user: "Latest request", assistant: "Latest answer")
        ])
    }

    @Test func snapshotRejectsMissingOrIncompleteLatestTurn() {
        let id = UUID()
        #expect(NextPromptContext.snapshot(session: session([
            .user(id: id, text: "Question", attachments: []),
            .thought(id: UUID(), StreamingText("Thinking"))
        ]), completedUserID: id) == nil)
        #expect(NextPromptContext.snapshot(session: session([
            .user(id: id, text: "Question", attachments: []),
            .agent(id: UUID(), StreamingText("Answer")),
            .user(id: UUID(), text: "Later request", attachments: [])
        ]), completedUserID: id) == nil)
    }

    @Test func snapshotRejectsAttachmentDependentAndDelegatedLatestTurns() {
        let id = UUID()
        let attachment = ACPMessage.Attachment(uri: "file:///secret.txt", name: "secret.txt")
        let answer = ACPMessage.agent(id: UUID(), StreamingText("Done"))
        #expect(NextPromptContext.snapshot(session: session([
            .user(id: id, text: "Inspect this", attachments: [attachment]), answer
        ]), completedUserID: id) == nil)
        #expect(NextPromptContext.snapshot(session: session([
            .user(id: id, messageId: nil, text: "Delegated", attachments: [],
                  delegatedSource: .init(sessionId: "parent", messageId: "row")), answer
        ]), completedUserID: id) == nil)
    }

    @Test func checkpointReferenceDoesNotSuppressTextOnlyTurn() {
        let id = UUID()
        let rows: [ACPMessage] = [
            .user(id: id, text: "Explain the result", attachments: [.checkpointReference(id: UUID())]),
            .agent(id: UUID(), StreamingText("Here is the explanation."))
        ]
        #expect(NextPromptContext.snapshot(session: session(rows), completedUserID: id) == [
            .init(user: "Explain the result", assistant: "Here is the explanation.")
        ])
    }

    @Test func latestOverflowAbstainsAndOlderOverflowDropsWholeTurn() {
        let id = UUID()
        let oversized = String(repeating: "a", count: 131_072)
        #expect(NextPromptContext.snapshot(session: session([
            .user(id: id, text: oversized, attachments: []),
            .agent(id: UUID(), StreamingText("answer"))
        ]), completedUserID: id) == nil)

        let oldID = UUID(), old = String(repeating: "b", count: 131_060)
        let rows: [ACPMessage] = [
            .user(id: oldID, text: old, attachments: []),
            .agent(id: UUID(), StreamingText("old answer")),
            .user(id: id, text: "new", attachments: []),
            .agent(id: UUID(), StreamingText("new answer"))
        ]
        #expect(NextPromptContext.snapshot(session: session(rows), completedUserID: id) == [
            .init(user: "new", assistant: "new answer")
        ])
    }

    @Test func separatorBetweenAgentRowsCountsAgainstSourceCap() {
        let id = UUID()
        let rows: [ACPMessage] = [
            .user(id: id, text: "u", attachments: []),
            .agent(id: UUID(), StreamingText(String(repeating: "a", count: 65_535))),
            .agent(id: UUID(), StreamingText(String(repeating: "b", count: 65_536)))
        ]
        #expect(NextPromptContext.snapshot(session: session(rows), completedUserID: id) == nil)
    }

    @Test func tokenizerSelectionIncludesPolicyAndNeverSlicesTurns() {
        let turns = [
            NextPromptTurn(user: "old 😀", assistant: "old result"),
            NextPromptTurn(user: "new", assistant: "latest result")
        ]
        var counted: [[NextPromptChatMessage]] = []
        let selected = NextPromptContext.fit(turns, tokenLimit: 10) { messages in
            counted.append(messages)
            return messages.last?.content.contains("old 😀") == true ? 11 : 10
        }
        #expect(selected == [turns[1]])
        #expect(counted.allSatisfy { $0.first?.role == .system && $0.first?.content == NextPromptPolicy.systemPrompt })
        #expect(NextPromptContext.fit(turns, tokenLimit: 9) { _ in 10 } == nil)
    }
}
