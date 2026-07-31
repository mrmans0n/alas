import Testing
@testable import Alas

@MainActor
struct GGStackActionStateTests {
    @Test func beginActionGuardsAgainstConcurrentActions() {
        let state = GGStackActionState()
        #expect(state.beginAction(.sync))
        #expect(state.inFlightAction == .sync)
        // A second action while one is in flight is rejected.
        #expect(!state.beginAction(.land))
        #expect(state.inFlightAction == .sync)
        state.endAction(.sync)
        #expect(state.inFlightAction == nil)
        #expect(state.beginAction(.land))
    }

    @Test func endActionOnlyClearsMatchingAction() {
        let state = GGStackActionState()
        _ = state.beginAction(.sync)
        state.endAction(.land) // non-matching: no-op
        #expect(state.inFlightAction == .sync)
        state.endAction(.sync)
        #expect(state.inFlightAction == nil)
    }

    @Test func syncProgressAccumulatesAndClears() {
        let state = GGStackActionState()
        state.appendSyncEvent(.start(totalEntries: 2))
        state.appendSyncEvent(.pushStarted(position: 1))
        #expect(state.syncProgress.count == 2)
        state.clearSyncProgress()
        #expect(state.syncProgress.isEmpty)
    }

    @Test func beginningAnyLaterActionClearsRetainedSyncProgress() {
        let state = GGStackActionState()
        _ = state.beginAction(.sync)
        state.appendSyncEvent(.start(totalEntries: 1))
        state.appendSyncEvent(.error(position: 1, operation: "push", message: "push failed"))
        state.endAction(.sync)
        #expect(!state.syncProgress.isEmpty)

        _ = state.beginAction(.land)
        #expect(state.syncProgress.isEmpty)
    }

    @Test func beginningAnyLaterActionClearsRetainedError() {
        let state = GGStackActionState()
        _ = state.beginAction(.sync)
        state.setError("push failed")
        state.markSyncTerminalFailure()
        state.endAction(.sync)

        #expect(state.syncHasTerminalFailure)

        _ = state.beginAction(.land)

        #expect(state.lastError == nil)
        #expect(!state.syncHasTerminalFailure)
    }

    @Test func errorAndPausedRoundTrip() {
        let state = GGStackActionState()
        state.setError("boom")
        #expect(state.lastError == "boom")
        state.clearError()
        #expect(state.lastError == nil)
        state.setPaused(GGPausedOperation(pausedBy: .land))
        #expect(state.pausedOperation == GGPausedOperation(pausedBy: .land))
        state.clearPaused()
        #expect(state.pausedOperation == nil)
    }

    @Test func actionSummaryLifecycle() {
        let state = GGStackActionState()
        state.setActionSummary("Synced · 2 pushed")
        #expect(state.lastActionSummary == "Synced · 2 pushed")
        // Starting any new action clears the previous summary.
        _ = state.beginAction(.clean)
        #expect(state.lastActionSummary == nil)
    }

    @Test func syncSummaryLineCountsEvents() {
        let events: [GGSyncEvent] = [
            .start(totalEntries: 3),
            .pushDone(position: 1, forced: false),
            .pushDone(position: 2, forced: false),
            .prCreated(position: 2, prNumber: 42, prURL: nil, draft: false),
            .summary,
        ]
        #expect(GGStackActionState.syncSummaryLine(from: events) == "Synced · 2 pushed · 1 PR created")
        // No .summary event (errored/cancelled sync) → no summary line.
        #expect(GGStackActionState.syncSummaryLine(from: [.pushDone(position: 1, forced: false)]) == nil)
        // Summary with nothing pushed/created → plain "Synced".
        #expect(GGStackActionState.syncSummaryLine(from: [.summary]) == "Synced")
    }

    @Test func landSummaryLine() {
        #expect(GGStackActionState.landSummaryLine(from: []) == nil)
        #expect(GGStackActionState.landSummaryLine(from: [
            GGLandedEntry(position: 1, prNumber: 1),
        ]) == "Landed 1 PR")
        #expect(GGStackActionState.landSummaryLine(from: [
            GGLandedEntry(position: 1, prNumber: 1),
            GGLandedEntry(position: 2, prNumber: 2),
            GGLandedEntry(position: 3, prNumber: 3),
        ]) == "Landed 3 PRs")
        // Queued (GitLab merge-train) entries are reported separately, not as landed.
        #expect(GGStackActionState.landSummaryLine(from: [
            GGLandedEntry(position: 1, prNumber: 1, action: "merged"),
            GGLandedEntry(position: 2, prNumber: 2, action: "queued"),
            GGLandedEntry(position: 3, prNumber: 3, action: "already_queued"),
        ]) == "Landed 1 PR · Queued 2 PRs")
        #expect(GGStackActionState.landSummaryLine(from: [
            GGLandedEntry(position: 1, prNumber: 1, action: "queued"),
        ]) == "Queued 1 PR")
    }
}
