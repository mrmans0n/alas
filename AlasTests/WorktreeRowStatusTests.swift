import Testing
@testable import Alas

struct WorktreeRowStatusTests {
    @Test func runningSessionShowsPulsingGreenChip() throws {
        let status = try #require(WorktreeRowView.statusPresentation(harnessState: .running))
        #expect(status.note == "running")
        #expect(status.colorToken == "add")
        #expect(status.pulses)
    }

    @Test func awaitingSessionShowsAmberChipWithoutPulse() throws {
        let status = try #require(WorktreeRowView.statusPresentation(harnessState: .awaiting))
        #expect(status.note == "waiting")
        #expect(status.colorToken == "mod")
        #expect(!status.pulses)
    }

    @Test func idleRowHasNoStatusChipAtAll() {
        // The E1 mock pairs a dot with the word "clean" here. We cannot honour
        // that yet: Worktree.status is written .clean unconditionally, so
        // rendering it would assert a worktree has no uncommitted work without
        // anything having checked.
        //
        // Returning nil rather than a label-less presentation is deliberate.
        // An earlier version returned `note: nil` with a colour, and the view
        // drew the dot unconditionally while gating only the label — leaving a
        // meaningless grey circle on every idle row. Modelling "no status" as
        // absence makes that class of bug unrepresentable.
        #expect(WorktreeRowView.statusPresentation(harnessState: nil) == nil)
    }

    @Test func aChipAlwaysCarriesALabel() {
        // The dot and its label are one unit: any presentation that exists must
        // have something to say, or it should not exist.
        let states: [HarnessService.AggregatedState?] = [.running, .awaiting, nil]
        for state in states {
            guard let status = WorktreeRowView.statusPresentation(harnessState: state) else { continue }
            #expect(!status.note.isEmpty)
        }
    }

    @Test func noStateEverProducesTheWordClean() {
        let states: [HarnessService.AggregatedState?] = [.running, .awaiting, nil]
        for state in states {
            let note = WorktreeRowView.statusPresentation(harnessState: state)?.note
            #expect(note?.localizedCaseInsensitiveContains("clean") != true)
        }
    }
}
