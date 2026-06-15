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
}
