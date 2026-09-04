import Foundation
import Testing
@testable import Alas

@MainActor
struct GGStackReadinessModelTests {
    @Test func placeholderMapsActiveStackLoadStates() {
        let context = GGWorktreeContext.active(stackName: "feature")

        let loading = GGStackPlaceholderModel.make(context: context, loadState: .loading)
        #expect(loading == .init(
            title: "feature", summaryChip: "Loading", detail: nil, canRetry: false, isLoading: true
        ))
        #expect(loading?.isExpandable == false)

        let empty = GGStackPlaceholderModel.make(context: context, loadState: .empty)
        #expect(empty == .init(
            title: "feature", summaryChip: "0 commits", detail: nil, canRetry: false, isLoading: false
        ))
        #expect(empty?.isExpandable == false)

        let failed = GGStackPlaceholderModel.make(context: context, loadState: .failed("gg unavailable"))
        #expect(failed == .init(
            title: "feature", summaryChip: "Unavailable", detail: "gg unavailable", canRetry: true, isLoading: false
        ))
        #expect(failed?.isExpandable == true)
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

    @Test func projectionUsesLiveBehindBaseOnlyForMatchingStackBase() {
        let stack = stack([entry(position: 1, prState: nil)], synced: 1, behind: 0)
        let behind = GitService.BehindStatus(ref: "origin/main", sha: "abc", count: 2, probedAt: Date())

        #expect(GGStackReadinessProjection.liveBehindBaseOverride(
            stack: stack,
            selectedBaseBranch: "main",
            behindBase: behind
        ) == 2)
        #expect(GGStackReadinessProjection.liveBehindBaseOverride(
            stack: stack,
            selectedBaseBranch: "release",
            behindBase: behind
        ) == nil)
        #expect(GGStackReadinessProjection.effectiveBehindBase(
            stack: stack,
            selectedBaseBranch: "release",
            behindBase: behind
        ) == 0)
    }

    @Test func blockingGitOperationDisablesStackMutations() {
        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open, approved: true, ci: .success)]),
            action: GGStackActionState(),
            hasBlockingGitOperation: true
        )

        #expect(model.actions.allSatisfy { !$0.isEnabled })
    }

    @Test func projectionTreatsPlainGitOperationAsBlockingOnlyWhenGGIsNotPaused() {
        let operation = MergeOperation.merge(sourceBranch: "main")

        #expect(GGStackReadinessProjection.hasBlockingGitOperation(
            mergeOperation: operation,
            pausedGGOperation: nil
        ))
        #expect(!GGStackReadinessProjection.hasBlockingGitOperation(
            mergeOperation: operation,
            pausedGGOperation: GGPausedOperation(pausedBy: .sync)
        ))
        #expect(!GGStackReadinessProjection.hasBlockingGitOperation(
            mergeOperation: nil,
            pausedGGOperation: nil
        ))
    }

    @Test func sharedProjectionUsesMatchingLiveBehindAndEffectiveConfig() {
        let staleStack = stack([entry(position: 1, prState: .open)], synced: 1, behind: 0)
        let behind = GitService.BehindStatus(
            ref: "origin/main",
            sha: "abc",
            count: 2,
            probedAt: Date()
        )

        let model = GGStackReadinessProjection.make(
            stackLoadState: .loaded,
            stack: staleStack,
            action: GGStackActionState(),
            selectedBaseBranch: "main",
            behindBase: behind,
            mergeOperation: nil,
            effectiveConfig: .init(syncAutoRebase: true, syncBehindThreshold: 1),
            localChanges: .zero,
            undoCandidate: nil
        )

        #expect(model?.primaryActions.first?.kind == .sync)
        #expect(model?.primaryActions.first?.detail == "Includes rebase onto main")
        #expect(model?.facts.contains { $0.label == "Behind base" && $0.value == "2" } == true)
    }

    @Test func sharedProjectionIgnoresMismatchedLiveBehindAndAppliesBlockingGate() {
        let stack = stack([entry(position: 1, prState: nil)], synced: 1, behind: 0)
        let behind = GitService.BehindStatus(
            ref: "origin/release",
            sha: "abc",
            count: 2,
            probedAt: Date()
        )

        let model = GGStackReadinessProjection.make(
            stackLoadState: .loaded,
            stack: stack,
            action: GGStackActionState(),
            selectedBaseBranch: "release",
            behindBase: behind,
            mergeOperation: .merge(sourceBranch: "main"),
            effectiveConfig: .defaults,
            localChanges: .zero,
            undoCandidate: nil
        )

        #expect(model?.primaryActions.first?.kind == .sync)
        #expect(model?.primaryActions.first?.detail == nil)
        #expect(model?.primaryActions.first?.isEnabled == false)
        #expect(model?.facts.contains { $0.label == "Behind base" && $0.value == "0" } == true)
    }

    @Test func sharedProjectionRequiresLoadedStack() {
        let stack = stack([entry(position: 1, prState: nil)])

        #expect(GGStackReadinessProjection.make(
            stackLoadState: .loading,
            stack: stack,
            action: GGStackActionState(),
            selectedBaseBranch: "main",
            behindBase: nil,
            mergeOperation: nil,
            effectiveConfig: .defaults,
            localChanges: .zero,
            undoCandidate: nil
        ) == nil)
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

    @Test func syncWithoutEventsShowsImmediatePreparingStatus() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)

        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)], behind: 2),
            action: action,
            effectiveConfig: .init(syncAutoRebase: true, syncBehindThreshold: 1, syncAutoLint: true)
        )

        #expect(model.syncProgress?.liveStatus == "Preparing stack…")
        #expect(model.syncProgress?.showsSpinner == true)
        #expect(model.syncProgress?.steps.map(\.title) == [
            "Preparing stack",
            "Syncing commits",
            "Updating pull requests",
            "Refreshing Changes",
        ])
        #expect(
            model.syncProgress?.steps.first?.detail
                == "Checking base · Rebase onto main if needed · Run configured lint"
        )
    }

    @Test func restoredPausedSyncDoesNotShowAnActivePhase() throws {
        let action = GGStackActionState()
        action.setPaused(GGPausedOperation(pausedBy: .sync))

        let progress = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]),
            action: action
        ).syncProgress)

        #expect(progress.liveStatus == nil)
        #expect(progress.showsSpinner == false)
        #expect(progress.steps.allSatisfy { $0.state == .pending })
    }

    @Test func syncProgressUpdatesOneStableRowPerPosition() throws {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.start(totalEntries: 2))
        action.appendSyncEvent(.entryStarted(position: 2, title: "Second"))
        action.appendSyncEvent(.pushDone(position: 2, forced: false))
        action.appendSyncEvent(.prUpdated(position: 2, prNumber: 22, action: "updated"))
        action.appendSyncEvent(.entryStarted(position: 1, title: "First"))
        action.appendSyncEvent(.pushDone(position: 1, forced: false))
        action.appendSyncEvent(.prCreated(position: 1, prNumber: 11, prURL: nil, draft: false))

        let progress = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: nil), entry(position: 2, prState: nil)]),
            action: action
        ).syncProgress)
        #expect(progress.rows == [
            .init(position: 1, text: "[1] Pushed · PR #11 created"),
            .init(position: 2, text: "[2] Pushed · PR #22 updated"),
        ])
        #expect(progress.liveStatus == "Syncing 2 of 2 commits…")
        #expect(progress.steps.filter { $0.state == .current }.map(\.id) == ["commits"])
    }

    @Test func prUpdatedMapsKnownActionsAndUsesNeutralFallback() throws {
        let cases = [
            ("updated", "[1] PR #7 updated"),
            ("unchanged", "[1] PR #7 up to date"),
            ("up_to_date", "[1] PR #7 up to date"),
            ("recreated", "[1] PR #7 recreated"),
            ("future_action", "[1] PR #7"),
        ]

        for (reportedAction, expectedRow) in cases {
            let action = GGStackActionState()
            _ = action.beginAction(.sync)
            action.appendSyncEvent(.prUpdated(position: 1, prNumber: 7, action: reportedAction))
            let progress = try #require(GGStackReadinessModel.make(
                stack: stack([entry(position: 1, prState: .open)]), action: action
            ).syncProgress)
            #expect(progress.rows == [.init(position: 1, text: expectedRow)])
        }
    }

    @Test func createdAndClosedPRRowsOnlyClaimPushWhenObserved() throws {
        let created = GGStackActionState()
        _ = created.beginAction(.sync)
        created.appendSyncEvent(.prCreated(position: 1, prNumber: 7, prURL: nil, draft: false))
        let createdProgress = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: created
        ).syncProgress)
        #expect(createdProgress.rows == [.init(position: 1, text: "[1] PR #7 created")])

        let closed = GGStackActionState()
        _ = closed.beginAction(.sync)
        closed.appendSyncEvent(.pushDone(position: 1, forced: false))
        closed.appendSyncEvent(.prSkippedClosed(position: 1, prNumber: 7))
        let progress = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: closed
        ).syncProgress)
        #expect(progress.rows == [.init(position: 1, text: "[1] Pushed · PR #7 already closed")])
    }

    @Test func positionalErrorCountsAsProcessedAndLaterEntryKeepsProgressLive() throws {
        let failed = GGStackActionState()
        _ = failed.beginAction(.sync)
        failed.appendSyncEvent(.start(totalEntries: 2))
        failed.appendSyncEvent(.error(position: 1, operation: "push", message: "push failed"))
        let afterError = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: failed
        ).syncProgress)
        #expect(afterError.rows == [.init(position: 1, text: "[1] Failed to push")])
        #expect(afterError.liveStatus == "Syncing 1 of 2 commits…")
        #expect(afterError.showsSpinner)

        failed.appendSyncEvent(.entryStarted(position: 2, title: "Second"))
        let afterNextEntry = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: failed
        ).syncProgress)
        #expect(afterNextEntry.liveStatus == "Syncing [2] Second…")
        #expect(afterNextEntry.showsSpinner)
    }

    @Test func summaryEntryErrorDoesNotDowngradeEarlierPushFailure() throws {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.error(position: 1, operation: "push", message: "push failed"))
        action.appendSyncEvent(.error(position: 1, operation: nil, message: "push failed"))
        action.appendSyncEvent(.summary)

        let progress = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: action
        ).syncProgress)
        #expect(progress.rows == [.init(position: 1, text: "[1] Failed to push")])
        #expect(progress.liveStatus == nil)
        #expect(!progress.showsSpinner)
        #expect(progress.steps.map(\.state) == [.complete, .failed, .pending, .pending])
    }

    @Test func pausedOnSyncKeepsProgressAndOffersContinueAbort() throws {
        // Reproduces the exact state a rebase conflict during `gg sync` leaves
        // behind: syncProgress is non-empty AND the operation is paused. The
        // model must report both facts simultaneously so the drawer can show
        // the progress list *and* still surface Continue/Abort.
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.start(totalEntries: 1))
        action.appendSyncEvent(.pushDone(position: 1, forced: false))
        action.endAction(.sync) // sync's gg process exits when it hits the conflict
        action.setPaused(GGPausedOperation(pausedBy: .sync)) // watcher-driven filesystem probe picks up the pause
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: .open)]), action: action)
        #expect(model.isPaused)
        #expect(model.primaryActions.map(\.kind) == [.continueOp, .abortOp])
        let progress = try #require(model.syncProgress)
        #expect(progress.rows == [.init(position: 1, text: "[1] Pushed")])
        #expect(progress.liveStatus == nil)
        #expect(!progress.showsSpinner)
    }

    @Test func terminalSummaryMovesToChangesRefresh() throws {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.start(totalEntries: 1))
        action.appendSyncEvent(.prCreated(position: 1, prNumber: 7, prURL: nil, draft: false))
        action.appendSyncEvent(.summary)
        let model = GGStackReadinessModel.make(stack: stack([entry(position: 1, prState: .open)]), action: action)
        let progress = try #require(model.syncProgress)
        #expect(progress.liveStatus == "Refreshing Changes…")
        #expect(progress.showsSpinner)
    }

    @Test func summaryOnlySyncCompletesEveryPhaseBeforeRefresh() throws {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.summary)

        let progress = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]),
            action: action
        ).syncProgress)

        #expect(progress.steps.map(\.state) == [.complete, .complete, .complete, .current])
        #expect(progress.steps[1].detail == "Commit sync complete")
        #expect(progress.steps[2].detail == "Pull request updates complete")
    }

    @Test func postSummaryCommandFailureKeepsFailedSyncPhase() throws {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.summary)
        action.markSyncTerminalFailure()
        action.setError("sync exited unsuccessfully")
        action.endAction(.sync)

        let progress = try #require(GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]),
            action: action
        ).syncProgress)

        #expect(progress.steps.map(\.state) == [.complete, .failed, .pending, .pending])
    }

    @Test func idleFailedSyncRetainsProgressWhileLastErrorIsSet() throws {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.pushDone(position: 1, forced: false))
        action.appendSyncEvent(.error(position: 1, operation: "push", message: "push failed"))
        action.setError("push failed")
        action.endAction(.sync)

        let model = GGStackReadinessModel.make(
            stack: stack([entry(position: 1, prState: .open)]), action: action
        )
        let progress = try #require(model.syncProgress)
        #expect(progress.rows == [.init(position: 1, text: "[1] Failed to push")])
        #expect(progress.liveStatus == nil)
        #expect(!progress.showsSpinner)
        #expect(model.isRetainedSyncFailure)
        #expect(!model.primaryActions.isEmpty)
        #expect(!model.facts.isEmpty)
    }

    @Test func dismissingCompletedSyncFailureClearsRetainedFeedback() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.markSyncTerminalFailure()
        action.endAction(.sync)
        action.setError("push failed", for: .sync)

        action.dismissCompletedSyncFailure()

        #expect(action.syncProgress.isEmpty)
        #expect(!action.syncHasTerminalFailure)
        #expect(action.lastError == nil)
    }

    @Test func unrelatedErrorDuringSyncCannotBeDismissedAsASyncFailure() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.setError("provider failed")
        action.endAction(.sync)

        #expect(!action.canDismissCompletedSyncFailure)
        action.dismissCompletedSyncFailure()
        #expect(action.lastError == "provider failed")
    }

    @Test func dismissingSyncFailureKeepsALaterUnrelatedError() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.markSyncTerminalFailure()
        action.appendSyncEvent(.start(totalEntries: 1))
        action.setError("sync failed", for: .sync)
        action.endAction(.sync)
        action.setError("provider failed")

        #expect(action.canDismissCompletedSyncFailure)
        action.dismissCompletedSyncFailure()

        #expect(action.syncProgress.isEmpty)
        #expect(!action.syncHasTerminalFailure)
        #expect(action.lastError == "provider failed")
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
