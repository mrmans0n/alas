import Testing
import Foundation
@testable import Alas

@MainActor
struct PendingStashDropTests {
    @Test func alertCopyUsesStashRefAndSubject() {
        let stash = GitStash(ref: "stash@{0}", subject: "parser cleanup", relativeTime: "2 hours ago", sha: "abc")
        let pending = PendingStashDrop(stash: stash)

        #expect(PendingStashDrop.alertTitle(for: pending) == "Drop stash@{0}?")
        #expect(PendingStashDrop.alertMessage(for: pending) == "This permanently deletes \"parser cleanup\" from the stash list. This cannot be undone.")
    }

    @Test func reconcileStashesClearsCachedFilesWhenRefPointsAtDifferentSha() {
        let state = RightPaneState(
            worktree: Worktree(
                id: "wt",
                projectId: "project",
                name: "main",
                branch: "main",
                path: URL(fileURLWithPath: "/tmp/repo"),
                status: .clean,
                lastActivity: Date()
            ),
            baseBranch: "main"
        )
        state.stashFilesByRef = [
            "stash@{0}": [GitStashFile(path: "old.txt", status: "M", add: 1, del: 0)],
        ]
        state.expandedStashRefs = ["stash@{0}"]
        state.stashes = [
            GitStash(ref: "stash@{0}", subject: "old", relativeTime: "1 minute ago", sha: "old-sha"),
        ]

        state.reconcileStashCaches(with: [
            GitStash(ref: "stash@{0}", subject: "new", relativeTime: "now", sha: "new-sha"),
        ])

        #expect(state.stashFilesByRef.isEmpty)
        #expect(state.expandedStashRefs.isEmpty)
    }
}
