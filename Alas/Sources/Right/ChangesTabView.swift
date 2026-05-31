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
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            if let err = rps.sidebarError {
                InlineErrorStrip(
                    message: err,
                    onDismiss: { rps.sidebarError = nil }
                )
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

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
                DraftCommitTriggerRow(
                    stagedCount: stagedCount,
                    stagedAdd: stagedAdd,
                    stagedDel: stagedDel,
                    hasDraft: hasDraftTab,
                    draftNonEmpty: draftNonEmpty,
                    onOpen: openDraftTab
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
                isLoadingBranches: rps.isFetchingBranches,
                hasLoadedBranches: rps.hasFetchedBranches,
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

private struct DraftCommitTriggerRow: View {
    let stagedCount: Int
    let stagedAdd: Int
    let stagedDel: Int
    let hasDraft: Bool
    let draftNonEmpty: Bool
    let onOpen: () -> Void

    @Environment(\.theme) private var theme

    private var label: String {
        hasDraft ? "Open draft" : "Draft commit"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Icon(name: "commit", size: 11, color: theme.color("fg-dim"))
                if stagedCount > 0 {
                    Text("\(stagedCount) staged")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                    Text("+\(stagedAdd)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("add"))
                    Text("−\(stagedDel)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("del"))
                } else {
                    Text("0 staged")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-faint"))
                }
                Spacer()
                if hasDraft && draftNonEmpty {
                    Circle()
                        .fill(theme.color("accent"))
                        .frame(width: 5, height: 5)
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.color("accent"))
                Icon(name: "chev-right", size: 10, color: theme.color("fg-faint"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}
