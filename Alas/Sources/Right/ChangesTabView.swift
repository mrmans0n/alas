import SwiftUI
import AppKit

struct ChangesTabView: View {
    @Bindable var rps: RightPaneState
    @Bindable var appState: AppState
    let onSelect: (ChangedFile) -> Void
    let onSelectCommit: (CommitInfo) -> Void
    let onEditCommit: (CommitInfo, String) -> Void
    let onReviewCommit: (CommitInfo) -> Void

    private var conflicts: [ChangedFile] {
        rps.changes.filter { $0.conflict != nil }
    }

    private var nonConflictChanges: [ChangedFile] {
        rps.changes.filter { $0.conflict == nil }
    }

    private var preparationModel: ChangesPreparationModel {
        if isGGDrawerActive {
            return ChangesPreparationModel.makeGG(
                changes: rps.changes,
                hasDraft: draftNonEmpty,
                capabilities: GGAvailability.shared.capabilities,
                hasLoadedCommit: rps.ggStack?.entries.isEmpty == false,
                mutationDisabledReason: ggPreparationMutationDisabledReason,
                newCommitDisabledReason: Self.ggNewStackCommitDisabledReason(
                    contextIsActive: rps.ggContext.isActive,
                    stackLoadState: rps.ggStackLoadState,
                    stack: rps.ggStack,
                    currentHeadSHA: rps.currentHeadSHA
                )
            )
        }
        let readiness = ReviewReadinessModel(
            snapshot: rps.reviewLoop.snapshot,
            lastError: rps.reviewLoop.lastError,
            canOpenAgentHandoff: rps.canOpenReviewLoopHandoff(appState: appState),
            inFlightAction: rps.reviewLoop.inFlightAction
        )
        return ChangesPreparationModel(
            changes: rps.changes,
            hasDraft: hasDraftTab,
            draftNonEmpty: draftNonEmpty,
            aheadCommitCount: rps.commits.count,
            local: rps.reviewLoop.snapshot?.local,
            readinessActions: readiness.actions
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                scrollContent
            }
            if isGGDrawerActive {
                GGStackDrawer(rps: rps, appState: appState)
            } else {
                ReviewLoopDrawer(
                    state: rps.reviewLoop,
                    canOpenAgentHandoff: rps.canOpenReviewLoopHandoff(appState: appState),
                    onAction: { action in rps.handleReviewReadinessAction(action, appState: appState) }
                )
            }
        }
    }

    private var isGGDrawerActive: Bool {
        Self.shouldShowGGDrawer(
            contextIsActive: rps.ggContext.isActive,
            pausedGGOperation: rps.ggActionState.pausedOperation,
            hasUndoCandidate: rps.ggUndoCandidate != nil
        )
    }

    private var ggPreparationMutationDisabledReason: String? {
        Self.ggPreparationMutationDisabledReason(
            contextIsActive: rps.ggContext.isActive,
            stackLoadState: rps.ggStackLoadState,
            pausedOperation: rps.ggActionState.pausedOperation,
            inFlightAction: rps.ggActionState.inFlightAction,
            mergeOperation: rps.mergeOp.current
        )
    }

    static func ggPreparationMutationDisabledReason(
        contextIsActive: Bool,
        stackLoadState: GGStackLoadState,
        pausedOperation: GGPausedOperation?,
        inFlightAction: GGStackActionKind?,
        mergeOperation: MergeOperation?
    ) -> String? {
        if pausedOperation != nil {
            return "Continue or abort the paused GG operation first."
        }
        if inFlightAction != nil {
            return "Another GG operation is running."
        }
        if mergeOperation != nil {
            return "Finish the current Git operation first."
        }
        guard contextIsActive else { return "A GG stack is not available." }
        switch stackLoadState {
        case .loading:
            return "Wait for the GG stack to load."
        case .failed:
            return "Retry loading the GG stack."
        case .inactive:
            return "A GG stack is not available."
        case .empty, .loaded:
            return nil
        }
    }

    static func ggNewStackCommitDisabledReason(
        contextIsActive: Bool,
        stackLoadState: GGStackLoadState,
        stack: GGStack?,
        currentHeadSHA: String
    ) -> String? {
        guard contextIsActive else { return "A GG stack is not available." }
        switch stackLoadState {
        case .empty:
            return nil
        case .loading:
            return "Wait for the GG stack to load."
        case .failed:
            return "Retry loading the GG stack."
        case .inactive:
            return "A GG stack is not available."
        case .loaded:
            break
        }
        guard let stack else { return "A GG stack is not available." }
        guard !currentHeadSHA.isEmpty,
              let head = stack.entries.max(by: { $0.position < $1.position }),
              !head.sha.isEmpty,
              currentHeadSHA.hasPrefix(head.sha) || head.sha.hasPrefix(currentHeadSHA)
        else {
            return "Checkout the stack head to create a new stack commit."
        }
        return nil
    }

    private var scrollContent: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            if let err = rps.sidebarError {
                InlineErrorStrip(
                    message: err,
                    onDismiss: { rps.sidebarError = nil }
                )
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            if let op = rps.mergeOp.current,
               Self.shouldShowGenericOperationCard(mergeOperation: op, pausedGGOperation: rps.ggActionState.pausedOperation)
            {
                OperationCard(
                    operation: op,
                    hasUnresolvedConflicts: !conflicts.isEmpty,
                    onContinue: { rps.continueOperation() },
                    onSkip: { rps.skipOperation() },
                    onAbort: { rps.abortOperation() }
                )
            }

            ConflictsSection(
                conflicts: conflicts,
                bulkInFlight: rps.bulkResolveInFlight,
                bulkReport: rps.bulkResolveReport,
                hasAgent: resolvedBulkAgent != nil,
                onSelect: { file in rps.openConflict?(file.path) },
                onUseOurs: { file in rps.useOurs(file: file) },
                onUseTheirs: { file in rps.useTheirs(file: file) },
                onKeepDeleted: { file in rps.keepDeleted(file: file) },
                onMarkResolved: { file in rps.markResolved(file: file) },
                onResolveAllWithAgent: {
                    guard let agent = resolvedBulkAgent else { return }
                    rps.resolveAllConflicts(
                        using: agent,
                        prompt: appState.config.changes.mergeBulkResolvePrompt
                    )
                },
                onCancelBulkResolve: { rps.cancelBulkResolve() },
                onDismissBulkReport: { rps.dismissBulkResolveReport() }
            )

            if Self.shouldShowChangesPreparationCard(
                preparationIsVisible: preparationModel.isVisible
            ) {
                ChangesPreparationCard(
                    model: preparationModel,
                    onReviewChanges: openReviewChangesTab,
                    onDraftCommit: openDraftTab,
                    onGGAction: handleGGPreparationAction,
                    onReviewRequestAction: { action in
                        rps.handleReviewReadinessAction(action, appState: appState)
                    }
                )
            }
            WorkingTreeSectionView(
                changes: nonConflictChanges,
                expanded: $rps.workingTreeExpanded,
                onSelect: onSelect,
                onStageAll: { rps.stageAll($0) },
                onUnstageAll: { rps.unstageAll($0) },
                onIgnore: { path, isDir, dest in
                    rps.ignore(path: path, isDirectory: isDir, destination: dest)
                },
                onDiscardAll: { rps.requestDiscardAll() },
                onDiscardFolder: { path in rps.requestDiscardFolder(path: path) },
                onOpenFile: { file in
                    appState.openFile(relativePath: file.path, worktreeId: rps.worktree.id)
                },
                onCopyRelative: { file in
                    Clipboard.copy(file.path)
                },
                onCopyFull: { file in
                    let absolute = rps.worktree.path.appendingPathComponent(file.path).path
                    Clipboard.copy(absolute)
                },
                onRevealInFinder: rps.worktree.path.isRemoteAlasPath ? nil : { file in
                    let url = rps.worktree.path.appendingPathComponent(file.path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                onCopyDiff: { file in
                    rps.copyDiff(for: file.path, renameFrom: file.renameFrom)
                },
                onViewAtHEAD: { file in
                    appState.openFileSnapshotAtHEAD(
                        relativePath: file.renameFrom ?? file.path,
                        worktreeId: rps.worktree.id
                    )
                },
                onCompareWithHEAD: { file in
                    appState.openDiffTab(
                        forFileInWorktree: rps.worktree,
                        relativePath: file.path,
                        originalPath: file.renameFrom,
                        compareWithHEAD: true
                    )
                },
                onFileHistory: { file in
                    appState.openFileHistory(
                        relativePath: file.renameFrom ?? file.path,
                        worktreeId: rps.worktree.id
                    )
                },
                onDiscardFile: { file in rps.requestDiscardFile(path: file.path) },
                onParkChanges: { rps.requestParkChanges() },
                parkChangesDisabled: rps.mergeOp.current != nil || rps.stashOperationInFlight,
                isOpenFileEnabled: { file in
                    DiffOpenFileAvailability.isAvailable(
                        worktreePath: rps.worktree.path,
                        relativePath: file.path
                    )
                }
            )
            StashesSectionView(
                stashes: rps.stashes,
                filesByRef: rps.stashFilesByRef,
                loadingRefs: rps.loadingStashRefs,
                expanded: $rps.stashesExpanded,
                expandedRefs: rps.expandedStashRefs,
                onToggleSection: { rps.stashesExpanded.toggle() },
                onToggleStash: { rps.toggleStashExpanded($0) },
                onSelectFile: { stash, file in
                    appState.openStashDiffTab(worktree: rps.worktree, stash: stash, file: file)
                },
                onApply: { rps.applyStash($0) },
                onPop: { rps.popStash($0) },
                onDrop: { rps.requestDropStash($0) }
            )
            Divider().opacity(0.4)
            CommitsSectionView(
                commits: rps.commits,
                olderCommits: rps.olderCommits,
                comparisonRef: rps.comparisonRef,
                hasMoreOlder: rps.hasMoreOlder,
                isLoadingOlder: rps.isLoadingOlder,
                behindBase: rps.showBehindBaseChip ? rps.behindBase : nil,
                behindUpstream: rps.showBehindUpstreamChip ? rps.behindUpstream : nil,
                expanded: $rps.commitsExpanded,
                baseBranch: $rps.baseBranch,
                branches: BaseBranchSelector.smartList(
                    branches: rps.availableBranches,
                    currentRef: rps.comparisonRef,
                    upstream: rps.upstreamRef,
                    recent: rps.recentBaseBranches
                ),
                isLoadingBranches: rps.isFetchingBranches,
                hasLoadedBranches: rps.hasFetchedBranches,
                onSelect: onSelectCommit,
                onCopySHA: copyCommitSHA,
                onEdit: { commit in
                    if let ref = rps.comparisonRef {
                        onEditCommit(commit, ref)
                    }
                },
                onReview: onReviewCommit,
                onLoadOlder: { Task { @MainActor in await rps.loadOlder() } },
                onSelectBaseBranch: { branch in
                    rps.selectBaseBranch(branch)
                },
                onOpenBaseBranchSelector: { Task { @MainActor in await rps.fetchBranches() } },
                rps: rps,
                ggStack: rps.ggStack,
                stackCodeHostKind: rps.commitRemote?.kind,
                onGGAction: { action, commit in
                    rps.handleGGCommitAction(action, commit: commit, appState: appState)
                }
            )
        }
    }

    static func shouldShowGenericOperationCard(
        mergeOperation: MergeOperation?,
        pausedGGOperation: GGPausedOperation?
    ) -> Bool {
        mergeOperation != nil && pausedGGOperation == nil
    }

    static func shouldShowGGDrawer(
        contextIsActive: Bool,
        pausedGGOperation: GGPausedOperation?,
        hasUndoCandidate: Bool
    ) -> Bool {
        contextIsActive || pausedGGOperation != nil || hasUndoCandidate
    }

    static func shouldShowChangesPreparationCard(
        preparationIsVisible: Bool
    ) -> Bool {
        preparationIsVisible
    }

    static func stackAction(for action: GGChangesPreparationAction) -> GGStackActionKind? {
        switch action {
        case .newStackCommit: nil
        case .amendCurrent: .amendCurrent
        case .absorbIntoStack: .absorbStaged
        }
    }

    private var hasDraftTab: Bool {
        let live = appState.tabs.tabs(forWorktree: rps.worktree.id).contains { tab in
            if case .draftCommit = tab { return true } else { return false }
        }
        if live { return true }
        return appState.tabs.stashedDraft(worktreeId: rps.worktree.id) != nil
    }

    private var draftNonEmpty: Bool {
        let live = appState.tabs.tabs(forWorktree: rps.worktree.id).first { tab in
            if case .draftCommit = tab { return true } else { return false }
        }
        if case .draftCommit(let s) = live {
            if !s.subject.isEmpty || !s.bodyText.isEmpty { return true }
        }
        if let stashed = appState.tabs.stashedDraft(worktreeId: rps.worktree.id) {
            return !stashed.subject.isEmpty || !stashed.bodyText.isEmpty
        }
        return false
    }

    private func openDraftTab() {
        _ = appState.tabs.openOrFocusDraftCommit(worktreeId: rps.worktree.id)
    }

    private func handleGGPreparationAction(_ action: GGChangesPreparationAction) {
        if action == .newStackCommit {
            _ = appState.tabs.openOrFocusDraftCommit(
                worktreeId: rps.worktree.id,
                resetAmend: true
            )
            return
        }
        guard let stackAction = Self.stackAction(for: action) else { return }
        rps.onGGStackAction(stackAction, appState: appState)
    }

    private func openReviewChangesTab() {
        _ = appState.openReviewChangesTab(for: rps.worktree)
    }

    private func copyCommitSHA(_ commit: CommitInfo) {
        Clipboard.copy(commit.sha)
    }

    /// Agent to use for the Conflicts section's bulk resolve. Mirrors the
    /// `MergeConflictTabView.resolvedAgent` precedence: respect explicit
    /// "none", prefer the user's pinned tool from Settings, fall back to
    /// any enabled agent.
    ///
    /// Filters out agents without a `bypassPermissionsFlag` because the
    /// bulk action runs the agent non-interactively (no TTY to answer
    /// write-approval prompts). Without bypass support, the agent would
    /// stall on the first file write and the run would hang until the
    /// 10-minute timeout fires. The bulk button is disabled in that
    /// case with a tooltip explaining why.
    private var resolvedBulkAgent: AgentDefinition? {
        let id = appState.config.changes.aiToolId
        if id == "none" { return nil }
        if !id.isEmpty, let agent = appState.agent(id: id) {
            return agent.bypassPermissionsFlag != nil ? agent : nil
        }
        // Fallback: pick the first ENABLED agent that also supports
        // bypass. Filtering before .first matters when the registry's
        // enabled list begins with an agent that has no bypass flag
        // (e.g. Pi) but a later one does (e.g. Claude / Codex /
        // Cursor) — without this we'd reject the first match and
        // leave bulk resolve disabled despite a usable tool being
        // available.
        return appState.agentRegistry.enabled()
            .first(where: { $0.bypassPermissionsFlag != nil })
    }
}

struct ReviewChangesTriggerSummary: Equatable {
    let fileCount: Int
    let additions: Int?
    let deletions: Int?

    static func summary(for changes: [ChangedFile]) -> ReviewChangesTriggerSummary? {
        let reviewableChanges = changes.filter { $0.conflict == nil }
        guard !reviewableChanges.isEmpty else { return nil }
        let hasDuplicatePath = Set(reviewableChanges.map(\.path)).count != reviewableChanges.count

        return ReviewChangesTriggerSummary(
            fileCount: reviewableChanges.count,
            additions: hasDuplicatePath ? nil : reviewableChanges.reduce(0) { $0 + $1.add },
            deletions: hasDuplicatePath ? nil : reviewableChanges.reduce(0) { $0 + $1.del }
        )
    }
}
