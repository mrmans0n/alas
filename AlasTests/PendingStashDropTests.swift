import Testing
@testable import Alas

struct PendingStashDropTests {
    @Test func alertCopyUsesStashRefAndSubject() {
        let stash = GitStash(ref: "stash@{0}", subject: "parser cleanup", relativeTime: "2 hours ago", sha: "abc")
        let pending = PendingStashDrop(stash: stash)

        #expect(PendingStashDrop.alertTitle(for: pending) == "Drop stash@{0}?")
        #expect(PendingStashDrop.alertMessage(for: pending) == "This permanently deletes \"parser cleanup\" from the stash list. This cannot be undone.")
    }
}
