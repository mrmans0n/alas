import Foundation
import Testing
@testable import Alas

@MainActor
@Suite struct SessionSummaryContextTests {
    @Test func includesOnlyCompleteOrdinaryTurns() throws {
        let session = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: "Implement search", attachments: []),
            .thought(id: UUID(), messageId: nil, StreamingText("private reasoning")),
            .systemNotice(id: UUID(), text: "private notice"),
            .agent(id: UUID(), messageId: nil, StreamingText("Search now works.")),
            .user(id: UUID(), messageId: nil, text: "Newest incomplete turn", attachments: [])
        ])

        let context = try #require(SessionSummaryContext.snapshot(session: session))
        #expect(context.turns == [.init(user: "Implement search", assistant: "Search now works.")])
        let rendered = renderedText(context)
        #expect(!rendered.contains("private reasoning"))
        #expect(!rendered.contains("private notice"))
        #expect(!rendered.contains("Newest incomplete turn"))
    }

    @Test func excludesDelegatedPromptsAttachmentsToolsEditsAndNotices() throws {
        let session = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: "Ordinary request", attachments: []),
            .toolCall(.init(toolCallId: "tool", title: "Read", status: "completed", content: "tool secret")),
            .fileEdit(id: UUID(), .init(path: "hidden.swift", added: 1, removed: 0, newText: "edit secret")),
            .systemNotice(id: UUID(), text: "notice secret"),
            .agent(id: UUID(), messageId: nil, StreamingText("Ordinary answer")),
            .user(
                id: UUID(), messageId: nil, text: "delegated secret", attachments: [],
                delegatedSource: .init(sessionId: "parent", messageId: "prompt")
            ),
            .agent(id: UUID(), messageId: nil, StreamingText("delegated answer secret")),
            .user(
                id: UUID(), messageId: nil, text: "attachment secret",
                attachments: [.init(uri: "file:///tmp/a", name: "a")]
            ),
            .agent(id: UUID(), messageId: nil, StreamingText("attachment answer secret")),
            .user(id: UUID(), messageId: nil, text: "Newest request", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("Newest answer"))
        ])

        let context = try #require(SessionSummaryContext.snapshot(session: session))
        #expect(context.turns == [
            .init(user: "Ordinary request", assistant: "Ordinary answer"),
            .init(user: "Newest request", assistant: "Newest answer")
        ])
        let rendered = renderedText(context)
        for excluded in ["tool secret", "edit secret", "notice secret", "delegated secret", "attachment secret"] {
            #expect(!rendered.contains(excluded))
        }
    }

    @Test func keepsWholeNewestTurnsUnderSourceLimit() throws {
        let olderUser = "old-user-" + String(repeating: "u", count: 70_000)
        let olderAssistant = "old-assistant-" + String(repeating: "a", count: 70_000)
        let session = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: olderUser, attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText(olderAssistant)),
            .user(id: UUID(), messageId: nil, text: "new user", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("new assistant"))
        ])

        let context = try #require(SessionSummaryContext.snapshot(session: session))
        #expect(context.turns == [.init(user: "new user", assistant: "new assistant")])
        #expect(context.omittedOlderTurns)
        #expect(!renderedText(context).contains("old-user-"))
    }

    @Test func preservesChronologicalOrderAfterDroppingOlderTurns() throws {
        let session = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: String(repeating: "old", count: 44_000), attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("old answer")),
            .user(id: UUID(), messageId: nil, text: "middle user", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("middle answer")),
            .user(id: UUID(), messageId: nil, text: "newest user", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("newest answer"))
        ])

        let context = try #require(SessionSummaryContext.snapshot(session: session))
        #expect(context.turns.map(\.user) == ["middle user", "newest user"])
        let rendered = renderedText(context)
        let middle = try #require(rendered.range(of: "middle user"))
        let newest = try #require(rendered.range(of: "newest user"))
        #expect(middle.lowerBound < newest.lowerBound)
    }

    @Test func keepsGoalPlanAndNewestTurnInEveryCandidate() throws {
        let session = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: "first", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("first answer")),
            .user(id: UUID(), messageId: nil, text: "second", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("second answer")),
            .user(id: UUID(), messageId: nil, text: "newest", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("newest answer"))
        ])
        session.currentGoal = .init(objective: "Ship summaries", status: "active", tokenBudget: 2_000)
        session.transcript.appendMessage(.plan(id: UUID(), [
            .init(content: "Keep context bounded", status: "in_progress")
        ]))

        let context = try #require(SessionSummaryContext.snapshot(session: session))
        let candidates = context.messageCandidates()
        #expect(candidates.count == 3)
        for candidate in candidates {
            let rendered = candidate.map(\.content).joined()
            #expect(rendered.contains("Ship summaries"))
            #expect(rendered.contains("Keep context bounded"))
            #expect(rendered.contains("newest"))
            #expect(rendered.contains("newest answer"))
        }
        #expect(context.revision.goal == context.goal)
        #expect(context.revision.plan == context.plan)
        #expect(context.revision.transcriptGeneration == session.transcript.messagesGeneration)
    }

    @Test func marksPartialWhenSourceLimitDropsOlderTurns() throws {
        let session = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: String(repeating: "x", count: 131_000), attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("old answer")),
            .user(id: UUID(), messageId: nil, text: "latest", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("latest answer"))
        ])

        let context = try #require(SessionSummaryContext.snapshot(session: session))
        #expect(context.omittedOlderTurns)
        #expect(context.turns == [.init(user: "latest", assistant: "latest answer")])
    }

    @Test func returnsNilWhenNoCompleteTurnOrDeterministicContextFits() {
        let incomplete = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: "no answer", attachments: [])
        ])
        #expect(SessionSummaryContext.snapshot(session: incomplete) == nil)

        let oversized = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: "user", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("answer"))
        ])
        oversized.currentGoal = .init(
            objective: String(repeating: "g", count: SessionSummaryContext.sourceLimit),
            status: nil,
            tokenBudget: nil
        )
        #expect(SessionSummaryContext.snapshot(session: oversized) == nil)
    }

    private func makeSession(messages: [ACPMessage]) -> ACPSession {
        let session = ACPSession(id: "summary-test", agentId: "codex", worktreeId: "worktree", title: "Test")
        for message in messages { session.transcript.appendMessage(message) }
        return session
    }

    private func renderedText(_ context: SessionSummaryContext) -> String {
        context.messageCandidates().flatMap { $0 }.map(\.content).joined()
    }
}
