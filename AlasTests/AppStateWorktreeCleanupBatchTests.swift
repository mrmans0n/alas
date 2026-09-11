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

    /// The scan that produced a worktree's cached `Worktree.branch` can be
    /// stale by the time the batch actually runs. If something switches the
    /// checkout to a detached HEAD in that window, deleting on the stale
    /// cached branch name would remove a worktree whose commits are now
    /// reachable only via that detached HEAD — orphaning them. The batch
    /// must re-read the current branch immediately before removal.
    @Test func batchSkipsAWorktreeWhoseBranchChangedSinceTheScan() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        let target = fixture.worktrees[1]

        // Simulate an external actor detaching HEAD in this worktree after
        // the scan captured `target` as a named-branch `Worktree` value.
        let detach = try await Process.git(["checkout", "--detach"], cwd: target.path)
        #expect(detach.exitCode == 0)

        let results = await fixture.state.batchDeleteWorktrees([target], keepBranch: false)

        #expect(results[0].outcome == .skipped(reason: "Branch changed since this list was scanned"))
        #expect(FileManager.default.fileExists(atPath: target.path.path))
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

    // MARK: - hasOnlyAcknowledgedDirtiness

    @Test func identicalGenerationsAreAcknowledged() {
        #expect(AppState.hasOnlyAcknowledgedDirtiness(
            current: ["tab-a": 3],
            acknowledgedAtConfirmation: ["tab-a": 3]
        ))
    }

    @Test func emptyCurrentDirtinessIsAlwaysAcknowledged() {
        #expect(AppState.hasOnlyAcknowledgedDirtiness(
            current: [:],
            acknowledgedAtConfirmation: ["tab-a": 3]
        ))
    }

    /// The exact regression this mechanism exists to close: a tab already
    /// dirty (and discarded) at confirmation time, then re-edited since — its
    /// id is unchanged, but its generation has moved on.
    @Test func sameTabAtALaterGenerationIsNotAcknowledged() {
        #expect(!AppState.hasOnlyAcknowledgedDirtiness(
            current: ["tab-a": 4],
            acknowledgedAtConfirmation: ["tab-a": 3]
        ))
    }

    @Test func aNewlyDirtiedTabIsNotAcknowledged() {
        #expect(!AppState.hasOnlyAcknowledgedDirtiness(
            current: ["tab-a": 3, "tab-b": 0],
            acknowledgedAtConfirmation: ["tab-a": 3]
        ))
    }

    @Test func aTabThatBecameCleanDoesNotBlockTheOthers() {
        // "tab-b" was dirty at confirmation and is clean now — its absence
        // from `current` is fine; only what's dirty *now* is checked.
        #expect(AppState.hasOnlyAcknowledgedDirtiness(
            current: ["tab-a": 3],
            acknowledgedAtConfirmation: ["tab-a": 3, "tab-b": 1]
        ))
    }

    @Test func unopenedSnapshotOnlyTabsMatchOnTheSentinelGeneration() {
        // A tab with only a persisted hot-exit snapshot (no live buffer) is
        // recorded at the -1 sentinel; as long as it's never opened, that
        // stays stable across the snapshot and the recheck.
        #expect(AppState.hasOnlyAcknowledgedDirtiness(
            current: ["tab-a": -1],
            acknowledgedAtConfirmation: ["tab-a": -1]
        ))
    }
}
