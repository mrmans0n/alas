import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscript.currentPlan")
struct ACPTranscriptCurrentPlanTests {
    private func makeSession() -> ACPSession {
        ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "t")
    }

    @Test("returns nil when no plan message has arrived")
    func nilWhenNoPlan() {
        let session = makeSession()
        session.transcript.messages = [
            .agent(id: UUID(), StreamingText("hi")),
            .user(id: UUID(), text: "hello", attachments: [])
        ]
        #expect(session.transcript.currentPlan == nil)
    }

    @Test("returns the items of the current turn's latest plan message")
    func currentTurnLatestPlanItems() {
        let session = makeSession()
        let firstItems = [ACPMessage.PlanItem(content: "a", status: "completed")]
        let secondItems = [
            ACPMessage.PlanItem(content: "x", status: "completed"),
            ACPMessage.PlanItem(content: "y", status: "in_progress")
        ]
        session.transcript.messages = [
            .plan(id: UUID(), firstItems),
            .agent(id: UUID(), StreamingText("between")),
            .plan(id: UUID(), secondItems),
            .agent(id: UUID(), StreamingText("after"))
        ]
        #expect(session.transcript.currentPlan == secondItems)
    }

    @Test("returns empty array for an empty plan items array")
    func emptyPlanItems() {
        let session = makeSession()
        session.transcript.messages = [.plan(id: UUID(), [])]
        #expect(session.transcript.currentPlan == [])
    }

    @Test("returns nil after a new user prompt follows the previous plan")
    func nilAfterNewUserPromptFollowsPlan() {
        let session = makeSession()
        let previousTurnItems = [
            ACPMessage.PlanItem(content: "old step", status: "completed")
        ]
        session.transcript.messages = [
            .user(id: UUID(), text: "first prompt", attachments: []),
            .plan(id: UUID(), previousTurnItems),
            .agent(id: UUID(), StreamingText("done with turn 1")),
            .user(id: UUID(), text: "second prompt", attachments: [])
        ]
        // The previous turn's plan must not leak into the new turn.
        #expect(session.transcript.currentPlan == nil)
    }

    @Test("returns the current turn's plan when it sits after the latest user prompt")
    func returnsCurrentTurnPlan() {
        let session = makeSession()
        let previousTurnItems = [ACPMessage.PlanItem(content: "old", status: "completed")]
        let currentTurnItems = [ACPMessage.PlanItem(content: "new", status: "in_progress")]
        session.transcript.messages = [
            .user(id: UUID(), text: "first", attachments: []),
            .plan(id: UUID(), previousTurnItems),
            .user(id: UUID(), text: "second", attachments: []),
            .plan(id: UUID(), currentTurnItems)
        ]
        #expect(session.transcript.currentPlan == currentTurnItems)
    }

    @Test("apply(.plan) appends a fresh plan when the previous one belongs to an earlier turn")
    func applyAppendsAfterNewUserPrompt() {
        let session = makeSession()
        let previousTurnItems = [ACPMessage.PlanItem(content: "old", status: "completed")]
        session.transcript.messages = [
            .user(id: UUID(), text: "first", attachments: []),
            .plan(id: UUID(), previousTurnItems),
            .user(id: UUID(), text: "second", attachments: [])
        ]
        let newEntries = [ACPPlanEntry(content: "new", priority: nil, status: "in_progress")]
        session.apply(.plan(newEntries))
        // Previous turn's plan stays at index 1; the new one is appended.
        #expect(session.transcript.messages.count == 4)
        if case .plan(_, let firstItems) = session.transcript.messages[1] {
            #expect(firstItems == previousTurnItems)
        } else {
            Issue.record("expected previous turn's plan at index 1")
        }
        if case .plan(_, let latestItems) = session.transcript.messages.last {
            #expect(latestItems == [ACPMessage.PlanItem(content: "new", status: "in_progress")])
        } else {
            Issue.record("expected new plan appended at end")
        }
        #expect(session.transcript.currentPlan == [ACPMessage.PlanItem(content: "new", status: "in_progress")])
    }

    @Test("apply(.plan) overwrites in place while the current turn's plan progresses")
    func applyOverwritesWithinSameTurn() {
        let session = makeSession()
        let planId = UUID()
        session.transcript.messages = [
            .user(id: UUID(), text: "go", attachments: []),
            .plan(id: planId, [ACPMessage.PlanItem(content: "step", status: "pending")])
        ]
        let progress = [ACPPlanEntry(content: "step", priority: nil, status: "in_progress")]
        session.apply(.plan(progress))
        // No new user prompt → same plan slot updates in place, id preserved.
        #expect(session.transcript.messages.count == 2)
        if case .plan(let id, let items) = session.transcript.messages[1] {
            #expect(id == planId)
            #expect(items == [ACPMessage.PlanItem(content: "step", status: "in_progress")])
        } else {
            Issue.record("expected plan message at index 1")
        }
        #expect(session.transcript.currentPlan == [ACPMessage.PlanItem(content: "step", status: "in_progress")])
    }

    @Test("production tool-call updates do not rebuild plan caches")
    func toolCallUpdatesDoNotRebuildPlanCaches() {
        let transcript = ACPTranscript()
        let planItems = [ACPMessage.PlanItem(content: "step", status: "in_progress")]
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "tool",
            title: "Read",
            status: "in_progress",
            content: "",
            preview: "",
            locations: []
        )
        transcript.replaceMessages(with: [
            .user(id: UUID(), text: "go", attachments: []),
            .plan(id: UUID(), planItems),
            .toolCall(toolCall)
        ])
        let rebuildCount = transcript.planCacheRebuildCountForTests

        for update in 0..<100 {
            toolCall.content = "update \(update)"
            transcript.replaceMessage(at: 2, with: .toolCall(toolCall))
        }

        let updatedPlanItems = [ACPMessage.PlanItem(content: "step", status: "completed")]
        transcript.replaceMessage(at: 1, with: .plan(id: UUID(), updatedPlanItems))

        #expect(transcript.planCacheRebuildCountForTests == rebuildCount)
        #expect(transcript.currentPlan == updatedPlanItems)
    }
}
