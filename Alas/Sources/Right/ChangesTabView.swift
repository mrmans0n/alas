import Combine
import SwiftUI

struct ChangesTabView: View {
    @Bindable var rps: RightPaneState
    @Bindable var appState: AppState
    let onSelect: (ChangedFile) -> Void
    let onSelectCommit: (CommitInfo) -> Void
    let onEditCommit: (CommitInfo, String) -> Void
    let onReviewCommit: (CommitInfo) -> Void
    let onReviewScope: (ChangesReviewScopeOption) -> Void

    @State private var collapsedChangePaths: Set<String> = []
    @State private var appKitActionRelay = ChangesAppKitActionRelay()
    @State private var amendProbe = CommitPublishAmendProbeLoader()
    @State private var shepherdOwnerLookup: ShepherdOwnerLookup?
    /// Ids and archive flags of the worktree's recent sessions. Archiving,
    /// here or in another instance, changes it and reloads the owner row.
    @State private var shepherdSessionsSignature = ""
    /// When review feedback last went to an agent from this worktree.
    @State private var lastReviewSnapshot: ReviewedWorkingTreeSnapshot?
    @Environment(\.theme) private var theme

    private var conflicts: [ChangedFile] {
        rps.changes.filter { $0.conflict != nil }
    }

    private var nonConflictChanges: [ChangedFile] {
        rps.displayChanges.filter { $0.conflict == nil }
    }

    private var preparationModel: ChangesPreparationModel {
        let landingStatus = Self.landingStatus(
            from: GGLandingStore.shared.sessions[rps.worktree.projectId]
        )
        if Self.shouldUseGGPreparation(
            drawerIsActive: isGGDrawerActive,
            landingStatus: landingStatus
        ) {
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
                reconciliationAction: Self.reconciliationAction(
                    from: ggReadinessModel,
                    mutationDisabledReason: ggPreparationMutationDisabledReason
                ),
                landingStatus: landingStatus,
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
                canDismissSyncFailure: rps.ggActionState.canDismissCompletedSyncFailure,
                stackStatus: Self.ggPreparationStackStatus(
                    loadState: rps.ggStackLoadState,
                    stack: rps.ggStack,
                    remoteError: rps.ggStackRemoteError,
                    remoteEnrichmentPending: rps.ggStackRemoteEnrichmentPending
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
            readinessActions: readiness.actions,
            publishAvailability: CommitPublishAvailability.review(
                snapshot: rps.reviewLoop.snapshot,
                supportedRemote: rps.commitRemote ?? rps.primaryCommitRemote,
                isRefreshing: rps.reviewLoop.showsRefreshProgress,
                currentBranch: rps.currentBranch,
                currentBaseBranch: rps.baseBranch,
                lastError: rps.reviewLoop.lastError,
                mutationDisabledReason: publishMutationDisabledReason,
                amend: currentDraft?.amend == true,
                amendProbe: amendProbe.result(for: amendProbeKey)
            ),
            pushAndCreateReviewRequestLabel: {
                guard let snapshot = rps.reviewLoop.snapshot,
                      snapshot.reviewRequest == nil,
                      ReviewReadinessModel.canCreateReviewRequest(snapshot)
                else { return nil }
                return snapshot.remote?.kind.reviewRequestLabel
            }(),
            pushAndCreateReviewRequestInFlight: rps.reviewLoop.inFlightAction == .pushAndCreateReviewRequest
        )
    }

    private var pluginSections: [PluginPanelTarget] {
        appState.pluginPanelTargets(.changesSection, projectID: rps.worktree.projectId, worktree: rps.worktree.id)
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
                scrollRequest: rps.attentionScrollRequest,
                onActiveOwnerChange: { _ in },
                onScrollRequestCompletion: { generation in
                    if rps.attentionScrollRequest?.generation == generation { rps.attentionScrollRequest = nil }
                },
                // The rail presentation drops the scroller: against a 36pt rail
                // and a narrow pane, a permanent scroller reads as clutter.
                hidesScroller: true
            )
            if isGGDrawerActive, rps.attentionRevealedTarget != nil {
                Button("Back to stack") { rps.endAttentionReveal() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if isGGDrawerActive, !isRevealingAttentionReview {
                GGStackDrawer(rps: rps, appState: appState)
            } else {
                ReviewLoopDrawer(
                    state: rps.reviewLoop,
                    canOpenAgentHandoff: rps.canOpenReviewLoopHandoff(appState: appState),
                    onAction: { action in rps.handleReviewReadinessAction(action, appState: appState) },
                    onRevealReviewRequest: { number in
                        appState.acknowledgeAttentionSurface(worktreeID: rps.worktree.id, target: .reviewRequest(number: number))
                    },
                    shepherd: shepherdDrawerModel
                )
            }
        }
        .onDisappear { rps.endAttentionReveal() }
        .pluginPanelsVisible(pluginSections)
        .task(id: agentAvailabilityTaskID) {
            await appState.loadAgentAvailability(for: rps.worktree)
        }
        .task(id: amendProbeKey) {
            let key = amendProbeKey
            guard currentDraft?.amend == true, !isGGDrawerActive else { return }
            await amendProbe.load(key: key) {
                try await GitService().headPublicationState(worktreePath: rps.worktree.path)
            }
        }
        .onReceive(shepherdRecentRows) { rows in
            let signature = rows.map { "\($0.id)\u{0001}\($0.archived)" }.joined(separator: "\u{0000}")
            if signature != shepherdSessionsSignature { shepherdSessionsSignature = signature }
        }
        .task(id: shepherdOwnerTaskID) {
            await loadShepherdOwner()
        }
        .task(id: rps.worktree.id) { loadLastReviewSnapshot() }
        .onReceive(NotificationCenter.default.publisher(for: .alasReviewedSnapshotDidChange)) { notification in
            guard notification.object as? String == rps.worktree.id else { return }
            loadLastReviewSnapshot()
        }
    }

    private func loadLastReviewSnapshot() {
        let snapshot = try? ReviewedSnapshotStore().load(worktreeID: rps.worktree.id)
        if snapshot != lastReviewSnapshot { lastReviewSnapshot = snapshot }
    }

    private var isRevealingAttentionReview: Bool {
        if case .reviewRequest = rps.attentionRevealedTarget { return true }
        return false
    }

    /// The persisted row of a bound record's owning session, loaded by id so
    /// an owner outside the manager's recent rows still resolves.
    private struct ShepherdOwnerLookup {
        let sessionID: String
        let row: ACPSessionRow?
    }

    /// The record for exactly the pane's review request, when the worktree is
    /// one the shepherd supports.
    private var shepherdRecord: ShepherdRecord? {
        guard appState.isShepherdEligible(rps.worktree),
              let request = rps.reviewLoop.snapshot?.reviewRequest
        else { return nil }
        return appState.reviewShepherd.records[ShepherdRecordID(worktreeID: rps.worktree.id, request: request)]
    }

    private var shepherdRecentRows: AnyPublisher<[ACPSessionRow], Never> {
        guard appState.isShepherdEligible(rps.worktree),
              let manager = appState.acpManager(for: rps.worktree)
        else { return Empty().eraseToAnyPublisher() }
        return manager.$recent.eraseToAnyPublisher()
    }

    private var shepherdOwnerTaskID: String {
        "\(rps.worktree.id)\u{0000}\(shepherdRecord?.sessionID ?? "")\u{0000}\(shepherdSessionsSignature)"
    }

    /// Reads the owner from the store after pending writes land, so an archive
    /// made here or by another instance shows; the manager's cached row is the
    /// fallback when the read fails.
    private func loadShepherdOwner() async {
        guard let sessionID = shepherdRecord?.sessionID,
              let manager = appState.acpManager(for: rps.worktree)
        else {
            shepherdOwnerLookup = nil
            return
        }
        await manager.flushPersistence()
        let row: ACPSessionRow?
        do {
            row = try await manager.persistence.loadSession(id: sessionID)
        } catch {
            row = await manager.persistedSessionRow(id: sessionID)
        }
        guard !Task.isCancelled else { return }
        shepherdOwnerLookup = ShepherdOwnerLookup(sessionID: sessionID, row: row)
    }

    /// The shepherd record for the pane's PR, or an unbound open PR the user
    /// can hand to a session. Nil for worktrees the shepherd does not support,
    /// and for branches with neither. Only a record for exactly the pane's
    /// request counts, so an older PR on a reused branch is never shown.
    private var shepherdDrawerModel: ReviewShepherdDrawerModel? {
        let worktree = rps.worktree
        guard appState.isShepherdEligible(worktree),
              let paneSnapshot = rps.reviewLoop.snapshot,
              paneSnapshot.reviewRequest != nil
        else { return nil }
        let shepherd = appState.reviewShepherd
        let record = shepherdRecord
        let snapshot = record.flatMap { shepherd.snapshots[$0.id] } ?? paneSnapshot
        guard let request = snapshot.reviewRequest,
              record != nil || request.state == .open
        else { return nil }

        let manager = appState.acpManager(for: worktree)
        let owner: ACPSessionRow? = record.flatMap { bound -> ACPSessionRow? in
            if let recent = manager?.sessionRows.first(where: { $0.id == bound.sessionID }) { return recent }
            guard let lookup = shepherdOwnerLookup, lookup.sessionID == bound.sessionID else { return nil }
            return lookup.row
        }.flatMap { $0.archived ? nil : $0 }
        let candidates = appState.shepherdCandidateItems(worktreeID: worktree.id)
            .filter { $0.id != record?.sessionID }
        // A bound record uses the shepherd's full gate from its last decision;
        // without one, the readiness half.
        let gatePasses = record.map { shepherd.gatePasses[$0.id] ?? false }
            ?? ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot)
        let recordID = record?.id
        let ownerSessionID = record?.sessionID

        return ReviewShepherdDrawerModel(
            record: record,
            presentation: ShepherdPresentation.make(record: record, request: request, mergeGatePasses: gatePasses),
            ownerTitle: owner?.title,
            ownerAgent: owner.flatMap { appState.agent(id: $0.agentId) },
            candidates: candidates,
            setAutoFix: { on in
                guard let recordID else { return }
                appState.reviewShepherd.setAutoFix(on, for: recordID)
            },
            setAutoMerge: { on in
                guard let recordID else { return }
                appState.reviewShepherd.setAutoMerge(on, for: recordID)
            },
            jump: {
                guard let ownerSessionID else { return }
                Task { await appState.openExistingACPSession(sessionId: ownerSessionID, worktree: worktree) }
            },
            stop: {
                guard let recordID else { return }
                appState.reviewShepherd.stopShepherding(recordID)
            },
            resume: {
                guard let recordID else { return }
                appState.reviewShepherd.resume(recordID)
            },
            shepherdWith: { sessionID in
                Task { await appState.shepherdWithSession(sessionID, worktree: worktree, request: request) }
            },
            shepherdWithNewSession: {
                Task { await appState.shepherdWithNewSession(worktree: worktree, request: request) }
            },
            refreshSessions: {
                manager?.refreshRecent()
            }
        )
    }

    private var agentAvailabilityTaskID: String {
        "\(rps.worktree.id)\u{0000}\(rps.worktree.path.path)\u{0000}\(appState.agentExecutionTarget(for: rps.worktree))\u{0000}\(appState.agentAvailabilityGeneration(for: rps.worktree))"
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
        from readiness: GGStackReadinessModel?,
        mutationDisabledReason: String? = nil
    ) -> GGStackReadinessModel.Action? {
        guard let readiness, !readiness.isPaused else { return nil }
        if let recommended = readiness.primaryActions.first(where: {
            $0.kind == .sync || $0.kind == .rebase
        }) {
            return recommended
        }
        return GGStackReadinessModel.Action(
            kind: .sync,
            title: "Sync stack",
            detail: mutationDisabledReason,
            isEnabled: mutationDisabledReason == nil,
            isInFlight: false,
            emphasis: .normal
        )
    }

    static func ggPreparationStackStatus(
        loadState: GGStackLoadState,
        stack: GGStack?,
        remoteError: String?,
        remoteEnrichmentPending: Bool
    ) -> ChangesPreparationModel.GGStackStatus {
        switch loadState {
        case .inactive, .failed:
            return .unavailable
        case .loading:
            return .loading
        case .empty:
            return .empty
        case .loaded:
            break
        }
        guard let stack else { return .unavailable }
        if remoteEnrichmentPending { return .refreshingRemote }
        if remoteError != nil { return .remoteUnavailable }
        let unsynced = max(0, stack.totalCommits - stack.syncedCommits)
        if unsynced > 0 {
            return .unsynced(commits: unsynced)
        }
        return .synced(commits: stack.syncedCommits)
    }

    static func landingStatus(
        from session: GGLandingSession?
    ) -> ChangesPreparationModel.GGLandingStatus? {
        guard let session,
              session.phase == .running || session.phase == .cancelling
        else { return nil }
        let row = session.rows.first { GGLandingPresentation.isActive($0, in: session) }
            ?? session.rows.first { $0.outcome == nil }
        return ChangesPreparationModel.GGLandingStatus(
            completed: session.rows.filter { $0.outcome != nil && $0.outcome?.error == nil }.count,
            total: session.rows.count,
            reviewNumber: row?.prNumber,
            detail: row.map { GGLandingPresentation.detail(for: $0, in: session) }
                ?? (session.phase == .cancelling ? "Cancelling..." : "Landing...")
        )
    }

    private var appKitScrollPlan: AppKitDiffRowPlan {
        let preparation = preparationModel
        let workingTree = workingTreeSection
        let workingGroups = WorkingTreeChangeGroup.group(files: nonConflictChanges)
        let workingGroupsSignature = String(reflecting: workingGroups).hashValue
        let groupsByPath = Dictionary(uniqueKeysWithValues: workingGroups.map { ($0.path, $0) })
        let commits = commitsSection
        var rowActions = workingTree.rowActions
        rowActions.pluginCommands = appState.pluginCommands(.changesFileMenu, projectID: rps.worktree.projectId)
        rowActions.onRunPluginCommand = { [appState, worktreeID = rps.worktree.id] item, file in
            appState.runPluginCommand(item, slot: .changesFileMenu, worktreeID: worktreeID, detail: file.path)
        }
        rowActions.pluginDecorations = { [appState, worktree = rps.worktree] path in
            appState.pluginDecorations(.changesFile, projectID: worktree.projectId, worktree: worktree.id, target: path)
        }
        rowActions.onRunPluginDecoration = { [appState] in appState.runPluginDecoration($0) }
        // Rows are reused while their token holds, so the plugin commands in their menus, titles and icons
        // included, are part of it.
        let pluginToken = String(reflecting: rowActions.pluginCommands) + String(reflecting: commits.pluginCommands)
        var rows: [AppKitDiffRowSpec] = []

        if let error = rps.sidebarError {
            rows.append(appKitRow(id: "changes-error", token: error, estimatedHeight: 38) {
                InlineErrorStrip(message: error, onDismiss: { rps.sidebarError = nil })
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            })
        }

        if let operation = rps.mergeOp.current,
           (rps.attentionRevealedTarget == .gitOperation || Self.shouldShowGenericOperationCard(
            mergeOperation: operation,
            pausedGGOperation: rps.ggActionState.pausedOperation
           )) {
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
                .simultaneousGesture(TapGesture().onEnded {
                    appState.acknowledgeAttentionSurface(worktreeID: rps.worktree.id, target: .gitOperation)
                })
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
                            prompt: appState.config.changes.mergeBulkResolvePrompt,
                            target: appState.agentExecutionTarget(for: rps.worktree),
                            agentBinaryUnavailable: { target in
                                appState.agentAvailabilityStore.invalidate(
                                    target: target,
                                    worktreePath: rps.worktree.path.path
                                )
                                await appState.loadAgentAvailability(for: rps.worktree)
                            }
                        )
                    },
                    onCancelBulkResolve: { rps.cancelBulkResolve() },
                    onDismissBulkReport: { rps.dismissBulkResolveReport() },
                    dragPayload: { file in
                        .workingTreeFile(worktreePath: rps.worktree.path, relativePath: file.path)
                    }
                )
                .simultaneousGesture(TapGesture().onEnded {
                    appState.acknowledgeAttentionSurface(worktreeID: rps.worktree.id, target: .conflicts(path: nil))
                })
            })
        }

        let reviewSnapshot = rps.reviewLoop.snapshot
        let reviewScopeOptions = ChangesReviewScopeOption.options(
            changes: rps.changes,
            commitCount: rps.commits.count,
            comparisonRef: rps.comparisonRef,
            canSnapshotWorkingTree: !rps.worktree.path.isRemoteAlasPath,
            lastReview: lastReviewSnapshot,
            hostedReviews: ChangesReviewScopeOption.hostedReviews(
                stack: rps.ggContext.isActive && rps.ggStackLoadState == .loaded ? rps.ggStack : nil,
                stackRemote: reviewSnapshot?.remote ?? rps.commitRemote ?? rps.primaryCommitRemote,
                branchRequest: reviewSnapshot?.reviewRequest
            )
        )
        if let preparation = Self.changesPreparationCardModel(
            preparation: preparation,
            hasReviewScopes: !reviewScopeOptions.isEmpty
        ) {
            let reviewScopeShortcut = appState.binding(for: .openReviewPalette)
            rows.append(appKitRow(
                id: "changes-preparation",
                token: String(reflecting: preparation) + String(reflecting: reviewScopeShortcut)
                    + String(reflecting: reviewScopeOptions),
                estimatedHeight: 92
            ) {
                ChangesPreparationCard(
                    model: preparation,
                    onReviewChanges: openReviewChangesTab,
                    onChooseReviewScope: { [appState, rps] in
                        appState.openReviewPaletteOverlay(prefill: rps.worktree)
                    },
                    reviewScopeOptions: reviewScopeOptions,
                    onReviewScopeOption: onReviewScope,
                    reviewScopeShortcut: reviewScopeShortcut,
                    onDraftCommit: openDraftTab,
                    onPublishCommit: openPublishTab,
                    onGGAction: handleGGPreparationAction,
                    onGGStackAction: { rps.onGGStackAction($0, appState: appState) },
                    onReviewRequestAction: { rps.handleReviewReadinessAction($0, appState: appState) },
                    onDismissSyncFailure: { rps.ggActionState.dismissCompletedSyncFailure() },
                    onOpenGGLanding: { appState.openGGLanding(projectId: rps.worktree.projectId) }
                )
            })
        }

        // Plugin sections, each hidden until its plugin renders something for this worktree.
        for target in pluginSections {
            guard let tree = target.host.panelTree(for: target.place) else { continue }
            rows.append(appKitRow(
                id: "plugin-section-\(target.host.manifest.id)-\(target.place.panel)",
                token: "\(ObjectIdentifier(target.host).hashValue)" + String(reflecting: tree),
                estimatedHeight: 80
            ) { PluginPanelSectionView(target: target) })
        }

        rows.append(appKitRow(
            id: "working-tree-header",
            token: "\(workingGroupsSignature)-\(rps.workingTreeExpanded)-\(rps.mergeOp.current != nil)-\(rps.stashOperationInFlight)-\(rps.checkpointMutationsDisabled)-\(String(reflecting: rps.checkpointLoadError))",
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
                                : String(reflecting: groupsByPath[row.node.path]) + pluginToken
                                    + String(reflecting: rowActions.pluginDecorations(row.node.path))),
                        estimatedHeight: 28
                    ) {
                        WorkingTreeFlatRowView(
                            row: row,
                            groups: workingGroups,
                            groupsByPath: groupsByPath,
                            collapsedPaths: $collapsedChangePaths,
                            actions: rowActions
                        )
                    })
                }
            }
        }

        appendCheckpointRows(to: &rows)
        appendStashRows(to: &rows)
        rows.append(appKitRow(id: "changes-commit-divider", token: 0, estimatedHeight: 1) {
            Divider().opacity(0.4)
        })
        appendCommitRows(commits, pluginToken: pluginToken, to: &rows)
        return AppKitDiffRowPlan(rows: rows)
    }

    static func shouldShowCheckpointsSection(
        summaryCount: Int,
        nonterminalJournalCount: Int,
        lastStatus: String?,
        operationInFlight: CheckpointOperationKind?,
        hasVisibleLoadError: Bool
    ) -> Bool {
        summaryCount > 0
            || nonterminalJournalCount > 0
            || lastStatus != nil
            || operationInFlight != nil
            || hasVisibleLoadError
    }

    private func appendCheckpointRows(to rows: inout [AppKitDiffRowSpec]) {
        let summaries = rps.checkpointSummaries
        let hasVisibleLoadError = rps.checkpointLoadError != nil && !rps.worktree.path.isRemoteAlasPath
        guard Self.shouldShowCheckpointsSection(
            summaryCount: summaries.count,
            nonterminalJournalCount: rps.nonterminalCheckpointJournals.count,
            lastStatus: rps.lastCheckpointStatus,
            operationInFlight: rps.checkpointOperationInFlight,
            hasVisibleLoadError: hasVisibleLoadError
        ) else { return }

        rows.append(appKitRow(
            id: "checkpoints-header",
            token: "\(String(reflecting: summaries))\(rps.checkpointsExpanded)\(rps.checkpointMutationsDisabled)\(String(reflecting: rps.checkpointLoadError))\(String(reflecting: rps.nonterminalCheckpointJournals))\(String(reflecting: rps.lastCheckpointStatus))",
            estimatedHeight: 32,
            retention: .sticky
        ) {
            SectionHeader(
                role: .checkpoints,
                title: "Checkpoints",
                count: summaries.count,
                expanded: rps.checkpointsExpanded,
                onToggle: { rps.checkpointsExpanded.toggle() }
            ) {
                Button {
                    rps.requestCheckpointCreation()
                } label: {
                    Icon(name: "plus", size: 11, color: theme.color("fg-muted"))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(rps.checkpointMutationsDisabled || rps.checkpointLoadError != nil)
                .accessibilityLabel("Create checkpoint")
            }
        })

        if let journal = rps.nonterminalCheckpointJournals.first {
            rows.append(appKitRow(
                id: "checkpoint-recovery-\(journal.id.uuidString)",
                token: "\(String(reflecting: journal))\(String(reflecting: rps.checkpointOperationInFlight))\(String(reflecting: rps.lastCheckpointError))",
                estimatedHeight: 118
            ) {
                CheckpointRecoveryCard(
                    journal: journal,
                    inFlight: rps.checkpointOperationInFlight != nil,
                    error: rps.lastCheckpointError,
                    status: nil,
                    onRecover: { Task { await rps.recoverCheckpointRestore(operationID: journal.id) } }
                )
            })
        } else if let status = rps.lastCheckpointStatus {
            rows.append(appKitRow(
                id: "checkpoint-recovery-status",
                token: status,
                estimatedHeight: 32
            ) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("add"))
                    .padding(.horizontal, 12).padding(.vertical, 7)
            })
        }

        guard rps.checkpointsExpanded else { return }
        if let error = rps.checkpointLoadError {
            rows.append(appKitRow(id: "checkpoints-error", token: error, estimatedHeight: 32) {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
                    .padding(.horizontal, 12).padding(.vertical, 7)
            })
        } else if summaries.isEmpty {
            rows.append(appKitRow(id: "checkpoints-empty", token: 0, estimatedHeight: 32) {
                ChangesEmptyRow(text: "no checkpoints")
            })
        } else {
            let automatic = summaries.filter { $0.kind == .automatic }
            appendCheckpointSummaryRows(
                summaries.filter { $0.kind != .automatic },
                to: &rows
            )
            if !automatic.isEmpty {
                rows.append(appKitRow(
                    id: "automatic-checkpoints",
                    token: "\(automatic.map(\.id))-\(rps.automaticCheckpointsExpanded)",
                    estimatedHeight: 32
                ) {
                    SubHeader(
                        title: "Automatic",
                        count: automatic.count,
                        expanded: rps.automaticCheckpointsExpanded,
                        onToggle: { rps.automaticCheckpointsExpanded.toggle() }
                    )
                })
                if rps.automaticCheckpointsExpanded {
                    appendCheckpointSummaryRows(automatic, to: &rows)
                }
            }
        }
        rows.append(appKitRow(
            id: "checkpoints-footer", token: rps.checkpointStorageUsage, estimatedHeight: 30
        ) { CheckpointFooterRow(storageUsage: rps.checkpointStorageUsage) })
    }

    private func appendCheckpointSummaryRows(
        _ summaries: [WorktreeCheckpointSummary],
        to rows: inout [AppKitDiffRowSpec]
    ) {
        let blockedReason = CheckpointPresentation.mutationsBlockedReason(
            operationInFlight: rps.checkpointOperationInFlight,
            hasInterruptedRestore: rps.hasInterruptedCheckpointRestore
        )
        for checkpoint in summaries {
            let isExpanded = rps.expandedCheckpointIDs.contains(checkpoint.id)
            let isLoading = rps.loadingCheckpointManifestIDs.contains(checkpoint.id)
            let manifest = rps.checkpointManifests[checkpoint.id]
            let error = rps.checkpointManifestErrors[checkpoint.id]
            let fileListPageIndex = rps.checkpointFileListPage(for: checkpoint.id)
            rows.append(appKitRow(
                id: CheckpointPresentation.rowID(checkpointID: checkpoint.id),
                token: Self.checkpointSummaryRowToken(
                    summary: checkpoint,
                    expanded: isExpanded,
                    loading: isLoading,
                    manifestError: error,
                    mutationsDisabled: rps.checkpointMutationsDisabled,
                    manifest: isExpanded ? manifest : nil,
                    blockedReason: blockedReason,
                    fileListPageIndex: fileListPageIndex
                ),
                estimatedHeight: Self.checkpointCardHeight(
                    summary: checkpoint,
                    expanded: isExpanded,
                    manifest: manifest,
                    pendingManifest: isLoading || error != nil || manifest == nil,
                    showsBlockedReason: rps.checkpointMutationsDisabled && blockedReason != nil,
                    fileListPageIndex: fileListPageIndex
                )
            ) {
                CheckpointCard(
                    checkpoint: checkpoint,
                    expanded: isExpanded,
                    manifest: manifest,
                    manifestLoading: isLoading,
                    manifestError: error,
                    mutationsDisabled: rps.checkpointMutationsDisabled,
                    blockedReason: blockedReason,
                    fileListPageIndex: fileListPageIndex,
                    onToggle: { rps.toggleCheckpointExpanded(checkpoint.id) },
                    onPreviousFilePage: { rps.retreatCheckpointFileListPage(checkpoint.id) },
                    onNextFilePage: { rps.advanceCheckpointFileListPage(checkpoint.id) },
                    onRestore: { Task { await rps.previewCheckpointRestore(id: checkpoint.id) } },
                    onDelete: { rps.pendingCheckpointDeletion = checkpoint },
                    onInspect: { group in
                        appState.openCheckpointDiffTab(
                            worktree: rps.worktree,
                            checkpointID: checkpoint.id,
                            groupID: group.id,
                            primaryPath: group.primaryPath,
                            memberPaths: group.memberPaths,
                            checkpointLabel: checkpoint.label
                        )
                    }
                )
            })
        }
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
        pluginToken: String,
        to rows: inout [AppKitDiffRowSpec]
    ) {
        let commits = rps.commitsForDisplay
        let older = rps.olderCommits
        let rowStateToken = commitRowsStateToken + pluginToken
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
                token: String(reflecting: commit) + rowStateToken + Self.commitRowTerminalToken(isLast: isLast)
                    + String(section.reviewRangeAnchorSHAs.contains(commit.sha)),
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

    static func checkpointSummaryRowToken(
        summary: WorktreeCheckpointSummary,
        expanded: Bool,
        loading: Bool,
        manifestError: String?,
        mutationsDisabled: Bool,
        manifest: WorktreeCheckpointManifest?,
        blockedReason: String?,
        fileListPageIndex: Int
    ) -> String {
        String(reflecting: summary)
            + String(expanded)
            + String(loading)
            + String(reflecting: manifestError)
            + String(mutationsDisabled)
            // The manifest now renders inside the summary row's card, so its
            // content participates in the row's identity.
            + String(reflecting: manifest?.groups.map(\.id))
            + String(reflecting: manifest?.exclusions.count)
            + String(reflecting: blockedReason)
            + String(fileListPageIndex)
    }

    /// Estimated height for a checkpoint card. Collapsed: outer padding (4+4),
    /// card padding (10+10) and the chip line (18). Expanded adds the detail
    /// line, the manifest's current windowed page, and the action bar.
    static func checkpointCardHeight(
        summary: WorktreeCheckpointSummary,
        expanded: Bool,
        manifest: WorktreeCheckpointManifest?,
        pendingManifest: Bool,
        showsBlockedReason: Bool,
        fileListPageIndex: Int
    ) -> CGFloat {
        var height: CGFloat = 46
        if summary.unavailableReason != nil { return height + 20 }
        guard expanded else { return height }
        height += 6 + 14 + 4
        if pendingManifest {
            height += 22
        } else if let manifest {
            let cap = CheckpointPresentation.maxInlineFileGroups
            let total = manifest.groups.count
            let pageStart = total == 0 ? 0 : min(fileListPageIndex * cap, total - 1)
            let pageEnd = min(pageStart + cap, total)
            height += CGFloat(total == 0 ? 0 : pageEnd - pageStart) * 21
            if total > cap { height += 18 }
            if !manifest.exclusions.isEmpty { height += 22 }
        }
        height += 5 + ACPComposerActionButtonMetrics.capsuleHeight
        if showsBlockedReason { height += 18 }
        return height
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
                Clipboard.copyPath(rps.worktree.path.appendingPathComponent(file.path).path)
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
            onCreateCheckpoint: { rps.requestCheckpointCreation() },
            createCheckpointDisabled: rps.checkpointMutationsDisabled || rps.checkpointLoadError != nil,
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
            onReviewRange: { [appState, rps] commit in
                appState.openReviewPaletteOverlay(prefill: rps.worktree, rangeAnchorSHA: commit.sha)
            },
            reviewRangeAnchorSHAs: Set(rps.commits.map(\.sha)),
            onLoadOlder: { Task { @MainActor in await rps.loadOlder() } },
            onSelectBaseBranch: { rps.selectBaseBranch($0) },
            onOpenBaseBranchSelector: { Task { @MainActor in await rps.fetchBranches() } },
            rps: rps,
            ggStack: rps.ggStack,
            stackCodeHostKind: rps.commitRemote?.kind,
            onGGAction: { action, commit in
                rps.handleGGCommitAction(action, commit: commit, appState: appState)
            },
            reviewRequest: rps.reviewLoop.snapshot?.reviewRequest,
            onOpenReviewRequest: { rps.openReviewLoopProviderPage() },
            pluginCommands: appState.pluginCommands(.changesCommitMenu, projectID: rps.worktree.projectId),
            onRunPluginCommand: { [appState, worktreeID = rps.worktree.id] item, commit in
                appState.runPluginCommand(item, slot: .changesCommitMenu, worktreeID: worktreeID, detail: commit.sha)
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

    static func shouldUseGGPreparation(
        drawerIsActive: Bool,
        landingStatus: ChangesPreparationModel.GGLandingStatus?
    ) -> Bool {
        drawerIsActive || landingStatus != nil
    }

    /// The model the Prepare card renders, or nil to hide it. A card with
    /// nothing else to show still appears for review scopes, as a lone
    /// Review button: a clean branch's commits, stack requests, and changes
    /// since the last review are otherwise out of reach.
    static func changesPreparationCardModel(
        preparation: ChangesPreparationModel,
        hasReviewScopes: Bool
    ) -> ChangesPreparationModel? {
        if preparation.isVisible { return preparation }
        return hasReviewScopes ? .reviewScopesOnly : nil
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
    /// `MergeConflictTabView.resolvedAgent` precedence: nil when AI is
    /// disabled, else the user's pinned tool from Settings, else (Automatic)
    /// the first eligible enabled agent.
    ///
    /// Filters out agents without a `bypassPermissionsFlag` because the
    /// bulk action runs the agent non-interactively (no TTY to answer
    /// write-approval prompts). Without bypass support, the agent would
    /// stall on the first file write and the run would hang until the
    /// 10-minute timeout fires. The bulk button is disabled in that
    /// case with a tooltip explaining why.
    private var resolvedBulkAgent: AgentDefinition? {
        // Automatic picks the first enabled agent that supports bypass, not
        // just the first one: the registry may list an agent without a bypass
        // flag (e.g. Pi) ahead of one that has it (Claude / Codex / Cursor).
        RepositoryAgentSelectionPolicy.selection(
            selectedID: appState.config.changes.aiToolId,
            availability: appState.agentAvailability(for: rps.worktree),
            where: { $0.supportsTerminal && $0.bypassPermissionsFlag != nil }
        ).agent
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
