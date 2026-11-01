import AppKit
import Foundation
import Observation
import os

extension RightPaneState {
    // Not `private` so tests can call it directly against injected
    // `ggStackSourceCommits` / `ggService` without needing a real git repo +
    // watcher.
    @MainActor
    func seedGGContext(branch: String) {
        if currentBranch != branch {
            currentBranch = branch
            ggStackCommitsKey = nil
        }
        let branchContext = ggContextProvider?(branch) ?? .inactive(reason: .policyOff)
        if branchContext.isActive || !branchContext.permitsCurrentStackQuery || !ggContext.isActive {
            if ggContext != branchContext { ggContext = branchContext }
        }
        if ggStackLoadState == .loaded {
            invalidateOlderHistoryForDisplaySourceChange()
        }
        ggStackLoadState = branchContext.permitsCurrentStackQuery ? .loading : .inactive
    }

    @MainActor
    func refreshGGStack(forceRemote: Bool = false) async {
        let snapshotGeneration = snapshotInvalidationGeneration
        ggStackRefreshGeneration &+= 1
        let refreshGeneration = ggStackRefreshGeneration
        let deferralGeneration = ggStackRefreshDeferralGeneration
        let branchContext = ggContextProvider?(currentBranch) ?? .inactive(reason: .policyOff)
        if branchContext.isActive || !branchContext.permitsCurrentStackQuery || !ggContext.isActive {
            if ggContext != branchContext { ggContext = branchContext }
        }
        reconcilePausedOperation()
        guard branchContext.permitsCurrentStackQuery else {
            if ggStackLoadState == .loaded {
                invalidateOlderHistoryForDisplaySourceChange()
            }
            ggStackCommitsKey = nil
            ggStackLoadState = .inactive
            ggStackRemoteError = nil
            ggStackRemoteEnrichmentPending = false
            ggStackRemoteMetadataCache = nil
            if ggStack != nil { ggStack = nil }
            if !ggStackDisplayCommits.isEmpty { ggStackDisplayCommits = [] }
            if GGStackSummaryStore.shared.summaries[worktree.path.path] != nil {
                GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
            }
            // Context can be inactive transiently while startup availability
            // resolves. Hide the candidate but retain its persisted marker for
            // a later active-context reconciliation.
            ggMutationCoordinator.suspendUndoCandidate()
            return
        }
        ggEffectiveConfig = GGConfigReader.effectiveConfig(repoPath: worktree.path.path)
        // `gg ls --json` reaches out to gh/glab for PR state — skip watcher-
        // driven refreshes when the branch and commit set are unchanged.
        // Explicit remote refreshes must still pick up approval and CI changes.
        // The branch is part of the key because `gg ls` answers for the
        // *current* branch — a checkout to a different branch that happens
        // to share the same commits (e.g. right after `git checkout -b`)
        // must not reuse the old branch's cached stack.
        let key = currentGGStackCommitsKey
        if !forceRemote, key == ggStackCommitsKey, ggStackRemoteEnrichmentPending {
            await enrichGGStackRemote(
                snapshotGeneration: snapshotGeneration,
                refreshGeneration: refreshGeneration
            )
        }
        guard forceRemote || key != ggStackCommitsKey else {
            await reconcileGGUndoCandidateIfNeeded()
            return
        }
        let previousStack = ggStack
        let previousDisplayCommits = ggStackDisplayCommits
        let previousKey = ggStackCommitsKey
        let previousLoadState = ggStackLoadState
        let previousSummary = GGStackSummaryStore.shared.summaries[worktree.path.path]
        let keepsPreviousPresentation = previousKey == key
            && previousLoadState == .loaded
        var publishedKey: String?
        defer {
            let retainedKey = publishedKey ?? key
            if Task.isCancelled,
               snapshotGeneration == snapshotInvalidationGeneration,
               refreshGeneration == ggStackRefreshGeneration,
               !((ggStackLoadState == .loaded || ggStackLoadState == .empty)
                 && ggStackCommitsKey == retainedKey && retainedKey == currentGGStackCommitsKey) {
                let canRestorePreviousSnapshot = previousKey == key
                    && key == currentGGStackCommitsKey
                    && (previousLoadState == .loaded || previousLoadState == .empty)
                if canRestorePreviousSnapshot {
                    invalidateOlderHistoryForDisplaySourceChange()
                    ggStack = previousStack
                    ggStackDisplayCommits = previousDisplayCommits
                    ggStackCommitsKey = previousKey
                    ggStackLoadState = previousLoadState
                    GGStackSummaryStore.shared.summaries[worktree.path.path] = previousSummary
                } else {
                    ggStack = nil
                    ggStackDisplayCommits = []
                    ggStackCommitsKey = nil
                    ggStackLoadState = .failed(
                        "Stack refresh was interrupted. Retry to load it again."
                    )
                    GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
                }
            }
        }
        if !keepsPreviousPresentation {
            invalidateOlderHistoryForDisplaySourceChange()
            ggStackLoadState = .loading
            ggStackRemoteError = nil
            ggStackRemoteEnrichmentPending = false
            ggStackCommitsKey = nil
            if ggStack != nil { ggStack = nil }
            if !ggStackDisplayCommits.isEmpty { ggStackDisplayCommits = [] }
            if GGStackSummaryStore.shared.summaries[worktree.path.path] != nil {
                GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
            }
            ggMutationCoordinator.suspendUndoCandidate()
        }
        do {
            let usesLocalSnapshot = ggCapabilities().localStackSnapshot
            var stack = try await ggService.currentStack(
                worktreePath: worktree.path.path,
                refreshRemote: !usesLocalSnapshot
            )
            if usesLocalSnapshot {
                stack = stack?.mergingRemoteMetadata(from: previousStack ?? ggStackRemoteMetadataCache)
            }
            let displayCommits: [CommitInfo]
            if let stack {
                let infos = stack.entries.isEmpty
                    ? [:]
                    : try await ggStackCommitLoader(worktree.path, stack.entries.map(\.sha))
                displayCommits = try stack.projectCommits(infos)
            } else {
                displayCommits = []
            }
            // A newer refresh, or a `markSnapshotUnknown()` invalidation,
            // superseded this one — its own `refreshGGStack` call (or the
            // invalidation's own reset) will write the current state;
            // writing here would race it with a stale result.
            if Task.isCancelled { return }
            guard snapshotGeneration == snapshotInvalidationGeneration,
                  refreshGeneration == ggStackRefreshGeneration,
                  Self.shouldPublishGGStackRefresh(
                      refreshedCommitsKey: key,
                      currentCommitsKey: currentGGStackCommitsKey
                  )
            else { return }
            let resolvedContext: GGWorktreeContext
            if branchContext.isActive {
                resolvedContext = branchContext
            } else if let stack {
                resolvedContext = .active(stackName: stack.name)
            } else {
                resolvedContext = branchContext
            }
            if ggContext != resolvedContext { ggContext = resolvedContext }
            ggStackRemoteError = nil
            if deferralGeneration == ggStackRefreshDeferralGeneration {
                ggStackRefreshDeferredUntilMutationEnds = false
            }
            ggStackCommitsKey = currentGGStackCommitsKey
            if ggStack != stack { ggStack = stack }
            ggStackDisplayCommits = displayCommits
            let stackIsEmpty = stack.map { $0.totalCommits == 0 || $0.entries.isEmpty } ?? true
            if !stackIsEmpty,
               previousLoadState != .loaded || previousDisplayCommits != displayCommits {
                invalidateOlderHistoryForDisplaySourceChange()
            }
            ggStackLoadState = stackIsEmpty ? .empty : .loaded
            let summary = stackIsEmpty ? nil : stack?.summary
            if GGStackSummaryStore.shared.summaries[worktree.path.path] != summary {
                GGStackSummaryStore.shared.summaries[worktree.path.path] = summary
            }
            ggStackRemoteMetadataCache = nil
            publishedKey = ggStackCommitsKey
            await reconcileGGUndoCandidateIfNeeded()
            guard usesLocalSnapshot else { return }

            await enrichGGStackRemote(
                snapshotGeneration: snapshotGeneration,
                refreshGeneration: refreshGeneration
            )
        } catch {
            // Keep a same-key stack visible on a transient remote failure.
            // A failed refresh for a different key cannot be rendered safely,
            // so drop it and retry on the next refresh.
            if Task.isCancelled { return }
            guard snapshotGeneration == snapshotInvalidationGeneration,
                  refreshGeneration == ggStackRefreshGeneration,
                  Self.shouldPublishGGStackRefresh(
                      refreshedCommitsKey: key,
                      currentCommitsKey: currentGGStackCommitsKey
                  )
            else { return }
            if keepsPreviousPresentation, key == currentGGStackCommitsKey {
                ggStackRemoteError = (error as? GGServiceError)?.userMessage ?? error.localizedDescription
                return
            }
            if ggContext != branchContext { ggContext = branchContext }
            ggStackCommitsKey = nil
            if ggStack != nil { ggStack = nil }
            if !ggStackDisplayCommits.isEmpty { ggStackDisplayCommits = [] }
            if GGStackSummaryStore.shared.summaries[worktree.path.path] != nil {
                GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
            }
            ggStackLoadState = .failed(
                (error as? GGServiceError)?.userMessage ?? error.localizedDescription
            )
            ggStackRemoteError = nil
            // The cached stack we just dropped belonged to a different key, so
            // the current stack identity is unknown until a refresh succeeds.
            // Hide any recovery candidate (keeping its marker) so the drawer
            // does not offer an Undo scoped to the previous stack; it is
            // rebuilt once a later reconcile validates against the new stack.
            ggMutationCoordinator.suspendUndoCandidate()
        }
    }

    private func enrichGGStackRemote(snapshotGeneration: Int, refreshGeneration: UInt) async {
        ggStackRemoteEnrichmentPending = true
        do {
            let remote = try await ggService.currentStack(worktreePath: worktree.path.path)
            if Task.isCancelled { return }
            guard snapshotGeneration == snapshotInvalidationGeneration,
                  refreshGeneration == ggStackRefreshGeneration,
                  ggStackCommitsKey == currentGGStackCommitsKey
            else { return }
            if let enriched = ggStack?.mergingRemoteMetadata(from: remote), ggStack != enriched {
                ggStack = enriched
                GGStackSummaryStore.shared.summaries[worktree.path.path] = enriched.summary
            }
            ggStackRemoteError = nil
            ggStackRemoteEnrichmentPending = false
        } catch {
            if Task.isCancelled { return }
            guard snapshotGeneration == snapshotInvalidationGeneration,
                  refreshGeneration == ggStackRefreshGeneration,
                  ggStackCommitsKey == currentGGStackCommitsKey
            else { return }
            ggStackRemoteError = (error as? GGServiceError)?.userMessage
                ?? error.localizedDescription
            ggStackRemoteEnrichmentPending = false
        }
    }

    private func reconcileGGUndoCandidateIfNeeded() async {
        let coordinator = ggMutationCoordinator
        guard !didAttemptGGUndoRestore || coordinator.hasUndoStateToReconcile else { return }
        if Self.ggUndoRecoveryIsBlockedByGenericGitOperation(
            operationInProgress: GGStackGate.operationInProgress(repoPath: worktree.path.path),
            alasGGOperationInProgress: GGStackGate.alasGGOperationInProgress(repoPath: worktree.path.path)
        ) {
            coordinator.suspendUndoCandidate()
            return
        }
        didAttemptGGUndoRestore = true
        await coordinator.restoreUndoCandidate(currentStackName: ggStack?.name)
    }

    /// Supersedes every prior stack refresh and clears its published
    /// presentation. Active callers may atomically install a replacement
    /// refresh; quiescent callers leave the state invalidated for activation.
    @MainActor
    @discardableResult
    func invalidateGGPresentation(
        startingRefresh shouldRefresh: Bool
    ) -> Task<Void, Never>? {
        // GG rewrites refs throughout mutations. Keep the last coherent stack
        // mounted until the coordinator performs its final refresh.
        if ggActionState.inFlightAction != nil, ggStackLoadState == .loaded {
            supersedeGGStackRefreshForMutation()
            deferGGStackRefreshUntilMutationEnds()
            return nil
        }
        // Advance ownership before cancellation: a direct/untracked caller may
        // ignore cancellation, but its generation guard must still reject the
        // response after this presentation is invalidated.
        ggStackRefreshGeneration &+= 1
        ggStackRefreshTask?.cancel()
        ggStackRefreshTask = nil
        invalidateOlderHistoryForDisplaySourceChange()
        ggStackCommitsKey = nil
        if ggStack != nil { ggStack = nil }
        if !ggStackDisplayCommits.isEmpty { ggStackDisplayCommits = [] }
        ggStackLoadState = ggContext.isActive ? .loading : .inactive
        ggStackRemoteError = nil
        ggStackRemoteMetadataCache = nil
        if GGStackSummaryStore.shared.summaries[worktree.path.path] != nil {
            GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
        }
        guard shouldRefresh else { return nil }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshGGStack()
        }
        ggStackRefreshTask = task
        return task
    }

    func supersedeGGStackRefreshForMutation() {
        // Retry the cancelled load even if mutation preflight fails before its final refresh.
        ggStackRefreshDeferredUntilMutationEnds = true
        ggStackRefreshGeneration &+= 1
        ggStackRefreshTask?.cancel()
        ggStackRefreshTask = nil
    }

    func deferGGStackRefreshUntilMutationEnds() {
        ggStackRefreshDeferralGeneration &+= 1
        ggStackRefreshDeferredUntilMutationEnds = true
    }

    private func scheduleDeferredGGStackRefreshIfNeeded() {
        guard ggStackRefreshDeferredUntilMutationEnds,
              ggActionState.inFlightAction == nil,
              ggExplicitStackRefreshID == nil
        else { return }
        ggStackRefreshTask?.cancel()
        ggStackRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshGGStack(forceRemote: true)
        }
    }

    /// Re-run the gg gate immediately (e.g. after a Settings toggle) rather
    /// than waiting for the next watcher-driven refresh. Forces a fresh query
    /// even when commits are unchanged while keeping a compatible loaded
    /// stack visible, then reloads or clears stack state. Returns the
    /// underlying task so tests can await completion; production call
    /// sites ignore the return value.
    /// Shared-ref refreshes verify the live branch and HEAD because the
    /// cached commit key may not yet reflect the ref notification.
    @MainActor
    @discardableResult
    func reevaluateGGGate(verifyingHead: Bool = false) -> Task<Void, Never> {
        let remoteMetadata = ggStack
        ggStackRefreshGeneration &+= 1
        let refreshGeneration = ggStackRefreshGeneration
        ggStackRefreshTask?.cancel()
        ggStackRemoteMetadataCache = remoteMetadata
        let refreshID = UUID()
        ggExplicitStackRefreshID = refreshID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.ggExplicitStackRefreshID == refreshID {
                    self.ggExplicitStackRefreshID = nil
                    if self.hasLoadedSnapshot || self.ggLocalSnapshotRecoveryTask == nil {
                        self.scheduleDeferredGGStackRefreshIfNeeded()
                    }
                }
            }
            if let recovery = self.ggLocalSnapshotRecoveryTask {
                _ = await recovery.value
                guard !Task.isCancelled else { return }
                if !verifyingHead && !self.hasLoadedSnapshot { return }
            }
            if verifyingHead {
                let cachedBranch = self.currentBranch
                let cachedHeadSHA = self.currentHeadSHA
                async let liveBranch = try? self.git.currentBranch(worktreePath: self.worktree.path)
                async let liveHeadSHA = try? self.git.resolveRevision(at: self.worktree.path, ref: "HEAD")
                let (branch, headSHA) = await (liveBranch, liveHeadSHA)
                guard !Task.isCancelled, self.ggStackRefreshGeneration == refreshGeneration else { return }
                if !self.hasLoadedSnapshot || cachedHeadSHA.isEmpty || branch != cachedBranch || headSHA != cachedHeadSHA {
                    self.markSnapshotUnknown()
                    // Invalidation cancels this GG task. A fresh task must
                    // install the local snapshot before its stack can reload.
                    let localRefresh = Task { @MainActor [weak self] in
                        await self?.refresh()
                    }
                    self.ggLocalSnapshotRecoveryTask = localRefresh
                    _ = await localRefresh.value
                    await self.ggStackRefreshTask?.value
                    return
                }
            }
            await self.refreshGGStack(forceRemote: true)
        }
        ggStackRefreshTask = task
        return task
    }

    /// Pure filesystem probe → `ggActionState.pausedOperation` sync. Runs
    /// after the GG gates pass, but only for an already-known/active GG
    /// operation. Plain git conflicts use the same marker files and must keep
    /// their regular recovery UI.
    private func reconcilePausedOperation() {
        let operationInProgress = GGStackGate.operationInProgress(repoPath: worktree.path.path)
        if !operationInProgress {
            GGStackGate.clearAlasGGOperationInProgress(repoPath: worktree.path.path)
        }
        if operationInProgress,
           ggActionState.inFlightAction != nil
               || ggActionState.pausedOperation != nil
               || GGStackGate.alasGGOperationInProgress(repoPath: worktree.path.path)
        {
            if ggActionState.pausedOperation == nil {
                ggActionState.setPaused(GGPausedOperation(pausedBy: ggActionState.inFlightAction ?? .sync))
            }
        } else {
            ggActionState.clearPaused()
        }
    }

    /// Dispatches a stack-drawer action kind to its gg mutation. `.land`
    /// stages a confirmation (see `requestGGLand`/`performGGLand`) rather
    /// than mutating directly, and `.checkout` is dispatched directly by the
    /// entry menu (Task 9) via `requestGGCheckout` instead of going through
    /// this dispatcher.
    @MainActor
    func onGGStackAction(_ kind: GGStackActionKind, appState: AppState) {
        switch kind {
        case .sync:
            runGGMutation(.sync)
        case .clean:
            requestGGCleanAll()
        case .continueOp:
            runGGMutation(.continueOperation)
        case .abortOp:
            runGGMutation(.abortOperation)
        case .checkout:
            break
        case .land:
            requestGGLand(.ready)
        case .amendCurrent:
            runGGMutation(.amendCurrent)
        case .absorbStaged:
            runGGMutation(.absorbStaged)
        case .restack:
            requestGGRestack()
        case .rebase:
            guard let stackBase = ggStack?.base else {
                ggActionState.setError("The stack base is no longer available. Refresh and try again.")
                return
            }
            runGGMutation(.rebase(target: Self.ggManualRebaseTarget(
                stackBase: stackBase,
                behindBase: behindBase
            )))
        case .reorder:
            requestGGReorder()
        case .undo:
            guard let candidate = ggUndoCandidate else { return }
            runGGMutation(.undo(operationID: candidate.operationID))
        case .drop, .unstack, .split:
            break
        }
    }

    func requestGGReorder() {
        guard let stack = ggStack,
              stack.entries.allSatisfy({ $0.ggId != nil })
        else {
            ggActionState.setError("Every stack commit needs a GG ID before it can be reordered.")
            return
        }
        let entries = stack.entries.sorted(by: { $0.position < $1.position }).map { entry in
            let id = entry.ggId!
            return entry.prState == .merged
                ? GGReorderEntry.immutable(id: id, title: entry.title)
                : GGReorderEntry.mutable(id: id, title: entry.title)
        }
        let model = GGReorderModel(entries: entries)
        Task { @MainActor in
            do {
                let prepared = try await ggMutationCoordinator.prepare(.reorder(order: model.orderedIDs))
                pendingGGReorder = GGReorderPresentation(snapshot: prepared.snapshot, model: model)
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }

    func cancelGGReorder() {
        pendingGGReorder = nil
    }

    func submitGGReorder(_ model: GGReorderModel) async throws {
        guard let pending = pendingGGReorder,
              model.hasChanges
        else { throw GGMutationError.staleConfirmation }
        try await requireCheckpointMutationAllowedAfterJournalRevalidation()
        guard mergeOp.current == nil else { throw GGMutationError.blockingGitOperation }
        try await ggMutationCoordinator.apply(
            .reorder(order: model.orderedIDs),
            confirmedAgainst: pending.snapshot
        )
        pendingGGReorder = nil
    }

    func requestGGRestack() {
        Task { @MainActor in
            do {
                pendingGGRestack = GGRestackPresentation(
                    prepared: try await ggMutationCoordinator.prepareRestackPreview()
                )
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }

    func cancelGGRestack() {
        pendingGGRestack = nil
    }

    func submitGGRestack() async throws {
        guard let pending = pendingGGRestack, pending.hasWork else {
            throw GGMutationError.staleConfirmation
        }
        try await requireCheckpointMutationAllowedAfterJournalRevalidation()
        guard mergeOp.current == nil else { throw GGMutationError.blockingGitOperation }
        // The stack identity only carries the base name + head SHA, so a base
        // ref that advanced since the preview was built would still match.
        // Re-run the dry-run plan and require it to equal the reviewed one, so
        // Apply can't rewrite against a different parent than the user saw.
        let revalidated = try await ggMutationCoordinator.prepareRestackPreview()
        guard revalidated.plan == pending.prepared.plan else {
            pendingGGRestack = GGRestackPresentation(prepared: revalidated)
            throw GGMutationError.staleConfirmation
        }
        try await requireCheckpointMutationAllowedAfterJournalRevalidation()
        try await ggMutationCoordinator.apply(.restack, confirmedAgainst: revalidated.snapshot)
        pendingGGRestack = nil
    }

    /// Stages the land confirmation from the stack already on screen so the
    /// dialog appears immediately. The forge round-trip that `gg ls` needs to
    /// re-validate the stack runs later, while the landing tab is visible —
    /// preparing first made the menu click look frozen for seconds.
    func requestGGLand(_ request: GGLandRequest) {
        guard let snapshot = cachedGGStackSnapshot,
              let stack = snapshot.stack,
              let target = Self.ggLandUntilTarget(for: request, in: stack)
        else {
            ggActionState.setError("This stack is no longer ready to land.")
            return
        }
        do {
            let prepared = try ggMutationCoordinator.prepare(.land(target: target), using: snapshot)
            guard case .land(_, let commits) = prepared.confirmation, commits > 0 else {
                throw GGMutationError.staleConfirmation
            }
            pendingGGLandPrepared = prepared
            pendingGGLand = request
        } catch {
            ggActionState.setError(GGErrorPresentation.message(for: error))
        }
    }

    func handleGGCommitAction(_ action: GGCommitAction, commit: CommitInfo, appState: AppState) {
        guard let entry = ggStack?.entry(matchingCommitSHA: commit.sha) else {
            ggActionState.setError("The stack changed. Refresh and try again.")
            return
        }

        switch action {
        case .reviewProviderRequest(let number, let url):
            guard entry.prNumber == number,
                  commitRemote?.reviewRequestURL(number: number) == url
            else {
                ggActionState.setError("The provider review changed. Refresh and try again.")
                return
            }
            Task { @MainActor in
                let response = await appState.cliOpenReview(
                    worktree: worktree,
                    target: url.absoluteString,
                    caller: .app
                )
                if let message = Self.ggProviderReviewError(response) {
                    ggActionState.setError(message)
                }
            }
        case .openProviderRequest(let number):
            guard entry.prNumber == number, let remote = commitRemote else {
                ggActionState.setError("The provider review is no longer available.")
                return
            }
            NSWorkspace.shared.open(remote.reviewRequestURL(number: number))
        case .checkout:
            requestGGCheckout(target: entry.id)
        case .splitCommit:
            guard mergeOp.current == nil else {
                ggActionState.setError("Finish the current Git operation before splitting a commit.")
                return
            }
            requestGGSplitCommit?(entry)
        case .dropCommit:
            requestGGDrop(entry)
        case .unstackHere:
            requestGGUnstack(entry)
        case .landThrough:
            requestGGLand(.until(entryId: entry.id, title: entry.title))
        }
    }

    static func ggProviderReviewError(_ response: AlasCLIResponse) -> String? {
        guard case .error(let message) = response else { return nil }
        return message
    }

    @ObservationIgnored var requestGGSplitCommit: ((GGStackEntry) -> Void)? = nil

    func loadDescription(target: GGSplitCommitTarget) async throws -> GGSplitLoadedDescription {
        guard let snapshot = cachedGGStackSnapshot,
              let identity = snapshot.identity,
              let entry = snapshot.stack?.entry(matchingCommitSHA: target.targetSHA),
              target.targetGGID == nil || entry.ggId == target.targetGGID
        else { throw GGMutationError.staleConfirmation }
        let description = try await ggService.describeSplit(
            worktreePath: worktree.path.path,
            target: target.commandTarget
        )
        return GGSplitLoadedDescription(description: description, stackIdentity: identity)
    }

    func applySplit(
        planURL: URL,
        target: GGSplitTargetIdentity,
        planToken: String,
        confirmedAgainst identity: GGStackIdentity
    ) async throws {
        try await requireCheckpointMutationAllowedAfterJournalRevalidation()
        try await ggMutationCoordinator.apply(
            .applySplit(planURL: planURL, target: target, planToken: planToken),
            confirmedAgainst: identity
        )
    }

    func requestGGDrop(_ entry: GGStackEntry) {
        do {
            guard let snapshot = cachedGGStackSnapshot else {
                throw GGMutationError.staleConfirmation
            }
            let prepared = try ggMutationCoordinator.prepare(.drop(target: entry.id), using: snapshot)
            guard case .drop(_, let descendants, let hasOpenReview) = prepared.confirmation else {
                throw GGMutationError.staleConfirmation
            }
            pendingGGDropPrepared = prepared
            pendingGGDrop = GGDropPresentation(
                target: entry.id,
                title: entry.title,
                rewrittenDescendants: descendants,
                openReviewLabel: hasOpenReview
                    ? (commitRemote?.kind.reviewRequestLabel ?? "review")
                    : nil
            )
        } catch {
            ggActionState.setError(GGErrorPresentation.message(for: error))
        }
    }

    func cancelGGDrop() {
        pendingGGDrop = nil
        pendingGGDropPrepared = nil
    }

    func performGGDrop() {
        guard !checkpointMutationsDisabled else { return }
        guard let prepared = pendingGGDropPrepared else { return }
        Task { @MainActor in
            guard await checkpointMutationAllowedAfterJournalRevalidation() else { return }
            pendingGGDrop = nil
            pendingGGDropPrepared = nil
            guard let operation = ggMutationCoordinator.startApplying(prepared) else { return }
            let actionGeneration = ggActionState.actionGeneration
            do {
                try await operation.value
            } catch let error as GGMutationError {
                switch error {
                case .immutableTarget, .staleConfirmation:
                    await refreshGGStack(forceRemote: true)
                default:
                    break
                }
                publishGGMutationPresentationError(
                    error,
                    for: prepared.request.actionKind,
                    actionGeneration: actionGeneration
                )
            } catch {
                publishGGMutationPresentationError(
                    error,
                    for: prepared.request.actionKind,
                    actionGeneration: actionGeneration
                )
            }
        }
    }

    func requestGGUnstack(_ entry: GGStackEntry) {
        let name = GGUnstackModel.derivedStackName(from: entry.title)
        let request = GGMutationRequest.unstack(
            target: entry.id,
            name: name,
            createWorktree: true
        )
        Task { @MainActor in
            do {
                let prepared = try await ggMutationCoordinator.prepare(request)
                let model = try GGUnstackModel(
                    prepared: prepared,
                    supportsKeepCurrent: GGAvailability.shared.capabilities.keepCurrentUnstack
                )
                pendingGGUnstackPrepared = prepared
                pendingGGUnstack = model
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }

    func cancelGGUnstack() {
        pendingGGUnstack = nil
        pendingGGUnstackPrepared = nil
    }

    func submitGGUnstack(_ model: GGUnstackModel) async throws -> GGUnstackSubmissionResult {
        guard let pending = pendingGGUnstack,
              let prepared = pendingGGUnstackPrepared,
              pending.id == model.id,
              let name = model.validatedStackName
        else {
            throw GGMutationError.staleConfirmation
        }
        try await requireCheckpointMutationAllowedAfterJournalRevalidation()
        let request = GGMutationRequest.unstack(
            target: model.targetID,
            name: name,
            createWorktree: model.createWorktree
        )

        let freshPrepared = try await ggMutationCoordinator.prepare(request)
        if request != prepared.request
            || freshPrepared.snapshot != prepared.snapshot
            || freshPrepared.confirmation != prepared.confirmation
        {
            let freshModel = try GGUnstackModel(
                prepared: freshPrepared,
                supportsKeepCurrent: GGAvailability.shared.capabilities.keepCurrentUnstack
            )
            pendingGGUnstackPrepared = freshPrepared
            pendingGGUnstack = freshModel
            return .reconfirm(freshModel)
        }

        pendingGGUnstackPrepared = freshPrepared
        try await requireCheckpointMutationAllowedAfterJournalRevalidation()
        try await ggMutationCoordinator.apply(freshPrepared)
        pendingGGUnstack = nil
        pendingGGUnstackPrepared = nil
        return .applied
    }

    func cancelGGLand() {
        pendingGGLand = nil
        pendingGGLandPrepared = nil
    }
    func requestGGCleanAll() {
        Task { @MainActor in
            do {
                pendingGGCleanPrepared = try await ggMutationCoordinator.prepare(.clean)
                pendingGGCleanAll = true
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }
    func cancelGGCleanAll() {
        pendingGGCleanAll = false
        pendingGGCleanPrepared = nil
    }
    func performGGCleanAll() {
        guard pendingGGCleanAll, let prepared = pendingGGCleanPrepared else { return }
        pendingGGCleanAll = false
        pendingGGCleanPrepared = nil
        runGGMutation(prepared.request, confirmedAgainst: prepared.snapshot)
    }

    /// Checks out a stack entry (`gg mv <target>`) through the shared mutation
    /// lifecycle so it gets the same gating and refresh behavior as other actions.
    @MainActor
    func requestGGCheckout(target: String) {
        runGGMutation(.checkout(target: target))
    }

    /// Pure landability check: `.ready` needs at least one mergeable commit at
    /// the bottom of the stack right now, while `.until` follows
    /// `GGLandReadiness` — with a waiting-capable gg it starts on a review
    /// nobody approved yet and lets gg poll for it.
    func ggLandTargetStillLandable(_ request: GGLandRequest, in stack: GGStack) -> Bool {
        switch request {
        case .ready:
            return !Self.ggLandReadyPrefix(in: stack).isEmpty
        case .until(let entryId, _):
            guard let target = stack.entries.first(where: { $0.id == entryId }) else { return false }
            return GGLandReadiness.canStartLand(
                target: target,
                in: stack,
                canWaitForReadiness: ggCapabilities().landJSONL
            )
        }
    }

    static func ggEntryIsReadyToLand(_ entry: GGStackEntry) -> Bool {
        GGLandReadiness.isMergeable(entry)
    }

    static func ggLandReadyPrefix(in stack: GGStack) -> [GGStackEntry] {
        var entries: [GGStackEntry] = []
        for entry in stack.entries.sorted(by: { $0.position < $1.position }) {
            if entry.prState == .merged { continue }
            guard ggEntryIsReadyToLand(entry) else { break }
            entries.append(entry)
        }
        return entries
    }

    static func ggLandStackFingerprint(_ stack: GGStack) -> String {
        let entryFingerprint = stack.entries
            .sorted(by: { $0.position < $1.position })
            .map { "\($0.position):\($0.id):\($0.sha)" }
            .joined(separator: "|")
        return "\(stack.name)|\(stack.base)|\(entryFingerprint)"
    }

    static func ggLandStackMatchesPendingConfirmation(_ stack: GGStack, fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        return ggLandStackFingerprint(stack) == fingerprint
    }

    static func ggLandUntilTarget(for request: GGLandRequest, in stack: GGStack) -> String? {
        switch request {
        case .ready:
            return ggLandReadyPrefix(in: stack).last?.id
        case .until(let entryId, _):
            return entryId
        }
    }

    static func ggLandConfirmationMessage(for request: GGLandRequest, stack: GGStack?) -> String {
        switch request {
        case .ready:
            let n = stack.map { Self.ggLandReadyPrefix(in: $0).count } ?? 0
            return "Merge \(n) approved, passing PR\(n == 1 ? "" : "s") from the bottom of the stack."
        case .until(_, let title):
            return "Land the stack up to and including \u{201C}\(title)\u{201D}."
        }
    }

    static func ggManualRebaseTarget(
        stackBase: String,
        behindBase: GitService.BehindStatus?
    ) -> String {
        guard let ref = behindBase?.ref else { return stackBase }
        if ref == stackBase { return ref }
        let components = ref.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2, components[1] == stackBase else { return stackBase }
        return ref
    }

    static func ggUndoRecoveryIsBlockedByGenericGitOperation(
        operationInProgress: Bool,
        alasGGOperationInProgress: Bool
    ) -> Bool {
        operationInProgress && !alasGGOperationInProgress
    }

    var pendingGGLandConfirmationMessage: String? {
        guard let request = pendingGGLand else { return nil }
        guard case .land(let target, let commits) = pendingGGLandPrepared?.confirmation,
              let stack = pendingGGLandPrepared?.stack,
              let entry = stack.entries.first(where: { $0.id == target || $0.sha == target })
        else {
            return Self.ggLandConfirmationMessage(for: request, stack: ggStack)
        }
        switch request {
        case .ready:
            return "Merge \(commits) approved, passing PR\(commits == 1 ? "" : "s") from the bottom of the stack."
        case .until(_, let title):
            let scope = "Land the stack up to and including \u{201C}\(title)\u{201D}."
            let waiting = GGLandReadiness.waitingEntries(upTo: entry, in: stack).count
            guard waiting > 0 else { return scope }
            let label = commitRemote?.kind.reviewRequestLabel ?? "PR"
            let subject = waiting == 1 ? "1 \(label) isn't" : "\(waiting) \(label)s aren't"
            return scope + " \(subject) ready yet — gg waits for approvals and CI, then merges in order."
        }
    }

    @MainActor
    func performGGLand(appState: AppState) {
        guard !checkpointMutationsDisabled else { return }
        guard pendingGGLand != nil, let prepared = pendingGGLandPrepared else { return }
        pendingGGLand = nil
        pendingGGLandPrepared = nil
        guard ggCapabilities().landJSONL else {
            runGGMutation(prepared.request, confirmedAgainst: prepared.snapshot)
            return
        }
        if let session = ggLandingStore.sessions[worktree.projectId],
           session.phase == .running || session.phase == .cancelling {
            appState.openGGLanding(projectId: worktree.projectId)
            return
        }
        guard case .land(let target) = prepared.request,
              let seed = ggLandingSeed(target: target, stack: prepared.stack) else { return }
        guard ggLandingStore.begin(seed) else {
            if let session = ggLandingStore.sessions[worktree.projectId],
               session.phase != .running, session.phase != .cancelling {
                ggLandingStore.startPreparation(projectId: worktree.projectId) { [self] in
                    await ggLandingStore.waitForOperation(projectId: worktree.projectId)
                    guard ggLandingStore.begin(seed) else { return }
                    startGGLanding(prepared, target: target)
                }
            }
            appState.openGGLanding(projectId: worktree.projectId)
            return
        }
        appState.openGGLanding(projectId: worktree.projectId)
        startGGLanding(prepared, target: target)
    }

    func restartGGLand(target: String) {
        let projectId = worktree.projectId
        guard let session = ggLandingStore.sessions[projectId],
              session.phase == .cancelled || session.phase == .failed || session.phase == .succeeded
        else { return }
        ggLandingStore.startPreparation(projectId: projectId) { [self] in
            await ggLandingStore.waitForOperation(projectId: projectId)
            guard !Task.isCancelled else { return }
            guard ggLandingStore.sessions[projectId]?.id == session.id else { return }
            let completedIDs = session.completedIDs.union(session.rows.compactMap { row -> String? in
                guard row.outcome?.error == nil, row.outcome != nil else { return nil }
                return row.stableID ?? row.ggId
            })
            guard ggLandingStore.begin(session.confirmedScope, completedIDs: completedIDs) else { return }
            let sessionId = ggLandingStore.sessions[projectId]?.id
            do {
                guard ggCapabilities().landJSONL else {
                    throw GGServiceError.commandFailed(stderr: "Live landing is no longer supported by gg.")
                }
                let prepared = try await ggMutationCoordinator.prepare(.land(target: target))
                try Task.checkCancellation()
                guard let stack = prepared.stack,
                      Self.ggLandingScopeMatches(
                        session.confirmedScope,
                        target: target,
                        stack: stack,
                        landedIDs: completedIDs
                      ),
                      let seed = ggLandingSeed(target: target, stack: stack)
                else { throw GGMutationError.staleConfirmation }
                guard ggLandingStore.sessions[projectId]?.id == sessionId else { return }
                ggLandingStore.reconcilePreflightSeed(seed, projectId: projectId)
                startGGLanding(prepared, target: target)
            } catch {
                guard ggLandingStore.sessions[projectId]?.id == sessionId else { return }
                ggLandingStore.fail(projectId: projectId, message: GGErrorPresentation.message(for: error))
            }
        }
    }

    private func ggLandingSeed(target: String, stack: GGStack? = nil) -> GGLandingSession.Seed? {
        guard let stack = stack ?? ggStack,
              let entry = stack.entries.first(where: { $0.id == target || $0.sha == target })
        else { return nil }
        return GGLandingSession.Seed(
            projectId: worktree.projectId, worktreeId: worktree.id,
            stack: stack.name, base: stack.base, target: target,
            rows: stack.entries.filter { $0.position <= entry.position }
                .sorted { $0.position < $1.position }
                .map {
                    GGLandingRow(
                        position: $0.position,
                        title: $0.title,
                        ggId: $0.ggId,
                        stableID: $0.id,
                        prNumber: $0.prNumber
                    )
                }
        )
    }

    private static func ggLandingScopeMatches(
        _ session: GGLandingSession.Seed,
        target: String,
        stack: GGStack,
        landedIDs: Set<String>
    ) -> Bool {
        guard target == session.target,
              stack.name == session.stack,
              stack.base == session.base,
              let targetEntry = stack.entries.first(where: { $0.id == target || $0.sha == target })
        else { return false }
        let originalIDs = session.rows.compactMap { $0.stableID ?? $0.ggId }
        guard originalIDs.count == session.rows.count,
              originalIDs.last == targetEntry.id
        else { return false }
        let currentIDs = stack.entries.sorted { $0.position < $1.position }
            .filter { $0.position <= targetEntry.position }.map(\.id)
        let remainingIDs = Set(stack.entries.map(\.id))
        let missingIDs = originalIDs.filter { !remainingIDs.contains($0) }
        guard missingIDs.allSatisfy({ landedIDs.contains($0) }) else { return false }
        return currentIDs == originalIDs.filter { remainingIDs.contains($0) }
    }

    /// The confirmation is staged against the on-screen stack, so the session's
    /// rows start out optimistic. `onPreflight` hands back the freshly
    /// re-validated stack the command will actually run against — reseed the
    /// rows from it, otherwise a row count that drifted since the last refresh
    /// makes gg's `start` event look like a different stack.
    private func startGGLanding(_ prepared: GGPreparedMutation, target: String) {
        Task { @MainActor in
            guard await checkpointMutationAllowedAfterJournalRevalidation() else {
                ggLandingStore.fail(
                    projectId: worktree.projectId,
                    message: GGErrorPresentation.message(for: GGMutationError.operationInFlight)
                )
                return
            }
            guard let operation = ggMutationCoordinator.startApplying(
                prepared.request,
                confirmedAgainst: prepared.snapshot,
                onPreflight: { [weak self] fresh in
                    guard let self,
                          let seed = self.ggLandingSeed(target: target, stack: fresh.stack)
                    else { return }
                    self.ggLandingStore.reconcilePreflightSeed(seed, projectId: self.worktree.projectId)
                }
            ) else {
                ggLandingStore.fail(
                    projectId: worktree.projectId,
                    message: GGErrorPresentation.message(for: GGMutationError.operationInFlight)
                )
                return
            }
            ggLandingStore.attach(
                projectId: worktree.projectId,
                task: completeGGMutation(operation, request: prepared.request),
                cancel: { operation.cancel() }
            )
        }
    }

    @discardableResult
    func runGGMutation(
        _ request: GGMutationRequest,
        confirmedAgainst identity: GGStackIdentity? = nil
    ) -> Task<Void, Never>? {
        guard !checkpointMutationsDisabled else { return nil }
        return Task { @MainActor in
            guard await checkpointMutationAllowedAfterJournalRevalidation() else { return }
            guard let operation = ggMutationCoordinator.startApplying(
                request,
                confirmedAgainst: identity
            ) else { return }
            _ = try? await completeGGMutation(operation, request: request).value
        }
    }

    @discardableResult
    func runGGMutation(_ prepared: GGPreparedMutation) -> Task<Void, Never>? {
        guard !checkpointMutationsDisabled else { return nil }
        return Task { @MainActor in
            guard await checkpointMutationAllowedAfterJournalRevalidation() else { return }
            guard let operation = ggMutationCoordinator.startApplying(prepared) else { return }
            _ = try? await completeGGMutation(operation, request: prepared.request).value
        }
    }

    func ggTargetForCommitPublish() -> GGStackTargetIdentity? {
        guard let stack = ggStack, !currentHeadSHA.isEmpty else { return nil }
        return .init(
            branch: currentBranch,
            stackName: stack.name,
            base: stack.base,
            expectedHeadSHA: currentHeadSHA
        )
    }

    private func readCurrentGGTargetForCommitPublish() async throws -> GGStackTargetIdentity {
        let branch = try await git.currentBranch(worktreePath: worktree.path)
        let headSHA = try await git.revParseHEAD(worktreePath: worktree.path)
        let snapshot = try await ggService.currentStackSnapshot(worktreePath: worktree.path.path)
        guard let identity = snapshot.identity else { throw GGMutationError.staleConfirmation }
        return .init(
            branch: branch,
            stackName: identity.stackName,
            base: identity.base,
            expectedHeadSHA: headSHA
        )
    }

    func validateGGTargetForCommitPublish(_ target: GGStackTargetIdentity) async throws {
        let current = try await readCurrentGGTargetForCommitPublish()
        guard target.matches(
            branch: current.branch,
            stackName: current.stackName,
            base: current.base,
            headSHA: current.expectedHeadSHA
        ) else {
            throw GGMutationError.staleConfirmation
        }
    }

    func currentGGRecoveryOperationIDForCommitPublish() async throws -> String? {
        try await ggService.currentStackSnapshot(worktreePath: worktree.path.path).operationID
    }

    func validateGGRecoveryHeadForCommitPublish(operationID: String, headSHA: String) throws {
        guard ggActionState.completedRecoveryOperation == .init(operationID: operationID, headSHA: headSHA) else {
            throw GGMutationError.staleConfirmation
        }
    }

    /// `request` is `.sync` or a scoped `.syncUntil`.
    func syncGGForCommitPublish(
        _ request: GGMutationRequest = .sync,
        target: GGStackTargetIdentity? = nil,
        markExecutionStarted: @escaping @MainActor () -> Void = {}
    ) async throws {
        try await requireCheckpointMutationAllowedAfterJournalRevalidation()
        guard let operation = ggMutationCoordinator.startApplying(
            request,
            confirmedAgainst: nil,
            expectedTarget: target,
            onExecutionStarted: markExecutionStarted
        ) else {
            throw GGMutationError.operationInFlight
        }
        try await completeGGMutation(operation, request: request).value
        if ggActionState.syncHasTerminalFailure {
            throw GGMutationError.syncTerminalFailure(message: ggActionState.lastError ?? "GG sync failed.")
        }
    }

    /// `gg rebase` onto the stack's base, the drawer's Rebase, for
    /// `stack_ship` to drop entries that already landed before it syncs.
    /// gg fetches the base and rebases onto its origin. Throws
    /// `staleConfirmation` unless the worktree is still on `expected` right
    /// before gg runs, and throws when gg stops, a conflict included; the
    /// paused operation is left for `gg continue`.
    func rebaseGGForShip(expected: GGStackIdentity) async throws {
        try await requireCheckpointMutationAllowedAfterJournalRevalidation()
        guard let operation = ggMutationCoordinator.startApplying(.rebase(target: nil), confirmedAgainst: expected) else {
            throw GGMutationError.operationInFlight
        }
        try await completeGGMutation(operation, request: .rebase(target: nil)).value
    }

    private func completeGGMutation(
        _ operation: Task<Void, Error>,
        request: GGMutationRequest
    ) -> Task<Void, Error> {
        supersedeGGStackRefreshForMutation()
        let actionGeneration = ggActionState.actionGeneration
        return Task { @MainActor in
            defer { scheduleDeferredGGStackRefreshIfNeeded() }
            do {
                try await operation.value
            } catch {
                if operation.isCancelled || error is CancellationError { throw CancellationError() }
                publishGGMutationPresentationError(
                    error,
                    for: request.actionKind,
                    actionGeneration: actionGeneration
                )
                throw error
            }
        }
    }

    private func publishGGMutationPresentationError(
        _ error: Error,
        for action: GGStackActionKind,
        actionGeneration generation: UInt
    ) {
        guard ggActionState.actionGeneration == generation else { return }
        if action == .sync { ggActionState.markSyncTerminalFailure() }
        guard ggActionState.shouldPublishError(forActionGeneration: generation, action: action) else { return }
        ggActionState.setError(GGErrorPresentation.message(for: error), for: action)
    }
}
