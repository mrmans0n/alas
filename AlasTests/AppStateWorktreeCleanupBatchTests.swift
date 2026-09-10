import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateWorktreeCleanupBatchTests {
    @Test func mainWorktreeIsSkippedAndNeverDeleted() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        let main = fixture.worktrees[0]   // fixture marks index 0 as main

        let results = await fixture.state.batchDeleteWorktrees(
            [main],
            keepBranch: false
        )

        #expect(results.count == 1)
        #expect(results[0].outcome == .skipped(reason: "Main worktree"))
        #expect(fixture.state.projectsManager
            .worktrees(projectId: fixture.project.id)
            .contains { $0.id == main.id })
    }

    @Test func oneFailingItemDoesNotAbortTheBatch() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 3)
        let targets = Array(fixture.worktrees.dropFirst())   // skip main

        // Remove the second target's directory out from under git so its
        // removal fails while its siblings succeed.
        try FileManager.default.removeItem(at: targets[0].path)
        try Process.corruptWorktreeRegistration(targets[0])

        let results = await fixture.state.batchDeleteWorktrees(
            targets,
            keepBranch: false
        )

        #expect(results.count == targets.count)
        #expect(results.contains { $0.outcome != .deleted })
        #expect(results.contains { $0.outcome == .deleted })
    }

    @Test func everySelectedItemGetsItsOwnResult() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 3)
        let targets = Array(fixture.worktrees.dropFirst())

        let results = await fixture.state.batchDeleteWorktrees(
            targets,
            keepBranch: false
        )

        #expect(Set(results.map(\.worktreeId)) == Set(targets.map(\.id)))
        #expect(results.map(\.branch) == targets.map(\.branch))
    }

    /// A batch must never pop a modal mid-run. A worktree git refuses to remove
    /// without `--force` is reported back, not escalated into the app-wide
    /// force-delete alert.
    @Test func dirtyWorktreeReportsNeedsForceWithoutRaisingTheForceAlert() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        let target = fixture.worktrees[1]
        try "scratch".write(
            to: target.path.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let results = await fixture.state.batchDeleteWorktrees(
            [target],
            keepBranch: false
        )

        #expect(results[0].outcome == .needsForce)
        #expect(fixture.state.pendingForceDeleteWorktree == nil)
    }

    /// The batch skips per-item selection reconciliation (its list is still
    /// stale mid-run) and reconciles once at the end. Without that final pass
    /// the selection stays pinned to a worktree that no longer exists.
    @Test func selectionIsReconciledAfterBatchDeletesTheSelectedWorktree() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 3)
        let targets = Array(fixture.worktrees.dropFirst())
        fixture.state.selectWorktree(id: targets[0].id)
        #expect(fixture.state.selectedWorktreeId == targets[0].id)

        _ = await fixture.state.batchDeleteWorktrees(targets, keepBranch: false)

        #expect(fixture.state.selectedWorktreeId != targets[0].id)
        #expect(fixture.state.selectedWorktreeId != targets[1].id)
        if let selected = fixture.state.selectedWorktreeId {
            #expect(fixture.state.projectsManager
                .worktrees(projectId: fixture.project.id)
                .contains { $0.id == selected })
        }
    }

    @Test func emptySelectionReturnsNoResultsAndTouchesNothing() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        let before = fixture.state.projectsManager
            .worktrees(projectId: fixture.project.id).count

        let results = await fixture.state.batchDeleteWorktrees([], keepBranch: false)

        #expect(results.isEmpty)
        #expect(fixture.state.projectsManager
            .worktrees(projectId: fixture.project.id).count == before)
    }
}
