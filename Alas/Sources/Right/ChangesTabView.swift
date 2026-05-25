import SwiftUI
import AppKit

struct ChangesTabView: View {
    @Bindable var rps: RightPaneState
    @Bindable var appState: AppState
    let onSelect: (ChangedFile) -> Void
    let onSelectCommit: (CommitInfo) -> Void
    let onEditCommit: (CommitInfo, String) -> Void

    private var stagedCount: Int {
        rps.changes.filter { $0.stage == .staged }.count
    }
    private var stagedAdd: Int {
        rps.changes.filter { $0.stage == .staged }.reduce(0) { $0 + $1.add }
    }
    private var stagedDel: Int {
        rps.changes.filter { $0.stage == .staged }.reduce(0) { $0 + $1.del }
    }

    private var conflicts: [ChangedFile] {
        rps.changes.filter { $0.conflict != nil }
    }

    private var nonConflictChanges: [ChangedFile] {
        rps.changes.filter { $0.conflict == nil }
    }

    var body: some View {
        ScrollView {
            scrollContent
        }
    }

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let op = rps.mergeOp.current {
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

            if stagedCount > 0 {
                CommitComposerView(
                    state: rps.composer,
                    appState: appState,
                    stagedCount: stagedCount,
                    stagedAdd: stagedAdd,
                    stagedDel: stagedDel,
                    branchName: branchName,
                    availableAgents: appState.agentRegistry.enabled(),
                    aiToolId: appState.bind(\.changes.aiToolId),
                    onGenerate: handleGenerate,
                    onCommit: { rps.runCommit() },
                    onAmendToggle: { rps.amendDidChange($0) }
                )
            }
            WorkingTreeSectionView(
                changes: nonConflictChanges,
                expanded: $rps.workingTreeExpanded,
                onSelect: onSelect,
                onToggleStage: { rps.toggleStage($0) },
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
                onRevealInFinder: { file in
                    let url = rps.worktree.path.appendingPathComponent(file.path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                onCopyDiff: { file in
                    rps.copyDiff(for: file.path, renameFrom: file.renameFrom)
                },
                onDiscardFile: { file in rps.requestDiscardFile(path: file.path) },
                isOpenFileEnabled: { file in
                    DiffOpenFileAvailability.isAvailable(
                        worktreePath: rps.worktree.path,
                        relativePath: file.path
                    )
                }
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
                onSelect: onSelectCommit,
                onCopySHA: copyCommitSHA,
                onEdit: { commit in
                    if let ref = rps.comparisonRef {
                        onEditCommit(commit, ref)
                    }
                },
                onLoadOlder: { Task { @MainActor in await rps.loadOlder() } },
                onSelectBaseBranch: { branch in
                    rps.selectBaseBranch(branch)
                },
                onOpenBaseBranchSelector: { Task { @MainActor in await rps.fetchBranches() } },
                rps: rps
            )
        }
    }

    private var branchName: String? {
        let b = rps.worktree.branch
        return b.isEmpty ? nil : b
    }

    private func handleGenerate() {
        if rps.composer.busy {
            rps.cancelGenerate()
            return
        }
        guard let agent = appState.agent(id: appState.config.changes.aiToolId) else { return }
        rps.generate(promptOverride: appState.config.changes.prompt, agent: agent)
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
