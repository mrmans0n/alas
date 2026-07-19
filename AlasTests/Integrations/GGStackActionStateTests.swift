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
}
