import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateWorktreeCleanupBatchTests {
    @Test func mainWorktreeIsSkippedAndNeverDeleted() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
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
        defer { fixture.cleanUpAfterTest() }
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
        defer { fixture.cleanUpAfterTest() }
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
        defer { fixture.cleanUpAfterTest() }
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

    @Test func batchDeleteFailsWhenCheckpointRecoveryIsPending() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]
        let lineageID = try #require(target.lineageID)
        let store = WorktreeCheckpointStore()
        let journal = CheckpointRestoreJournal(
            lineageID: lineageID,
            checkpointID: UUID(),
            recoveryCheckpointID: UUID(),
            phase: .prepared,
            stagingRoot: target.path.appendingPathComponent(".alas-checkpoint-restore-\(UUID().uuidString.lowercased())").path,
            selectedPaths: ["File.swift"],
            expectedFingerprint: "fingerprint",
            expectedIndexChecksum: "checksum"
        )
        try await store.writeJournal(journal)
        defer { try? FileManager.default.removeItem(at: Paths.checkpointsRoot.appendingPathComponent(lineageID, isDirectory: true)) }

        let results = await fixture.state.batchDeleteWorktrees([target], keepBranch: false)

        #expect(results[0].outcome == .failed(message: "An interrupted checkpoint restore needs recovery before this worktree can be deleted."))
        #expect(FileManager.default.fileExists(atPath: target.path.path))
    }

    /// The batch skips per-item selection reconciliation (its list is still
    /// stale mid-run) and reconciles once at the end. Without that final pass
    /// the selection stays pinned to a worktree that no longer exists.
    @Test func selectionIsReconciledAfterBatchDeletesTheSelectedWorktree() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 3)
        defer { fixture.cleanUpAfterTest() }
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

    @Test func selectionIsReconciledAfterSingleDeleteRemovesTheSelectedWorktree() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]
        #expect(fixture.state.projects.map(\.id) == [fixture.project.id])
        fixture.state.selectWorktree(id: target.id)

        let result = await fixture.state.cliDeleteWorktree(target, force: true, keepBranch: true)

        #expect(result == .ok)
        for _ in 0..<100 {
            let stillListed = fixture.state.projectsManager
                .worktrees(projectId: fixture.project.id)
                .contains { $0.id == target.id }
            let stillClaimed = fixture.state.projectsManager.operationState(
                forWorktreeId: target.id,
                projectId: fixture.project.id
            ) != nil
            if !stillListed, !stillClaimed, fixture.state.selectedWorktreeId != target.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let otherProjectsStillListingTarget = fixture.state.projects.filter { project in
            project.id != fixture.project.id && fixture.state.projectsManager
                .worktrees(projectId: project.id)
                .contains { $0.id == target.id }
        }
        #expect(otherProjectsStillListingTarget.isEmpty)
        #expect(fixture.state.selectedWorktreeId != target.id)
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
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]

        // Simulate an external actor detaching HEAD in this worktree after
        // the scan captured `target` as a named-branch `Worktree` value.
        let detach = try await Process.git(["checkout", "--detach"], cwd: target.path)
        #expect(detach.exitCode == 0)

        let results = await fixture.state.batchDeleteWorktrees([target], keepBranch: false)

        #expect(results[0].outcome == .skipped(reason: "Branch changed since this list was scanned"))
        #expect(FileManager.default.fileExists(atPath: target.path.path))
    }

    /// A batch skips per-item refreshes, so each item's `.deleting` claim is
    /// held until the batch's single trailing refresh releases it together
    /// with the reconciled row. A claim that outlived the batch would block
    /// session admission for that id forever.
    @Test func batchReleasesHeldDeletingClaimsWhenItReturns() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 3)
        defer { fixture.cleanUpAfterTest() }
        let targets = Array(fixture.worktrees.dropFirst())

        let results = await fixture.state.batchDeleteWorktrees(targets, keepBranch: false)

        let deletedIDs = results.filter { $0.outcome == .deleted }.map(\.worktreeId)
        #expect(deletedIDs.count == targets.count)
        #expect(deletedIDs.allSatisfy {
            fixture.state.projectsManager.operationState(forWorktreeId: $0, projectId: fixture.project.id) == nil
        })
    }

    @Test func batchCleansRuntimeAfterDeletingEveryProjectSharingAWorktreeID() async throws {
        @MainActor
        final class SharedPathRemoval {
            weak var state: AppState?
            var projectID = ""
            var worktreeID = ""
            var tickets: [WorktreeTrashCleanupTicket] = []
        }
        let removal = SharedPathRemoval()
        let fixture = try await makeCleanupFixture(worktreeCount: 2) { ticket in
            removal.tickets.append(ticket)
            // A different project's refresh completes after this batch item
            // has skipped runtime cleanup for the still-listed shared id,
            // but before this batch's trailing refresh removes its own row.
            removal.state?.projectsManager.dropRemovedWorktree(
                id: removal.worktreeID,
                projectId: removal.projectID
            )
        }
        defer { fixture.cleanUpAfterTest() }
        let firstProjectTarget = fixture.worktrees[1]
        defer {
            for ticket in removal.tickets {
                try? FileManager.default.removeItem(at: ticket.trashRoot)
            }
        }

        let secondRepo = fixture.temporaryRoot.appendingPathComponent("second-repo")
        try FileManager.default.createDirectory(at: secondRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: secondRepo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: secondRepo)
        _ = try await Process.git(["config", "user.name", "test"], cwd: secondRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: secondRepo)

        let secondProject = try await fixture.state.projectsManager.addProject(
            path: secondRepo,
            displayName: "cleanup-fixture-second",
            color: "#5fb7c4"
        )
        let samePathOnSecondHost = Worktree(
            id: firstProjectTarget.id,
            projectId: secondProject.id,
            name: firstProjectTarget.name,
            branch: firstProjectTarget.branch,
            path: firstProjectTarget.path,
            status: .clean,
            lastActivity: .distantPast
        )
        fixture.state.projectsManager.insertOptimisticWorktree(samePathOnSecondHost)
        removal.state = fixture.state
        removal.projectID = secondProject.id
        removal.worktreeID = firstProjectTarget.id

        let firstManager = try #require(fixture.state.acpManager(for: firstProjectTarget))
        fixture.state.tabs.appendTerminal(
            worktreeId: firstProjectTarget.id,
            title: "shared runtime",
            sessionId: "shared-runtime-session"
        )
        let preflight = try await WorktreeService().deletePreflight(worktreePath: firstProjectTarget.path)
        let authorization = WorktreeCleanupDeleteAuthorization(
            sessionIDsByWorktree: [firstProjectTarget.id: ["shared-runtime-session"]],
            preflightByWorktree: [firstProjectTarget.id: preflight]
        )

        let results = await fixture.state.batchDeleteWorktrees(
            [firstProjectTarget],
            keepBranch: true,
            authorization: authorization
        )

        #expect(results.map(\.outcome) == [.deleted])
        #expect(fixture.state.projectsManager
            .worktrees(projectId: secondProject.id)
            .allSatisfy { $0.id != firstProjectTarget.id })
        #expect(fixture.state.tabs.tabs(forWorktree: firstProjectTarget.id).isEmpty)
        #expect(fixture.state.acpManager(forWorktreeId: firstProjectTarget.id) == nil)
        #expect(firstManager.runners.isEmpty)
    }

    /// A batch holds each item's `.deleting` claim past the removal itself.
    /// The stale row stays in the visible list until the batch's trailing
    /// refresh, so releasing the claim per item would let that row resolve as
    /// an ordinary worktree — remounting the right pane this deletion
    /// collapsed, and re-admitting sessions into a worktree already gone.
    ///
    /// Observed at the second item's cleanup launch: the one point inside the
    /// batch that runs after the first item's removal completed and before
    /// the trailing refresh.
    @Test func batchHoldsAnEarlierItemsDeletingClaimUntilTheTrailingRefresh() async throws {
        @MainActor
        final class BatchObservation {
            var state: AppState?
            var firstID = ""
            var projectID = ""
            var firstClaimAtLaunch: [WorktreeOperationState?] = []
            var firstListedAtLaunch: [Bool] = []
        }
        let observation = BatchObservation()
        let fixture = try await makeCleanupFixture(worktreeCount: 3) { _ in
            guard let state = observation.state else { return }
            observation.firstClaimAtLaunch.append(
                state.projectsManager.operationState(forWorktreeId: observation.firstID, projectId: observation.projectID)
            )
            observation.firstListedAtLaunch.append(
                state.projectsManager.worktrees(projectId: observation.projectID)
                    .contains { $0.id == observation.firstID }
            )
        }
        defer { fixture.cleanUpAfterTest() }
        let first = fixture.worktrees[1]
        let second = fixture.worktrees[2]
        observation.state = fixture.state
        observation.firstID = first.id
        observation.projectID = fixture.project.id

        let results = await fixture.state.batchDeleteWorktrees([first, second], keepBranch: false)

        #expect(results.map(\.outcome) == [.deleted, .deleted])
        try #require(observation.firstClaimAtLaunch.count == 2)
        // The first item's row is still listed while the second one is being
        // removed, and must still read as deleting.
        #expect(observation.firstListedAtLaunch == [true, true])
        #expect(observation.firstClaimAtLaunch[1] == .deleting(projectId: fixture.project.id))
        // The claim is released once the trailing refresh reconciles the row.
        #expect(fixture.state.projectsManager.operationState(forWorktreeId: first.id, projectId: fixture.project.id) == nil)
        #expect(fixture.state.projectsManager.operationState(forWorktreeId: second.id, projectId: fixture.project.id) == nil)
    }

    /// When the batch's trailing refresh fails, the removed row must not stay
    /// behind: it would resolve as an ordinary worktree (remounting the right
    /// pane this deletion collapsed, reopening session admission for a
    /// checkout that is gone) and `allWorktreeIds()` would keep the deleted
    /// selection alive. The row is dropped directly in that case.
    @Test func failedTrailingRefreshStillDropsRemovedRows() async throws {
        @MainActor
        final class RefreshBreaker {
            var repoPath: URL?
            var movedTo: URL?
        }
        let breaker = RefreshBreaker()
        // The cleanup launcher runs after the removal succeeded and before
        // the trailing refresh, so breaking the repo here is what makes that
        // refresh throw. A plain file is left at the repository path instead
        // of only moving the directory aside: git then fails immediately with
        // "not a git repository" rather than stalling toward its own timeout
        // against a path that no longer exists, which under CI's per-test
        // allowance is the difference between a fast failure and a timeout.
        let fixture = try await makeCleanupFixture(worktreeCount: 2) { _ in
            guard let repoPath = breaker.repoPath, breaker.movedTo == nil else { return }
            let saved = FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-broken-repo-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: repoPath, to: saved)
            breaker.movedTo = saved
            try Data("not a repository".utf8).write(to: repoPath)
        }
        defer {
            if let saved = breaker.movedTo {
                try? FileManager.default.removeItem(at: fixture.repoPath)
                try? FileManager.default.moveItem(at: saved, to: fixture.repoPath)
            }
            fixture.cleanUpAfterTest()
        }
        let target = fixture.worktrees[1]
        breaker.repoPath = fixture.repoPath
        // Give the row metadata a successful refresh would have reconciled
        // away with it, so the fallback can be held to the same standard.
        fixture.state.projectsManager.setGGWorktreeMode(
            projectId: fixture.project.id,
            worktreeId: target.id,
            mode: .off
        )
        fixture.state.projectsManager.setIssueAttachment(
            projectId: fixture.project.id,
            worktreeId: target.id,
            attachment: IssueAttachment(
                canonicalURL: URL(string: "https://example.test/42")!,
                providerLabel: "GitHub",
                displayReference: "#42",
                title: "t"
            )
        )

        let results = await fixture.state.batchDeleteWorktrees([target], keepBranch: false)

        #expect(results.map(\.outcome) == [.deleted])
        // The refresh could not run, so the row must have been dropped by the
        // failure fallback rather than left behind as an ordinary worktree.
        #expect(!fixture.state.projectsManager
            .worktrees(projectId: fixture.project.id)
            .contains { $0.id == target.id })
        #expect(fixture.state.projectsManager.operationState(forWorktreeId: target.id, projectId: fixture.project.id) == nil)
        // ...and the persisted per-worktree metadata must go with it, or a
        // hosted project restores the deleted row from `cachedWorktrees` at
        // startup recovery and recreating the path inherits stale state.
        #expect(fixture.state.projectsManager.ggWorktreeMode(
            projectId: fixture.project.id,
            worktreeId: target.id
        ) == .inherit)
        #expect(fixture.state.projectsManager.issueAttachment(
            projectId: fixture.project.id,
            worktreeId: target.id
        ) == nil)
        let persisted = fixture.persistence.writtenProjectsFile?.projects
            .first { $0.id == fixture.project.id }
        #expect(persisted?.cachedWorktrees.contains { $0.id == target.id } == false)
        #expect(persisted?.ggWorktreeModes[target.id] == nil)
        #expect(persisted?.issueAttachments[target.id] == nil)
    }

    /// A checkout recreated at the deleted path before the post-delete refresh
    /// keeps the same path-derived id, so the refresh cannot tell the new row
    /// apart from the removed one and leaves the `.deleting` claim in place —
    /// which would hide the new checkout from the right pane and block its
    /// sessions forever. The removal has succeeded by then, so the claim is
    /// released regardless of what now holds that id.
    @Test func deletionClaimIsReleasedWhenThePathIsRecreated() async throws {
        @MainActor
        final class Recreation {
            var repoPath: URL?
            var deletedPath: URL?
            var templatePath: URL?
            var recreated = false
        }
        let recreation = Recreation()
        // The cleanup launcher runs once the removal succeeded and before the
        // trailing refresh, so recreating the checkout here is exactly the
        // race: the refresh that follows sees a row at the removed id.
        let fixture = try await makeCleanupFixture(worktreeCount: 3) { _ in
            guard let repoPath = recreation.repoPath,
                  let deletedPath = recreation.deletedPath,
                  let templatePath = recreation.templatePath,
                  !recreation.recreated
            else { return }
            recreation.recreated = true
            try Process.registerWorktree(
                deletedPath,
                branch: "feature-2",
                repoPath: repoPath,
                template: templatePath
            )
        }
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]
        recreation.repoPath = fixture.repoPath
        recreation.deletedPath = target.path
        // A sibling that survives the batch, so its git-administrative
        // directory is available to copy.
        let template = fixture.worktrees[2]
        recreation.templatePath = template.path

        let results = await fixture.state.batchDeleteWorktrees([target], keepBranch: false)

        #expect(results.map(\.outcome) == [.deleted])
        #expect(recreation.recreated)
        // The recreated checkout carries the same path-derived id, so the
        // trailing refresh lists it and cannot clear the claim itself. The
        // claim must not survive: it would hide the new checkout from the
        // right pane and block its sessions for good.
        #expect(fixture.state.projectsManager
            .worktrees(projectId: fixture.project.id)
            .contains { $0.id == target.id })
        #expect(fixture.state.projectsManager.operationState(
            forWorktreeId: target.id,
            projectId: fixture.project.id
        ) == nil)
    }

    @Test func emptySelectionReturnsNoResultsAndTouchesNothing() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
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

    @Test func worktreeDeleteContentFingerprintChangesWhenDirtyContentChanges() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]
        let scratch = target.path.appendingPathComponent("scratch.txt")
        try "before".write(to: scratch, atomically: true, encoding: .utf8)
        let firstFingerprint = try await AppState.worktreeDeleteContentFingerprint(worktreePath: target.path)

        try "after".write(to: scratch, atomically: true, encoding: .utf8)

        let secondFingerprint = try await AppState.worktreeDeleteContentFingerprint(worktreePath: target.path)
        #expect(secondFingerprint != firstFingerprint)
    }

    @Test func worktreeDeleteContentFingerprintChangesWhenStagedContentChanges() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]
        let tracked = target.path.appendingPathComponent("tracked.txt")
        try "base".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "tracked.txt"], cwd: target.path)
        _ = try await Process.git(["commit", "-q", "-m", "track file"], cwd: target.path)

        try "staged one".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "tracked.txt"], cwd: target.path)
        _ = try await Process.git(["restore", "--worktree", "--source=HEAD", "tracked.txt"], cwd: target.path)
        let firstFingerprint = try await AppState.worktreeDeleteContentFingerprint(worktreePath: target.path)

        try "staged two".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "tracked.txt"], cwd: target.path)
        _ = try await Process.git(["restore", "--worktree", "--source=HEAD", "tracked.txt"], cwd: target.path)
        let secondFingerprint = try await AppState.worktreeDeleteContentFingerprint(worktreePath: target.path)

        #expect(secondFingerprint != firstFingerprint)
    }
    @Test func workspaceCleanupOwnershipIsAvailableWhenWorkspacePreviewIsDisabled() {
        #expect(AppState.workspaceCleanupOwnershipAvailable(
            workspacesEnabled: false,
            workspacesCanMutate: false
        ))
        #expect(AppState.workspaceCleanupOwnershipAvailable(
            workspacesEnabled: true,
            workspacesCanMutate: true
        ))
        #expect(!AppState.workspaceCleanupOwnershipAvailable(
            workspacesEnabled: true,
            workspacesCanMutate: false
        ))
    }

    @Test func missingHarnessActivityIsIdleForCleanupSessionCounts() {
        #expect(!AppState.harnessActivityIsBusy(nil))
        #expect(!AppState.harnessActivityIsBusy(.idle))
        #expect(AppState.harnessActivityIsBusy(.busy))
    }

    /// Regression: the instant delete-confirmation dialog blocks the main
    /// thread via `NSAlert.runModal()`, but that call's nested run loop
    /// still pumps other main-actor work — a scheduled run or
    /// issue-triggered session could be admitted into the worktree while
    /// the user is still deciding unless `.preparingDelete` blocks it the
    /// same way `.creating`/`.deleting` already do.
    @Test func preparingDeleteBlocksWorktreeSessionAdmission() {
        #expect(AppState.blocksWorktreeSessionAdmission(.preparingDelete))
        #expect(AppState.blocksWorktreeSessionAdmission(.creating))
        #expect(AppState.blocksWorktreeSessionAdmission(.deleting(projectId: "p")))
        #expect(!AppState.blocksWorktreeSessionAdmission(nil))
        #expect(!AppState.blocksWorktreeSessionAdmission(.deleteFailed(message: "x")))
    }
}
