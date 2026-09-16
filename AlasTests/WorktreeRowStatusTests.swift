import Testing
@testable import Alas

struct WorktreeRowStatusTests {
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
