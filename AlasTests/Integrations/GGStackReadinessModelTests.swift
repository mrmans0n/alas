import Testing
@testable import Alas

@MainActor
struct GGStackReadinessModelTests {
    private func entry(
        position: Int, prState: GGPRState?, approved: Bool = false, ci: GGCIStatus? = nil
    ) -> GGStackEntry {
        GGStackEntry(
            position: position, sha: "sha\(position)", title: "t\(position)",
            ggId: "id\(position)", prNumber: prState == nil ? nil : 100 + position,
            prState: prState, approved: approved, ciStatus: ci
        )
    }

    private func stack(_ entries: [GGStackEntry], total: Int? = nil, synced: Int = 0, behind: Int? = nil) -> GGStack {
        GGStack(
            name: "feat", base: "main", totalCommits: total ?? entries.count,
            syncedCommits: synced, currentPosition: nil, behindBase: behind, entries: entries
        )
    }

    @Test func titleAndFacts() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .merged), entry(position: 2, prState: .open)], synced: 2),
            action: GGStackActionState()
        )
        #expect(model.title == "Stack · feat")
        #expect(model.facts.contains { $0.label == "Entries" && $0.value == "2" })
        #expect(model.facts.contains { $0.label == "Merged" && $0.value == "1" })
    }

    @Test func syncEnabledWhenBaseIsCurrent() {
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: nil)]), action: GGStackActionState())
        let sync = model.actions.first { $0.kind == .sync }
        #expect(sync?.isEnabled == true)
    }

    @Test func syncDisabledWhenBaseIsBehind() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: nil)], behind: 1),
            action: GGStackActionState()
        )
        let sync = model.actions.first { $0.kind == .sync }
        #expect(sync?.isEnabled == false)
    }

    @Test func landReadyEnabledWithOpenEntryForFreshVerification() {
        let staleProviderState = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open, approved: false, ci: .success)]),
            action: GGStackActionState()
        )
        #expect(staleProviderState.actions.first { $0.kind == .land }?.isEnabled == true)

        let noOpenEntries = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .merged)]),
            action: GGStackActionState()
        )
        #expect(noOpenEntries.actions.first { $0.kind == .land }?.isEnabled == false)
    }

    @Test func cleanEnabledOnlyWithMergedEntry() {
        let noMerged = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: GGStackActionState()
        )
        #expect(noMerged.actions.first { $0.kind == .clean }?.isEnabled == false)

        let merged = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .merged)]), action: GGStackActionState()
        )
        #expect(merged.actions.first { $0.kind == .clean }?.isEnabled == true)
    }

    @Test func pausedSwapsToContinueAbort() {
        let action = GGStackActionState()
        action.setPaused(GGPausedOperation(pausedBy: .land))
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: .open)]), action: action)
        #expect(model.isPaused)
        #expect(model.actions.map(\.kind) == [.continueOp, .abortOp])
    }

    @Test func pausedFallbackOffersContinueAbortWithoutStack() {
        let action = GGStackActionState()
        action.setPaused(GGPausedOperation(pausedBy: .sync))
        let model = GGStackReadinessModel.makePausedFallback(action: action)
        #expect(model?.isPaused == true)
        #expect(model?.summaryChip == "paused")
        #expect(model?.actions.map(\.kind) == [.continueOp, .abortOp])
    }

    @Test func inFlightActionMarksButtonAndDisablesOthers() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open, approved: true, ci: .success)]), action: action
        )
        let sync = model.actions.first { $0.kind == .sync }
        #expect(sync?.isInFlight == true)
        // Other actions disabled while one is in flight.
        #expect(model.actions.first { $0.kind == .land }?.isEnabled == false)
    }

    @Test func summaryChipPriorityPausedThenUnsyncedThenBehindThenMerged() {
        let paused = GGStackActionState()
        paused.setPaused(GGPausedOperation(pausedBy: .sync))
        #expect(GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: .open)]), action: paused)
            .summaryChip.lowercased().contains("paused"))

        // 1 of 2 synced → 1 unsynced.
        let unsynced = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open), entry(position: 2, prState: nil)], total: 2, synced: 1),
            action: GGStackActionState()
        )
        #expect(unsynced.summaryChip.contains("unsynced"))

        let behind = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)], total: 1, synced: 1, behind: 3),
            action: GGStackActionState()
        )
        #expect(behind.summaryChip.contains("3"))

        let merged = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .merged)], total: 1, synced: 1),
            action: GGStackActionState()
        )
        #expect(merged.summaryChip == "1/1 merged")
    }

    @Test func progressRowsRenderDuringSync() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.start(totalEntries: 1))
        action.appendSyncEvent(.pushStarted(position: 1))
        action.appendSyncEvent(.prCreated(position: 1, prNumber: 7, prURL: nil, draft: false))
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: .open)]), action: action)
        #expect(!model.progressRows.isEmpty)
        #expect(model.progressRows.contains { $0.contains("7") })
    }

    @Test func pausedOnSyncKeepsProgressRowsAndOffersContinueAbort() {
        // Reproduces the exact state a rebase conflict during `gg sync` leaves
        // behind: syncProgress is non-empty AND the operation is paused. The
        // model must report both facts simultaneously so the drawer can show
        // the progress list *and* still surface Continue/Abort.
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.start(totalEntries: 1))
        action.appendSyncEvent(.pushStarted(position: 1))
        action.endAction(.sync) // sync's gg process exits when it hits the conflict
        action.setPaused(GGPausedOperation(pausedBy: .sync)) // watcher-driven filesystem probe picks up the pause
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: .open)]), action: action)
        #expect(model.isPaused)
        #expect(model.actions.map(\.kind) == [.continueOp, .abortOp])
        #expect(!model.progressRows.isEmpty)
    }

    @Test func progressRowsClearedWhenDifferentActionSucceedsSync() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.start(totalEntries: 1))
        action.appendSyncEvent(.pushStarted(position: 1))
        action.appendSyncEvent(.prCreated(position: 1, prNumber: 7, prURL: nil, draft: false))
        action.endAction(.sync)
        // Simulates the leak scenario: sync finished without clearSyncProgress()
        // being called, then an unrelated action starts.
        _ = action.beginAction(.land)
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: .open)]), action: action)
        #expect(!action.syncProgress.isEmpty)
        #expect(model.progressRows.isEmpty)
    }
}
