import Testing
@testable import Alas

@Suite("Delegated ACP session status labels")
struct ACPDelegatedSessionsPolicyTests {
    @Test("renders public creating-worktree state")
    func creatingWorktreeState() {
        #expect(ACPDelegatedSessionsPolicy.statusLabel(for: "creating_worktree") == "Creating worktree")
    }

    @Test("a session_new call's task is its prompt, on one line", arguments: [
        (#"{"agent":"codex","prompt":"  Review\nthe diff  "}"#, "Review the diff"),
        (#"{"prompt":"   "}"#, nil),
        ("alas session new hi", nil),
        (nil, nil),
    ] as [(String?, String?)])
    func taskFromRawInput(rawInput: String?, task: String?) {
        #expect(ACPDelegatedSessionsPolicy.task(fromRawInput: rawInput) == task)
    }
}
