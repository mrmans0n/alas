import Foundation
import Testing
@testable import Alas

struct WorktreeRowStatusTests {
    @Test func commitFallbackOnlyAppearsForCleanIdleBranches() {
        #expect(WorktreeRowView.showsCommitCount(harnessState: nil, worktreeStatus: .clean, isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: .running, worktreeStatus: .clean, isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: .awaiting, worktreeStatus: .clean, isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: nil, worktreeStatus: .unknown, isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: nil, worktreeStatus: .dirty(fileCount: 1, conflictCount: 0), isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: nil, worktreeStatus: .clean, isMain: true))
    }

    @Test func diffBarsHandleOneSidedAndEmptyChanges() {
        #expect(WorktreeRowView.diffBarAdditionCount(added: 0, deleted: 0) == nil)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 0, deleted: 12) == 0)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 12, deleted: 0) == 5)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 86, deleted: 12) == 4)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 1, deleted: 1000) == 1)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 1000, deleted: 1) == 4)
    }

    @Test func runningSessionShowsPulsingGreenChip() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: .running, worktreeStatus: .clean))
        #expect(status.note == "running")
        #expect(status.colorToken == "add")
        #expect(status.pulses)
    }

    @Test func awaitingSessionShowsAmberChipWithoutPulse() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: .awaiting, worktreeStatus: .clean))
        #expect(status.note == "waiting")
        #expect(status.colorToken == "mod")
        #expect(!status.pulses)
    }

    @Test func cleanAndUnknownBothRenderNothing() {
        // Identical output, different meaning: `unknown` exists so the first
        // paint after launch does not assert every worktree is clean.
        #expect(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .clean) == nil)
        #expect(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .unknown) == nil)
    }

    @Test func dirtyWorktreeReportsItsFileCount() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .dirty(fileCount: 3, conflictCount: 0)))
        #expect(status.note == "3 files")
        #expect(status.colorToken == "mod")
        #expect(!status.pulses)
    }

    @Test func singleDirtyFileIsSingular() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .dirty(fileCount: 1, conflictCount: 0)))
        #expect(status.note == "1 file")
    }

    @Test func conflictsOutrankPlainDirt() throws {
        // A conflicted worktree is blocked, not merely modified.
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .dirty(fileCount: 5, conflictCount: 2)))
        #expect(status.note == "2 conflicts")
        #expect(status.colorToken == "del")
    }

    @Test func singleConflictIsSingular() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .dirty(fileCount: 1, conflictCount: 1)))
        #expect(status.note == "1 conflict")
    }

    @Test func harnessActivityOutranksDirt() throws {
        // One chip slot; an agent mid-flight is the more urgent fact.
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: .running, worktreeStatus: .dirty(fileCount: 9, conflictCount: 3)))
        #expect(status.note == "running")
    }

    @Test func aChipAlwaysCarriesALabel() {
        let harnessStates: [HarnessService.AggregatedState?] = [.running, .awaiting, nil]
        let worktreeStates: [WorktreeDirtyState] = [
            .unknown, .clean,
            .dirty(fileCount: 1, conflictCount: 0),
            .dirty(fileCount: 4, conflictCount: 2)
        ]
        for harness in harnessStates {
            for worktree in worktreeStates {
                guard let status = WorktreeRowView.statusPresentation(
                    harnessState: harness, worktreeStatus: worktree) else { continue }
                #expect(!status.note.isEmpty)
            }
        }
    }

    @Test func commitQueryIdentityIgnoresRevision() {
        let base = WorktreeRowView.CommitQuery(
            path: URL(fileURLWithPath: "/repo/worktree"),
            branch: "feature",
            baseBranch: "main",
            preferLocal: false,
            host: nil,
            revision: 1
        )
        let bumped = WorktreeRowView.CommitQuery(
            path: base.path,
            branch: base.branch,
            baseBranch: base.baseBranch,
            preferLocal: base.preferLocal,
            host: base.host,
            revision: 2
        )
        // A revision bump alone — e.g. an unrelated ref change elsewhere in
        // the project — must not read as a different subject, or an
        // already-loaded commit count would blink out while it refetches.
        #expect(base.identity == bumped.identity)

        let differentBranch = WorktreeRowView.CommitQuery(
            path: base.path,
            branch: "other",
            baseBranch: base.baseBranch,
            preferLocal: base.preferLocal,
            host: base.host,
            revision: 1
        )
        #expect(base.identity != differentBranch.identity)

        // Same path on a different host is a different count source.
        let differentHost = WorktreeRowView.CommitQuery(
            path: base.path,
            branch: base.branch,
            baseBranch: base.baseBranch,
            preferLocal: base.preferLocal,
            host: "remote.test",
            revision: base.revision
        )
        #expect(base.identity != differentHost.identity)
    }

    @Test func zeroCommitsAreNotVisible() {
        #expect(!WorktreeRowView.hasVisibleCommits(nil))
        #expect(!WorktreeRowView.hasVisibleCommits(GitService.BranchCommitCount(count: 0, baseRef: "main")))
        #expect(WorktreeRowView.hasVisibleCommits(GitService.BranchCommitCount(count: 1, baseRef: "main")))
    }

    @Test func noStateEverProducesTheWordClean() {
        let harnessStates: [HarnessService.AggregatedState?] = [.running, .awaiting, nil]
        let worktreeStates: [WorktreeDirtyState] = [
            .unknown, .clean,
            .dirty(fileCount: 2, conflictCount: 0),
            .dirty(fileCount: 2, conflictCount: 1)
        ]
        for harness in harnessStates {
            for worktree in worktreeStates {
                let note = WorktreeRowView.statusPresentation(
                    harnessState: harness, worktreeStatus: worktree)?.note
                #expect(note?.localizedCaseInsensitiveContains("clean") != true)
            }
        }
    }
}
