import Foundation
import Testing
@testable import Alas

@MainActor
struct TabsManagerReviewSessionTests {
    @Test func opensOrFocusesReviewSessionForSameTarget() {
        let manager = TabsManager()
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
        let manager = TabsManager()
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

    @Test func openOrFocusReviewSessionRefreshesExistingDestinationState() {
        let manager = TabsManager()
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc",
            title: "Review abc"
        )
        let initial = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )
        _ = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: initial)

        var merged = initial
        merged.selectedFileID = DiffReviewFileID(namespace: "commit", path: "Merged.swift")
        merged.focusedCommentID = "comment-1"
        let refreshed = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: merged)

        guard case .reviewSession(let state) = refreshed else {
            Issue.record("Expected review session tab")
            return
        }
        #expect(state.selectedFileID == DiffReviewFileID(namespace: "commit", path: "Merged.swift"))
        #expect(state.focusedCommentID == "comment-1")
        #expect(manager.tabs(forWorktree: "wt-1").count == 1)
    }

    @Test func reviewSessionViewIDSurvivesRetargeting() throws {
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
        var state = ReviewSessionTabState(
            worktreeId: "wt-1",
            record: ReviewSessionRecord(
                id: fixedTarget.id,
                target: fixedTarget,
                createdAt: .init(timeIntervalSince1970: 1),
                updatedAt: .init(timeIntervalSince1970: 1)
            )
        )
        let viewID = state.viewID

        state.retarget(to: ReviewSessionRecord(
            id: trackedTarget.id,
            target: trackedTarget,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 2)
        ))

        #expect(state.id != viewID)
        #expect(state.viewID == viewID)
    }

    @Test func legacyReviewSessionTabDecodeUsesIDAsViewID() throws {
        let json = """
        {
          "id": "review-session:old",
          "worktreeId": "wt-1",
          "sessionID": "old",
          "title": "Review old"
        }
        """

        let state = try JSONDecoder().decode(ReviewSessionTabState.self, from: Data(json.utf8))

        #expect(state.id == "review-session:old")
        #expect(state.viewID == "review-session:old")
        #expect(state.sessionID == ReviewSessionID(rawValue: "old"))
    }

    @Test func retargetingReviewSessionCoalescesExistingDestinationTab() throws {
        let manager = TabsManager()
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

    @Test func reviewingCommitReplacesItsTabInPlaceAndSeedsTheLoadedDiffOnce() {
        let manager = TabsManager()
        let commit = manager.appendCommit(worktreeId: "wt-1", sha: "abc", title: "Fix parser")
        let neighbor = manager.appendCommit(worktreeId: "wt-1", sha: "def", title: "Other")
        let record = Self.commitRecord(sha: "abc")
        let selected = DiffReviewFileID(namespace: "commit", path: "A.swift")
        let seed = ReviewSessionSeed(
            target: record.target,
            session: DiffReviewLoadedSession(files: [], summary: DiffReviewSessionModel(files: [], groupsEnabled: false)),
            selectedFileID: selected
        )

        let review = manager.replaceCommitWithReviewSession(
            worktreeId: "wt-1", commitTabId: commit.id, record: record, seed: seed
        )

        #expect(manager.tabs(forWorktree: "wt-1").map(\.id) == [review.id, neighbor.id])
        #expect(manager.activeTabId(forWorktree: "wt-1") == review.id)
        #expect(manager.takeReviewSessionSeed(sessionID: record.id, target: record.target)?.selectedFileID == selected)
        #expect(manager.takeReviewSessionSeed(sessionID: record.id, target: record.target) == nil)
    }

    @Test func reviewingCommitWithOpenReviewFocusesItAndDropsTheCommitTab() {
        let manager = TabsManager()
        let record = Self.commitRecord(sha: "abc")
        let existing = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: record)
        let commit = manager.appendCommit(worktreeId: "wt-1", sha: "abc", title: "Fix parser")

        let review = manager.replaceCommitWithReviewSession(
            worktreeId: "wt-1", commitTabId: commit.id, record: record, seed: nil
        )

        #expect(review.id == existing.id)
        #expect(manager.tabs(forWorktree: "wt-1").map(\.id) == [existing.id])
        #expect(manager.activeTabId(forWorktree: "wt-1") == existing.id)
    }

    private static func commitRecord(sha: String) -> ReviewSessionRecord {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: sha,
            title: "Review \(sha)"
        )
        return ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )
    }
}
