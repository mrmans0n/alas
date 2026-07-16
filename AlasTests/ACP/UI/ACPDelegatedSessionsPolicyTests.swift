import Testing
@testable import Alas

@Suite("Delegated ACP session status labels")
struct ACPDelegatedSessionsPolicyTests {
    @Test("renders public creating-worktree state")
    func creatingWorktreeState() {
        #expect(ACPDelegatedSessionsPolicy.statusLabel(for: "creating_worktree") == "Creating worktree")
    }
}
