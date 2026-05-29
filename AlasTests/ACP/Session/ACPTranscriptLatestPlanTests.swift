import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscript.latestPlan")
struct ACPTranscriptLatestPlanTests {
    private typealias Item = ACPMessage.PlanItem

    private func makeSession() -> ACPSession {
        ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "t")
    }

    @Test("nil when no plan has ever arrived")
    func nilWhenNoPlan() {
        let session = makeSession()
        session.transcript.messages = [.user(id: UUID(), text: "hi", attachments: [])]
        #expect(session.transcript.latestPlan == nil)
    }

    @Test("returns the most recent plan in the current turn")
    func returnsCurrentTurnPlan() {
        let items: [Item] = [.init(content: "Read", status: "in_progress")]
        let session = makeSession()
        session.transcript.messages = [
            .user(id: UUID(), text: "hi", attachments: []),
            .plan(id: UUID(), items)
        ]
        #expect(session.transcript.latestPlan == items)
    }

    @Test("survives a new user prompt after a plan (unlike currentPlan)")
    func survivesNewUserPrompt() {
        let oldItems: [Item] = [.init(content: "Done step", status: "completed")]
        let session = makeSession()
        session.transcript.messages = [
            .user(id: UUID(), text: "first", attachments: []),
            .plan(id: UUID(), oldItems),
            .user(id: UUID(), text: "second", attachments: [])
        ]
        #expect(session.transcript.currentPlan == nil)     // turn-scoped, unchanged
        #expect(session.transcript.latestPlan == oldItems) // turn-stable
    }

    @Test("returns the latest plan when multiple plans exist across turns")
    func returnsLatestAcrossTurns() {
        let oldItems: [Item] = [.init(content: "Old", status: "completed")]
        let newItems: [Item] = [.init(content: "New", status: "in_progress")]
        let session = makeSession()
        session.transcript.messages = [
            .user(id: UUID(), text: "first", attachments: []),
            .plan(id: UUID(), oldItems),
            .user(id: UUID(), text: "second", attachments: []),
            .plan(id: UUID(), newItems)
        ]
        #expect(session.transcript.latestPlan == newItems)
    }

    @Test("returns nil when latest plan items are empty")
    func nilForEmptyLatest() {
        let session = makeSession()
        session.transcript.messages = [
            .user(id: UUID(), text: "hi", attachments: []),
            .plan(id: UUID(), [])
        ]
        #expect(session.transcript.latestPlan == nil)
    }
}
