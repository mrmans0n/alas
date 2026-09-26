import Testing
@testable import Alas

@Suite("ACP delegated outcome text")
struct ACPDelegatedOutcomeTextTests {
    private let context = ACPDelegatedOutcomeText.Context(
        childSessionId: "child-1", agentId: "codex", worktreeName: "feature-x"
    )

    @Test("unreported completion names the child and quotes its last message")
    func unreportedWithText() {
        let text = ACPDelegatedOutcomeText.unreported(context, lastAgentText: "Parser fixed.")
        #expect(text.hasPrefix("[alas system] Delegated session child-1 (codex, worktree feature-x) finished its turn without sending a result."))
        #expect(text.contains("Last message from the child:\nParser fixed."))
        #expect(text.hasSuffix("Use session_send to follow up with it, or session_list to inspect its state."))
        #expect(!text.lowercased().contains("acknowledge"))
    }

    @Test("unreported completion without agent text omits the quote block")
    func unreportedWithoutText() {
        let text = ACPDelegatedOutcomeText.unreported(context, lastAgentText: nil)
        #expect(!text.contains("Last message from the child"))
        #expect(text.contains("finished its turn without sending a result."))
    }

    @Test("omits the worktree clause when the name is unknown")
    func noWorktreeName() {
        let bare = ACPDelegatedOutcomeText.Context(childSessionId: "c", agentId: "claude", worktreeName: nil)
        #expect(ACPDelegatedOutcomeText.notice(bare) == "Delegated session c (claude) finished its turn.")
    }

    @Test("failure text carries the failure message")
    func failure() {
        #expect(ACPDelegatedOutcomeText.failure(context, message: "Agent is not enabled")
            == "[alas system] Delegated session child-1 (codex, worktree feature-x) failed: Agent is not enabled.")
    }

    @Test("tail keeps the last characters and marks truncation")
    func tailTruncates() {
        let long = String(repeating: "a", count: 10) + "END"
        #expect(ACPDelegatedOutcomeText.tail(long, limit: 5) == "…" + "aaEND")
        #expect(ACPDelegatedOutcomeText.tail("short", limit: 5) == "short")
        #expect(ACPDelegatedOutcomeText.tail("  padded \n", limit: 50) == "padded")
    }

    @Test("escalated blocker copy states the parent cannot approve")
    func escalatedBlockerCopy() {
        let text = ACPDelegatedOutcomeText.blocker(
            context, kindLabel: "permission", waitedSeconds: 30, escalated: true
        )
        #expect(text.hasPrefix("[alas system] Delegated session child-1 (codex, worktree feature-x)"))
        #expect(text.contains("30s"))
        #expect(text.contains("cannot approve"))
        #expect(text.contains("notify"))
        #expect(text.contains("session_send"))
    }

    @Test("non-escalated blocker copy is a plain notice")
    func nonEscalatedBlockerCopy() {
        let text = ACPDelegatedOutcomeText.blocker(
            context, kindLabel: "question", waitedSeconds: 0, escalated: false
        )
        #expect(!text.hasPrefix("[alas system]"))
        #expect(text.contains("waiting for a human decision"))
        #expect(!text.lowercased().contains("acknowledge"))
    }
}
