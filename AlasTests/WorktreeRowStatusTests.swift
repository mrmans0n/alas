import Testing
@testable import Alas

struct WorktreeRowStatusTests {
    @Test func runningSessionShowsPulsingGreenChip() {
        let status = WorktreeRowView.statusPresentation(harnessState: .running)
        #expect(status.note == "running")
        #expect(status.colorToken == "add")
        #expect(status.pulses)
    }

    @Test func awaitingSessionShowsAmberChipWithoutPulse() {
        let status = WorktreeRowView.statusPresentation(harnessState: .awaiting)
        #expect(status.note == "waiting")
        #expect(status.colorToken == "mod")
        #expect(!status.pulses)
    }

    @Test func idleRowShowsNoNoteText() {
        // The E1 mock says "clean" here. We cannot honour that yet:
        // Worktree.status is written as .clean unconditionally, so rendering
        // it would assert a worktree has no uncommitted work without ever
        // having checked. An empty slot is the honest version until the
        // per-worktree git status service lands.
        let status = WorktreeRowView.statusPresentation(harnessState: nil)
        #expect(status.note == nil)
        #expect(status.colorToken == "fg-faint")
        #expect(!status.pulses)
    }

    @Test func noStateEverProducesTheWordClean() {
        let states: [HarnessService.AggregatedState?] = [.running, .awaiting, nil]
        for state in states {
            let note = WorktreeRowView.statusPresentation(harnessState: state).note
            #expect(note?.localizedCaseInsensitiveContains("clean") != true)
        }
    }
}
