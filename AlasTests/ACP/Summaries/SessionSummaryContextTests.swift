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

    @Test func keepsTheMaximalFittingSuffixInChronologicalOrder() throws {
        let first = SessionSummaryTurn(
            user: "first-" + String(repeating: "a", count: 71_000),
            assistant: "first answer"
        )
        let second = SessionSummaryTurn(
            user: "second-" + String(repeating: "b", count: 60_000),
            assistant: "second answer"
        )
        let third = SessionSummaryTurn(user: "third", assistant: "third answer")
        let fourth = SessionSummaryTurn(user: "fourth", assistant: "fourth answer")
        let allTurns = [first, second, third, fourth]
        let session = makeSession(messages: allTurns.flatMap {
            [
                .user(id: UUID(), messageId: nil, text: $0.user, attachments: []),
                .agent(id: UUID(), messageId: nil, StreamingText($0.assistant))
            ]
        })

        let context = try #require(SessionSummaryContext.snapshot(session: session))
        #expect(context.turns == [second, third, fourth])
        #expect(context.omittedOlderTurns)
        let selectedInput = try #require(context.messageCandidates().first?[1].content)
        #expect(selectedInput.utf8.count <= SessionSummaryContext.sourceLimit)

        let expanded = SessionSummaryContext(
            revision: context.revision,
            goal: context.goal,
            plan: context.plan,
            turns: allTurns,
            omittedOlderTurns: false
        )
        let expandedInput = try #require(expanded.messageCandidates().first?[1].content)
        #expect(expandedInput.utf8.count > SessionSummaryContext.sourceLimit)
        let secondRange = try #require(selectedInput.range(of: "second-"))
        let thirdRange = try #require(selectedInput.range(of: "third"))
        let fourthRange = try #require(selectedInput.range(of: "fourth"))
        #expect(secondRange.lowerBound < thirdRange.lowerBound)
        #expect(thirdRange.lowerBound < fourthRange.lowerBound)
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
        let revision = try #require(context.revision)
        #expect(revision.goal == context.goal)
        #expect(revision.plan == context.plan)
        #expect(revision.transcriptGeneration == session.transcript.messagesGeneration)
    }

    @Test func boundsRenderedCandidateCountForLongSessions() throws {
        let turns = (0..<256).map {
            SessionSummaryTurn(user: "user \($0)", assistant: "assistant \($0)")
        }
        let session = makeSession(messages: turns.flatMap {
            [
                .user(id: UUID(), messageId: nil, text: $0.user, attachments: []),
                .agent(id: UUID(), messageId: nil, StreamingText($0.assistant))
            ]
        })

        let context = try #require(SessionSummaryContext.snapshot(session: session))

        #expect(context.messageCandidates().count <= 10)
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
        #expect(!SessionSummaryContext.hasCompleteTurn(session: incomplete))

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
        #expect(SessionSummaryContext.hasCompleteTurn(session: oversized))
    }

    @Test func currentIdleFactsReadTheSeparateComposerWithoutBuildingContext() {
        let session = makeSession(messages: [])
        session.agentState = .ready

        #expect(SessionSummaryContext.snapshot(session: session) == nil)
        #expect(SessionSummaryIdleFacts.current(session: session, composer: session.composer).isIdle)

        session.composer.replaceDraft(.init(segments: [.text("draft")]))

        #expect(!SessionSummaryIdleFacts.current(session: session, composer: session.composer).isIdle)
    }

    @Test func autoRunSessionWithoutTurnIsIdle() {
        let session = makeSession(messages: [])
        session.agentState = .ready
        session.autoRunEnabled = true

        #expect(SessionSummaryIdleFacts.current(session: session, composer: session.composer).isIdle)
    }

    @Test func storedSourceHashesIdenticallyToLiveSession() throws {
        let attachment = ACPMessage.Attachment(uri: "file:///tmp/a", name: "a")
        let delegated = ACPDelegatedPromptSource(sessionId: "parent", messageId: "prompt")
        let planItems = [ACPMessage.PlanItem(content: "Verify parity", status: "in_progress")]
        let session = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: "   ", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("orphan reply")),
            .user(id: UUID(), messageId: nil, text: "First request", attachments: []),
            .thought(id: UUID(), messageId: nil, StreamingText("private reasoning")),
            .toolCall(.init(toolCallId: "tool", title: "Read", status: "completed", content: "tool secret")),
            .agent(id: UUID(), messageId: nil, StreamingText("Part one.")),
            .agent(id: UUID(), messageId: nil, StreamingText("  ")),
            .agent(id: UUID(), messageId: nil, StreamingText("Part two.")),
            .user(id: UUID(), messageId: nil, text: "delegated", attachments: [], delegatedSource: delegated),
            .agent(id: UUID(), messageId: nil, StreamingText("delegated reply")),
            .user(id: UUID(), messageId: nil, text: "attached", attachments: [attachment]),
            .agent(id: UUID(), messageId: nil, StreamingText("attachment reply")),
            .user(id: UUID(), messageId: nil, text: "Second request", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("Second answer")),
            .plan(id: UUID(), planItems)
        ])
        let wires: [ACPMessageWire] = [
            .user(messageId: nil, text: "   ", attachments: [], delegatedSource: nil),
            .agent(messageId: nil, text: "orphan reply", phase: nil, metadata: nil),
            .user(messageId: nil, text: "First request", attachments: [], delegatedSource: nil),
            .thought(messageId: nil, text: "private reasoning", phase: nil, metadata: nil),
            .toolCall(.init(toolCallId: "tool", title: "Read", status: "completed", content: "tool secret")),
            .agent(messageId: nil, text: "Part one.", phase: nil, metadata: nil),
            .agent(messageId: nil, text: "  ", phase: nil, metadata: nil),
            .agent(messageId: nil, text: "Part two.", phase: nil, metadata: nil),
            .user(messageId: nil, text: "delegated", attachments: [], delegatedSource: delegated),
            .agent(messageId: nil, text: "delegated reply", phase: nil, metadata: nil),
            .user(messageId: nil, text: "attached", attachments: [attachment], delegatedSource: nil),
            .agent(messageId: nil, text: "attachment reply", phase: nil, metadata: nil),
            .user(messageId: nil, text: "Second request", attachments: [], delegatedSource: nil),
            .agent(messageId: nil, text: "Second answer", phase: nil, metadata: nil),
            .plan(planItems)
        ]

        let live = try #require(SessionSummaryContext.snapshot(session: session))
        let stored = try #require(SessionSummaryContext.snapshot(source: .init(
            goal: nil,
            plan: SessionSummarySource.currentPlan(in: wires),
            turns: SessionSummarySource.turns(in: wires))))

        #expect(live.turns == [
            .init(user: "First request", assistant: "Part one.\nPart two."),
            .init(user: "Second request", assistant: "Second answer")
        ])
        #expect(stored.revision == nil)
        #expect(live.inputHash(modelID: "m") == stored.inputHash(modelID: "m"))
        #expect(live.inputHash(modelID: "m") != live.inputHash(modelID: "other"))
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
