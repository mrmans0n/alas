import Foundation
import Testing
@testable import Alas

@MainActor
struct TabsManagerReviewSessionTests {
    @Test func opensOrFocusesReviewSessionForSameTarget() {
        var manager = TabsManager()
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )

        let first = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: record)
        let second = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: record)

        #expect(first.id == second.id)
        #expect(manager.tabs(forWorktree: "wt-1").filter {
            if case .reviewSession = $0 { return true }
            return false
        }.count == 1)
    }

    @Test func updatesReviewSessionSelection() {
        var manager = TabsManager()
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc",
            title: "Review abc"
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )
        let tab = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: record)

        _ = manager.updateReviewSession(worktreeId: "wt-1", tabId: tab.id) { state in
            state.selectedFileID = DiffReviewFileID(namespace: "commit", path: "A.swift")
        }

        guard case .reviewSession(let state)? = manager.tabs(forWorktree: "wt-1").first(where: { $0.id == tab.id }) else {
            Issue.record("Missing review session tab")
            return
        }
        #expect(state.selectedFileID == DiffReviewFileID(namespace: "commit", path: "A.swift"))
    }

    @Test func retargetingReviewSessionCoalescesExistingDestinationTab() throws {
        var manager = TabsManager()
        let repositoryPath = URL(fileURLWithPath: "/repo")
        let fixedTarget = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            sha: "old",
            title: "Review old"
        )
        let tracked = try #require(TrackedRevision(
            expression: "HEAD~2", baselineBranch: "feature", resolvedSHA: "new"
        ))
        let trackedTarget = ReviewSessionTarget.trackedCommit(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            revision: tracked,
            title: "Review HEAD~2"
        )
        let existing = manager.openOrFocusReviewSession(
            worktreeId: "wt-1",
            record: ReviewSessionRecord(
                id: trackedTarget.id,
                target: trackedTarget,
                status: .reviewed,
                createdAt: .init(timeIntervalSince1970: 1),
                updatedAt: .init(timeIntervalSince1970: 2)
            )
        )
        let source = manager.openOrFocusReviewSession(
            worktreeId: "wt-1",
            record: ReviewSessionRecord(
                id: fixedTarget.id,
                target: fixedTarget,
                createdAt: .init(timeIntervalSince1970: 3),
                updatedAt: .init(timeIntervalSince1970: 4)
            )
        )

        let result = manager.updateReviewSession(worktreeId: "wt-1", tabId: source.id) { state in
            state.retarget(to: ReviewSessionRecord(
                id: trackedTarget.id,
                target: trackedTarget,
                createdAt: .init(timeIntervalSince1970: 3),
                updatedAt: .init(timeIntervalSince1970: 5)
            ))
        }

        #expect(result?.id == existing.id)
        #expect(manager.tabs(forWorktree: "wt-1").map(\.id) == [existing.id])
        #expect(manager.activeTabId(forWorktree: "wt-1") == existing.id)
    }
}
