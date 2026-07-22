import Foundation
import Testing
@testable import Alas

@MainActor
struct GGStackReadinessModelTests {
    @Test func placeholderMapsActiveStackLoadStates() {
        let context = GGWorktreeContext.active(stackName: "feature")

        #expect(GGStackPlaceholderModel.make(context: context, loadState: .loading) == .init(
            title: "feature", summaryChip: "Loading", detail: nil, canRetry: false, isLoading: true
        ))
        #expect(GGStackPlaceholderModel.make(context: context, loadState: .empty) == .init(
            title: "feature", summaryChip: "0 commits", detail: nil, canRetry: false, isLoading: false
        ))
        #expect(GGStackPlaceholderModel.make(context: context, loadState: .failed("gg unavailable")) == .init(
            title: "feature", summaryChip: "Unavailable", detail: "gg unavailable", canRetry: true, isLoading: false
        ))
        #expect(GGStackPlaceholderModel.make(context: context, loadState: .loaded) == nil)
    }

    @Test func placeholderIsAbsentForInactiveContext() {
        let context = GGWorktreeContext.inactive(reason: .policyOff)

        #expect(GGStackPlaceholderModel.make(context: context, loadState: .loading) == nil)
        #expect(GGStackPlaceholderModel.make(context: context, loadState: .empty) == nil)
        #expect(GGStackPlaceholderModel.make(context: context, loadState: .failed("nope")) == nil)
        #expect(GGStackPlaceholderModel.make(context: context, loadState: .inactive) == nil)
    }

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
        #expect(model.facts.contains { $0.label == "Commits" && $0.value == "2" })
        #expect(model.facts.contains { $0.label == "Merged" && $0.value == "1" })
    }

    @Test func unsyncedStackSelectsSyncPrimary() {
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: nil)]), action: GGStackActionState())
        #expect(model.primaryActions.map(\.kind) == [.sync])
    }

    @Test func autoRebaseKeepsSyncPrimaryWhileBehind() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: nil)], behind: 1),
            action: GGStackActionState(),
            effectiveConfig: .init(syncAutoRebase: true, syncBehindThreshold: 1),
            localChanges: .zero
        )
        #expect(model.primaryActions.map(\.kind) == [.sync])
        #expect(model.primaryActions[0].detail == "Includes rebase onto main")
    }

    @Test func autoRebaseBelowThresholdKeepsSyncDetailPlain() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: nil)], behind: 1),
            action: GGStackActionState(),
            effectiveConfig: .init(syncAutoRebase: true, syncBehindThreshold: 3),
            localChanges: .zero
        )
        #expect(model.primaryActions.map(\.kind) == [.sync])
        #expect(model.primaryActions[0].detail == nil)
    }

    @Test func thresholdSelectsManualRebase() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: nil)], behind: 2),
            action: GGStackActionState(),
            effectiveConfig: .init(syncAutoRebase: false, syncBehindThreshold: 2),
            localChanges: .zero
        )
        #expect(model.primaryActions.map(\.kind) == [.rebase])
        #expect(model.primaryActions[0].title == "Rebase onto main")
    }

    @Test func belowThresholdKeepsSyncPrimary() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: nil)], behind: 1),
            action: GGStackActionState(),
            effectiveConfig: .init(syncAutoRebase: false, syncBehindThreshold: 2),
            localChanges: .zero
        )
        #expect(model.primaryActions.map(\.kind) == [.sync])
    }

    @Test func zeroThresholdAlwaysUsesPlainSyncRegardlessOfAutoRebase() {
        for autoRebase in [false, true] {
            let model = GGStackReadinessModel.make(
                stack: stack([entry(position: 1, prState: nil)], behind: 3),
                action: GGStackActionState(),
                effectiveConfig: .init(
                    syncAutoRebase: autoRebase,
                    syncBehindThreshold: 0
                )
            )

            #expect(model.primaryActions.map(\.kind) == [.sync])
            #expect(model.primaryActions[0].detail == nil)
        }
    }

    @Test func syncWithLocalChangesStatesTheyAreExcluded() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: nil)]),
            action: GGStackActionState(),
            effectiveConfig: .defaults,
            localChanges: .init(staged: 1, unstaged: 2)
        )
        #expect(model.primaryActions.map(\.kind) == [.sync])
        #expect(model.localChangesNote == "Local changes are not included")
    }

    @Test func publishableCommitSelectsSyncEvenWhenCommitCountIsSynced() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: nil)], synced: 1),
            action: GGStackActionState(),
            effectiveConfig: .defaults,
            localChanges: .zero
        )
        #expect(model.primaryActions.map(\.kind) == [.sync])
    }

    @Test func syncUsesLiveBehindBaseOverride() {
        let staleStack = stack([entry(position: 1, prState: nil)], synced: 1, behind: 0)
        let model = GGStackReadinessModel.make(
            stack: staleStack,
            action: GGStackActionState(),
            liveBehindBase: 2
        )

        #expect(model.primaryActions.map(\.kind) == [.rebase])
        #expect(model.facts.contains { $0.label == "Behind base" && $0.value == "2" })
        #expect(model.summaryChip.contains("2"))
    }

    @Test func drawerUsesLiveBehindBaseOnlyForMatchingStackBase() {
        let stack = stack([entry(position: 1, prState: nil)], synced: 1, behind: 0)
        let behind = GitService.BehindStatus(ref: "origin/main", sha: "abc", count: 2, probedAt: Date())

        #expect(GGStackDrawer.liveBehindBaseOverride(
            stack: stack,
            selectedBaseBranch: "main",
            behindBase: behind
        ) == 2)
        #expect(GGStackDrawer.liveBehindBaseOverride(
            stack: stack,
            selectedBaseBranch: "release",
            behindBase: behind
        ) == nil)
    }

    @Test func blockingGitOperationDisablesStackMutations() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open, approved: true, ci: .success)]),
            action: GGStackActionState(),
            hasBlockingGitOperation: true
        )

        #expect(model.actions.allSatisfy { !$0.isEnabled })
    }

    @Test func drawerTreatsPlainGitOperationAsBlockingOnlyWhenGGIsNotPaused() {
        let operation = MergeOperation.merge(sourceBranch: "main")

        #expect(GGStackDrawer.hasBlockingGitOperation(
            mergeOperation: operation,
            pausedGGOperation: nil
        ))
        #expect(!GGStackDrawer.hasBlockingGitOperation(
            mergeOperation: operation,
            pausedGGOperation: GGPausedOperation(pausedBy: .sync)
        ))
        #expect(!GGStackDrawer.hasBlockingGitOperation(
            mergeOperation: nil,
            pausedGGOperation: nil
        ))
    }

    @Test func freshLandableStackSelectsLandPrimary() {
        let ready = GGStackReadinessModel.make(
            stack: stack(
                [entry(position: 1, prState: .open, approved: true, ci: .success)],
                synced: 1
            ),
            action: GGStackActionState()
        )
        #expect(ready.primaryActions.map(\.kind) == [.land])

        let staleProviderState = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open, approved: false, ci: .success)]),
            action: GGStackActionState()
        )
        #expect(staleProviderState.primaryActions.map(\.kind) == [.sync])

        let noOpenEntries = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .merged)], synced: 1),
            action: GGStackActionState()
        )
        #expect(noOpenEntries.primaryActions.isEmpty)
    }

    @Test func overflowOrderKeepsLifecycleActionsSeparateFromPrimary() {
        let merged = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .merged)], synced: 1), action: GGStackActionState()
        )
        #expect(merged.overflowActions.map(\.kind) == [.reorder, .restack, .undo, .clean])
        #expect(merged.overflowActions.first { $0.kind == .clean }?.isEnabled == true)
    }

    @Test func undoOverflowIsEnabledOnlyForCoordinatorCandidate() {
        let operation = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["reorder"], touchedRemote: false, isUndoable: true
        )
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .merged)], synced: 1),
            action: GGStackActionState(),
            undoCandidate: GGUndoCandidate(operation: operation)
        )

        #expect(model.overflowActions.first { $0.kind == .undo }?.isEnabled == true)
    }

    @Test func pausedSwapsToContinueAbort() {
        let action = GGStackActionState()
        action.setPaused(GGPausedOperation(pausedBy: .land))
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: .open)]), action: action)
        #expect(model.isPaused)
        #expect(model.primaryActions.map(\.kind) == [.continueOp, .abortOp])
    }

    @Test func pausedFallbackOffersContinueAbortWithoutStack() {
        let action = GGStackActionState()
        action.setPaused(GGPausedOperation(pausedBy: .sync))
        let model = GGStackReadinessModel.makePausedFallback(action: action)
        #expect(model?.isPaused == true)
        #expect(model?.summaryChip == "paused")
        #expect(model?.primaryActions.map(\.kind) == [.continueOp, .abortOp])
    }

    @Test func inFlightActionMarksButtonAndDisablesOthers() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open, approved: true, ci: .success)]), action: action
        )
        let sync = model.primaryActions.first { $0.kind == .sync }
        #expect(sync?.isInFlight == true)
        #expect(model.overflowActions.allSatisfy { !$0.isEnabled })
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
        #expect(model.primaryActions.map(\.kind) == [.continueOp, .abortOp])
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

    @Test func actionSummarySurfacesWhenIdleOnly() {
        let action = GGStackActionState()
        action.setActionSummary("Synced · 1 pushed")
        let idle = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: action
        )
        #expect(idle.actionSummary == "Synced · 1 pushed")

        _ = action.beginAction(.sync) // beginAction clears the summary
        let syncing = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: action
        )
        #expect(syncing.actionSummary == nil)
    }
}
