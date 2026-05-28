import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession.currentPlan")
struct ACPSessionCurrentPlanTests {
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
        #expect(session.currentPlan == nil)
    }

    @Test("returns the items of the latest plan message")
    func latestPlanItems() {
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
        #expect(session.currentPlan == secondItems)
    }

    @Test("returns empty array for an empty plan items array")
    func emptyPlanItems() {
        let session = makeSession()
        session.transcript.messages = [.plan(id: UUID(), [])]
        #expect(session.currentPlan == [])
    }
}
