import SwiftUI

struct ChangesTabView: View {
    @Bindable var rps: RightPaneState
    @Bindable var appState: AppState
    let onSelect: (ChangedFile) -> Void
    let onSelectCommit: (CommitInfo) -> Void
    let onEditCommit: (CommitInfo, String) -> Void
    let onReviewCommit: (CommitInfo) -> Void

    @State private var collapsedChangePaths: Set<String> = []
    @State private var appKitActionRelay = ChangesAppKitActionRelay()
    @State private var amendProbe = CommitPublishAmendProbeLoader()
    @Environment(\.theme) private var theme

    private var conflicts: [ChangedFile] {
        rps.changes.filter { $0.conflict != nil }
    }

    private var nonConflictChanges: [ChangedFile] {
        rps.displayChanges.filter { $0.conflict == nil }
    }

    private var preparationModel: ChangesPreparationModel {
        if isGGDrawerActive {
            return ChangesPreparationModel.makeGG(
                changes: rps.changes,
                hasDraft: draftNonEmpty,
                capabilities: GGAvailability.shared.capabilities,
                hasLoadedCommit: rps.ggStackLoadState.hasLoadedCommit,
                mutationDisabledReason: ggPreparationMutationDisabledReason,
                inFlightAction: rps.ggActionState.inFlightAction,
                newCommitDisabledReason: Self.ggNewStackCommitDisabledReason(
                    contextIsActive: rps.ggContext.isActive,
                    stackLoadState: rps.ggStackLoadState,
                    stack: rps.ggStack,
                    currentHeadSHA: rps.currentHeadSHA
                ),
                mutationError: rps.ggActionState.lastError,
                reconciliationAction: Self.reconciliationAction(from: ggReadinessModel),
                syncProgress: GGStackReadinessModel.syncProgress(
                    action: rps.ggActionState,
                    base: rps.ggStack?.base ?? rps.baseBranch,
                    behindBase: rps.ggStack.map {
                        GGStackReadinessProjection.effectiveBehindBase(
                            stack: $0,
                            selectedBaseBranch: rps.baseBranch,
                            behindBase: rps.behindBase
                        )
                    } ?? rps.behindBase?.count ?? 0,
                    effectiveConfig: rps.ggEffectiveConfig
                ),
                canDismissSyncFailure: rps.ggActionState.canDismissCompletedSyncFailure
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
            readinessActions: readiness.actions,
            publishAvailability: CommitPublishAvailability.review(
                snapshot: rps.reviewLoop.snapshot,
                supportedRemote: rps.commitRemote ?? rps.primaryCommitRemote,
                isRefreshing: rps.reviewLoop.isRefreshing,
                currentBranch: rps.currentBranch,
                currentBaseBranch: rps.baseBranch,
                lastError: rps.reviewLoop.lastError,
                mutationDisabledReason: publishMutationDisabledReason,
                amend: currentDraft?.amend == true,
                amendProbe: amendProbe.result(for: amendProbeKey)
            )
        )
    }

    var body: some View {
        let _ = appKitActionRelay.update(
            onSelectFile: onSelect,
            onSelectCommit: onSelectCommit,
            onEditCommit: onEditCommit,
            onReviewCommit: onReviewCommit
        )
        VStack(spacing: 0) {
            AppKitDiffScroller(
                plan: appKitScrollPlan,
                scrollRequest: nil,
                onActiveOwnerChange: { _ in },
                onScrollRequestCompletion: { _ in }
            )
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
        .task(id: amendProbeKey) {
            let key = amendProbeKey
            guard currentDraft?.amend == true, !isGGDrawerActive else { return }
            await amendProbe.load(key: key) {
                try await GitService().headPublicationState(worktreePath: rps.worktree.path)
            }
        }
    }

    private var publishMutationDisabledReason: String? {
        if rps.mergeOp.current != nil { return "Finish the current Git operation first." }
        if rps.reviewLoop.inFlightAction != nil || rps.pullInFlight || rps.stashOperationInFlight {
            return "Another Git operation is running."
        }
        return nil
    }

    private var amendProbeKey: String {
        Self.amendPublicationProbeKey(
            worktreeID: rps.worktree.id, branch: rps.currentBranch, headSHA: rps.currentHeadSHA,
            amend: currentDraft?.amend == true, ggModeActive: isGGDrawerActive,
            reviewLoop: rps.reviewLoop
        )
    }

    static func amendPublicationProbeKey(
        worktreeID: String, branch: String, headSHA: String, amend: Bool,
        ggModeActive: Bool, reviewLoop: ReviewLoopState
    ) -> String {
        [worktreeID, branch, headSHA, String(amend), String(ggModeActive),
         String(reviewLoop.refreshGeneration),
         String(reflecting: reviewLoop.snapshot?.local)].joined(separator: "\u{0}")
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

    private var ggReadinessModel: GGStackReadinessModel? {
        GGStackReadinessProjection.make(
            stackLoadState: rps.ggStackLoadState,
            stack: rps.ggStack,
            action: rps.ggActionState,
            selectedBaseBranch: rps.baseBranch,
            behindBase: rps.behindBase,
            mergeOperation: rps.mergeOp.current,
            effectiveConfig: rps.ggEffectiveConfig,
            localChanges: rps.ggLocalChangeStatistics,
            undoCandidate: rps.ggUndoCandidate
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

    static func reconciliationAction(
        from readiness: GGStackReadinessModel?
    ) -> GGStackReadinessModel.Action? {
        readiness?.primaryActions.first {
            $0.kind == .sync || $0.kind == .rebase
        }
    }

    private var appKitScrollPlan: AppKitDiffRowPlan {
        let preparation = preparationModel
        let workingTree = workingTreeSection
        let workingGroups = WorkingTreeChangeGroup.group(files: nonConflictChanges)
        let workingGroupsSignature = String(reflecting: workingGroups).hashValue
        let groupsByPath = Dictionary(uniqueKeysWithValues: workingGroups.map { ($0.path, $0) })
        let commits = commitsSection
        var rows: [AppKitDiffRowSpec] = []

        if let error = rps.sidebarError {
            rows.append(appKitRow(id: "changes-error", token: error, estimatedHeight: 38) {
                InlineErrorStrip(message: error, onDismiss: { rps.sidebarError = nil })
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            })
        }

        if let operation = rps.mergeOp.current,
           Self.shouldShowGenericOperationCard(
            mergeOperation: operation,
            pausedGGOperation: rps.ggActionState.pausedOperation
           ) {
            rows.append(appKitRow(
                id: "changes-operation",
                token: String(reflecting: operation) + String(!conflicts.isEmpty),
                estimatedHeight: 110
            ) {
                OperationCard(
                    operation: operation,
                    hasUnresolvedConflicts: !conflicts.isEmpty,
                    onContinue: { rps.continueOperation() },
                    onSkip: { rps.skipOperation() },
                    onAbort: { rps.abortOperation() }
                )
            })
        }

        if !conflicts.isEmpty || rps.bulkResolveInFlight || rps.bulkResolveReport != nil {
            let token = String(reflecting: conflicts)
                + String(reflecting: rps.bulkResolveInFlight)
                + String(reflecting: rps.bulkResolveReport)
                + String(reflecting: resolvedBulkAgent)
                + appState.config.changes.mergeBulkResolvePrompt
            rows.append(appKitRow(id: "changes-conflicts", token: token, estimatedHeight: 120) {
                ConflictsSection(
                    conflicts: conflicts,
                    bulkInFlight: rps.bulkResolveInFlight,
                    bulkReport: rps.bulkResolveReport,
                    hasAgent: resolvedBulkAgent != nil,
                    onSelect: { file in rps.openConflict?(file.path) },
                    onUseOurs: { rps.useOurs(file: $0) },
                    onUseTheirs: { rps.useTheirs(file: $0) },
                    onKeepDeleted: { rps.keepDeleted(file: $0) },
                    onMarkResolved: { rps.markResolved(file: $0) },
                    onResolveAllWithAgent: {
                        guard let agent = resolvedBulkAgent else { return }
                        rps.resolveAllConflicts(
                            using: agent,
                            prompt: appState.config.changes.mergeBulkResolvePrompt
                        )
                    },
                    onCancelBulkResolve: { rps.cancelBulkResolve() },
                    onDismissBulkReport: { rps.dismissBulkResolveReport() },
                    dragPayload: { file in
                        .workingTreeFile(worktreePath: rps.worktree.path, relativePath: file.path)
                    }
                )
            })
        }

        if Self.shouldShowChangesPreparationCard(preparationIsVisible: preparation.isVisible) {
            rows.append(appKitRow(
                id: "changes-preparation",
                token: String(reflecting: preparation),
                estimatedHeight: 92
            ) {
                ChangesPreparationCard(
                    model: preparation,
                    onReviewChanges: openReviewChangesTab,
                    onDraftCommit: openDraftTab,
                    onPublishCommit: openPublishTab,
                    onGGAction: handleGGPreparationAction,
                    onGGStackAction: { rps.onGGStackAction($0, appState: appState) },
                    onReviewRequestAction: { rps.handleReviewReadinessAction($0, appState: appState) },
                    onDismissSyncFailure: { rps.ggActionState.dismissCompletedSyncFailure() }
                )
            })
        }

        rows.append(appKitRow(
            id: "working-tree-header",
            token: "\(workingGroupsSignature)-\(rps.workingTreeExpanded)-\(rps.mergeOp.current != nil)-\(rps.stashOperationInFlight)",
            estimatedHeight: 32,
            retention: .sticky
        ) { workingTree.headerRow })

        if rps.workingTreeExpanded {
            if workingGroups.isEmpty {
                rows.append(appKitRow(id: "working-tree-empty", token: 0, estimatedHeight: 32) {
                    ChangesEmptyRow(text: "no changes")
                })
            } else {
                for row in WorkingTreeFlatRow.make(
                    groups: workingGroups,
                    collapsedPaths: collapsedChangePaths
                ) {
                    rows.append(appKitRow(
                        id: "working-tree-\(row.id)",
                        token: String(reflecting: row)
                            + (row.node.kind == .dir
                                ? String(workingGroupsSignature)
                                : String(reflecting: groupsByPath[row.node.path])),
                        estimatedHeight: 28
                    ) {
                        WorkingTreeFlatRowView(
                            row: row,
                            groups: workingGroups,
                            groupsByPath: groupsByPath,
                            collapsedPaths: $collapsedChangePaths,
                            actions: workingTree.rowActions
                        )
                    })
                }
            }
        }

        appendStashRows(to: &rows)
        rows.append(appKitRow(id: "changes-commit-divider", token: 0, estimatedHeight: 1) {
            Divider().opacity(0.4)
        })
        appendCommitRows(commits, to: &rows)
        return AppKitDiffRowPlan(rows: rows)
    }

    private func appendStashRows(to rows: inout [AppKitDiffRowSpec]) {
        guard !rps.stashes.isEmpty else { return }
        rows.append(appKitRow(
            id: "stashes-header",
            token: String(reflecting: rps.stashes) + String(rps.stashesExpanded),
            estimatedHeight: 32,
            retention: .sticky
        ) {
            SectionHeader(
                role: .stashes,
                title: "Stashes",
                count: rps.stashes.count,
                expanded: rps.stashesExpanded,
                onToggle: { rps.stashesExpanded.toggle() }
            )
        })
        guard rps.stashesExpanded else { return }

        for stash in rps.stashes {
            let isOpen = rps.expandedStashRefs.contains(stash.ref)
            let isLoading = rps.loadingStashRefs.contains(stash.ref)
            rows.append(appKitRow(
                id: "stash-\(stash.ref)",
                token: String(reflecting: stash) + String(isOpen) + String(isLoading),
                estimatedHeight: 32
            ) {
                StashSummaryRow(
                    stash: stash,
                    open: isOpen,
                    loading: isLoading,
                    onToggle: { rps.toggleStashExpanded(stash) },
                    onApply: { rps.applyStash(stash) },
                    onPop: { rps.popStash(stash) },
                    onDrop: { rps.requestDropStash(stash) }
                )
            })
            guard isOpen else { continue }
            let files = rps.stashFilesByRef[stash.ref] ?? []
            if files.isEmpty {
                rows.append(appKitRow(
                    id: "stash-\(stash.ref)-empty",
                    token: isLoading,
                    estimatedHeight: 32
                ) { StashEmptyRow(loading: isLoading) })
            } else {
                for file in files {
                    rows.append(appKitRow(
                        id: "stash-\(stash.ref)-file-\(file.id)",
                        token: file,
                        estimatedHeight: 30
                    ) {
                        StashFileRow(
                            file: file,
                            onSelect: {
                                appState.openStashDiffTab(worktree: rps.worktree, stash: stash, file: file)
                            },
                            dragPayload: {
                                .stashFile(worktreePath: rps.worktree.path, stash: stash, file: file)
                            }
                        )
                    })
                }
            }
        }
    }

    private func appendCommitRows(
        _ section: CommitsSectionView,
        to rows: inout [AppKitDiffRowSpec]
    ) {
        let commits = rps.commitsForDisplay
        let older = rps.olderCommits
        let rowStateToken = commitRowsStateToken
        rows.append(appKitRow(
            id: "commits-header",
            token: commitHeaderToken,
            estimatedHeight: 32,
            retention: .sticky
        ) { section.headerRow })
        guard rps.commitsExpanded else { return }

        for commit in commits {
            let isLast = commit.id == commits.last?.id && older.isEmpty
            rows.append(appKitRow(
                id: "commit-primary-\(commit.sha)",
                token: String(reflecting: commit) + rowStateToken + Self.commitRowTerminalToken(isLast: isLast),
                estimatedHeight: 64
            ) { section.primaryCommitRow(commit) })
        }
        if commits.isEmpty && older.isEmpty {
            let text = rps.comparisonRef.map { "up to date with \($0)" } ?? "no comparison branch"
            rows.append(appKitRow(id: "commits-empty", token: text, estimatedHeight: 32) {
                CommitHistoryEmptyRow(text: text)
            })
        }
        if !older.isEmpty, let comparisonRef = rps.comparisonRef {
            rows.append(appKitRow(id: "commits-boundary", token: comparisonRef, estimatedHeight: 32) {
                CommitHistoryDividerRow(label: comparisonRef)
            })
        }
        for commit in older {
            let isLast = commit.id == older.last?.id
            rows.append(appKitRow(
                id: "commit-older-\(commit.sha)",
                token: String(reflecting: commit) + rowStateToken + Self.commitRowTerminalToken(isLast: isLast),
                estimatedHeight: 64
            ) { section.historicalCommitRow(commit) })
        }
        if rps.isLoadingOlder || (rps.hasMoreOlder && rps.ggStackLoadState != .loading) || !older.isEmpty {
            rows.append(appKitRow(
                id: "commits-footer",
                token: "\(rps.isLoadingOlder)-\(rps.hasMoreOlder)-\(rps.ggStackLoadState)-\(older.isEmpty)",
                estimatedHeight: 32
            ) {
                CommitHistoryFooterRow(
                    isLoading: rps.isLoadingOlder,
                    canLoadMore: rps.hasMoreOlder && rps.ggStackLoadState != .loading,
                    hasOlderCommits: !older.isEmpty,
                    onLoadOlder: { Task { @MainActor in await rps.loadOlder() } }
                )
            })
        }
    }

    private var commitHeaderToken: String {
        String(rps.commitsExpanded)
            + String(reflecting: rps.ggStack)
            + String(rps.showBehindBaseChip)
            + String(rps.showBehindUpstreamChip)
            + String(reflecting: rps.behindBase)
            + String(reflecting: rps.behindUpstream)
            + rps.baseBranch
            + String(reflecting: rps.availableBranches)
            + String(reflecting: rps.comparisonRef)
            + String(reflecting: rps.upstreamRef)
            + String(reflecting: rps.recentBaseBranches)
            + String(rps.isFetchingBranches)
            + String(rps.hasFetchedBranches)
            + String(rps.pullInFlight)
            + String(reflecting: rps.mergeOp.current)
            + Self.commitHeaderCountsToken(
                primary: rps.commitsForDisplay.count,
                older: rps.olderCommits.count
            )
    }

    static func commitHeaderCountsToken(primary: Int, older: Int) -> String {
        "\(primary):\(older)"
    }

    static func commitRowTerminalToken(isLast: Bool) -> String {
        String(isLast)
    }

    private var commitRowsStateToken: String {
        Self.commitRowsStateToken(
            ggStack: rps.ggStack,
            ggModeActive: rps.ggContext.isActive,
            comparisonRef: rps.comparisonRef,
            ggCapabilities: GGAvailability.shared.capabilities,
            inFlightAction: rps.ggActionState.inFlightAction,
            pausedOperation: rps.ggActionState.pausedOperation,
            mergeOperation: rps.mergeOp.current,
            selectionIsStale: rps.ggCommitSelectionIsStale,
            commitsNeedPush: rps.commitsNeedPush,
            commitRemote: rps.commitRemote,
            primaryCommitRemote: rps.primaryCommitRemote
        )
    }

    static func commitRowsStateToken(
        ggStack: GGStack?,
        ggModeActive: Bool,
        comparisonRef: String? = nil,
        ggCapabilities: GGCapabilities = GGCapabilities(structuredSplit: false, keepCurrentUnstack: false),
        inFlightAction: GGStackActionKind?,
        pausedOperation: GGPausedOperation?,
        mergeOperation: MergeOperation?,
        selectionIsStale: Bool,
        commitsNeedPush: Bool,
        commitRemote: CodeHostRemote?,
        primaryCommitRemote: CodeHostRemote?
    ) -> String {
        String(reflecting: ggStack)
            + String(ggModeActive)
            + String(reflecting: comparisonRef)
            + String(reflecting: ggCapabilities)
            + String(reflecting: inFlightAction)
            + String(reflecting: pausedOperation)
            + String(reflecting: mergeOperation)
            + String(selectionIsStale)
            + String(commitsNeedPush)
            + String(reflecting: commitRemote)
            + String(reflecting: primaryCommitRemote)
    }

    private func appKitRow<Token: Equatable, Content: View>(
        id: String,
        token: Token,
        estimatedHeight: CGFloat,
        retention: AppKitDiffRowRetention = .recyclable,
        @ViewBuilder content: @escaping () -> Content
    ) -> AppKitDiffRowSpec {
        AppKitDiffRowSpec(
            id: id,
            ownerID: nil,
            equalityToken: .init(ChangesAppKitRowToken(value: token, theme: theme)),
            contentSignature: id.hashValue,
            estimatedHeight: estimatedHeight,
            retention: retention
        ) {
            AnyView(content().environment(\.theme, theme))
        }
    }

    private var workingTreeSection: WorkingTreeSectionView {
        WorkingTreeSectionView(
            changes: nonConflictChanges,
            expanded: $rps.workingTreeExpanded,
            collapsedChangePaths: $collapsedChangePaths,
            onSelect: { appKitActionRelay.onSelectFile($0) },
            fileContextTarget: { file in
                FileContextMenuTarget.resolve(
                    kind: .file,
                    worktreePath: rps.worktree.path,
                    relativePath: file.path
                )
            },
            onStageAll: { rps.stageAll($0) },
            onUnstageAll: { rps.unstageAll($0) },
            onIgnore: { path, isDir, destination in
                rps.ignore(path: path, isDirectory: isDir, destination: destination)
            },
            onDiscardAll: { rps.requestDiscardAll() },
            onDiscardFolder: { rps.requestDiscardFolder(path: $0) },
            onOpenFile: { file in
                appState.openFile(relativePath: file.path, worktreeId: rps.worktree.id)
            },
            onCopyRelative: { Clipboard.copy($0.path) },
            onCopyFull: { file in
                Clipboard.copy(rps.worktree.path.appendingPathComponent(file.path).path)
            },
            onCopyDiff: { rps.copyDiff(for: $0.path, renameFrom: $0.renameFrom) },
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
            onDiscardFile: { rps.requestDiscardFile(path: $0.path) },
            onStashChanges: { rps.requestStashChanges() },
            stashChangesDisabled: rps.mergeOp.current != nil || rps.stashOperationInFlight,
            isOpenFileEnabled: { file in
                DiffOpenFileAvailability.isAvailable(
                    worktreePath: rps.worktree.path,
                    relativePath: file.path
                )
            },
            dragPayload: { file in
                .workingTreeFile(worktreePath: rps.worktree.path, relativePath: file.path)
            }
        )
    }

    private var commitsSection: CommitsSectionView {
        CommitsSectionView(
            commits: rps.commitsForDisplay,
            olderCommits: rps.olderCommits,
            comparisonRef: rps.comparisonRef,
            hasMoreOlder: rps.hasMoreOlder && rps.ggStackLoadState != .loading,
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
            onSelect: { appKitActionRelay.onSelectCommit($0) },
            onCopySHA: copyCommitSHA,
            onEdit: { commit in
                if let comparisonRef = rps.comparisonRef {
                    appKitActionRelay.onEditCommit(commit, comparisonRef)
                }
            },
            onReview: { appKitActionRelay.onReviewCommit($0) },
            onLoadOlder: { Task { @MainActor in await rps.loadOlder() } },
            onSelectBaseBranch: { rps.selectBaseBranch($0) },
            onOpenBaseBranchSelector: { Task { @MainActor in await rps.fetchBranches() } },
            rps: rps,
            ggStack: rps.ggStack,
            stackCodeHostKind: rps.commitRemote?.kind,
            onGGAction: { action, commit in
                rps.handleGGCommitAction(action, commit: commit, appState: appState)
            }
        )
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
        case .newStackCommit, .commitAndSync: nil
        case .amendCurrent: .amendCurrent
        case .absorbIntoStack: .absorbStaged
        }
    }

    static func draftPreferredAction(for action: GGChangesPreparationAction) -> DraftCommitPreferredAction? {
        switch action {
        case .newStackCommit: .commit
        case .commitAndSync: .publish
        case .amendCurrent, .absorbIntoStack: nil
        }
    }

    private var currentDraft: DraftCommitTabState? {
        for tab in appState.tabs.tabs(forWorktree: rps.worktree.id) {
            if case .draftCommit(let state) = tab { return state }
        }
        return appState.tabs.stashedDraft(worktreeId: rps.worktree.id)
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
        _ = appState.tabs.openOrFocusDraftCommit(worktreeId: rps.worktree.id, preferredAction: .commit)
    }

    private func openPublishTab() {
        _ = appState.tabs.openOrFocusDraftCommit(worktreeId: rps.worktree.id, preferredAction: .publish)
    }

    private func handleGGPreparationAction(_ action: GGChangesPreparationAction) {
        if let preferredAction = Self.draftPreferredAction(for: action) {
            _ = appState.tabs.openOrFocusDraftCommit(
                worktreeId: rps.worktree.id,
                resetAmend: true,
                preferredAction: preferredAction
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

@MainActor
final class ChangesAppKitActionRelay {
    var onSelectFile: (ChangedFile) -> Void = { _ in }
    var onSelectCommit: (CommitInfo) -> Void = { _ in }
    var onEditCommit: (CommitInfo, String) -> Void = { _, _ in }
    var onReviewCommit: (CommitInfo) -> Void = { _ in }

    func update(
        onSelectFile: @escaping (ChangedFile) -> Void,
        onSelectCommit: @escaping (CommitInfo) -> Void,
        onEditCommit: @escaping (CommitInfo, String) -> Void,
        onReviewCommit: @escaping (CommitInfo) -> Void
    ) {
        self.onSelectFile = onSelectFile
        self.onSelectCommit = onSelectCommit
        self.onEditCommit = onEditCommit
        self.onReviewCommit = onReviewCommit
    }
}

private struct ChangesAppKitRowToken<Value: Equatable>: Equatable {
    let value: Value
    let theme: Theme
}

private struct ChangesEmptyRow: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
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
