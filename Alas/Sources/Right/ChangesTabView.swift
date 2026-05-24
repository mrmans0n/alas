import SwiftUI
import AppKit

struct ChangesTabView: View {
    @Bindable var rps: RightPaneState
    @Bindable var appState: AppState
    let onSelect: (ChangedFile) -> Void
    let onSelectCommit: (CommitInfo) -> Void

    @State private var pendingMergeBranch: String = ""
    @State private var pendingRebaseOnto: String = ""
    @State private var branchesForPicker: [String] = []
    @State private var branchesLoading: Bool = false
    @State private var showMergePicker: Bool = false
    @State private var showRebasePicker: Bool = false

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
        VStack(alignment: .leading, spacing: 0) {
            branchOpsToolbar
            ScrollView {
                scrollContent
            }
        }
        .popover(isPresented: $showMergePicker, arrowEdge: .bottom) {
            branchPickerSheet(title: "Merge into current",
                              actionLabel: "Merge",
                              selection: $pendingMergeBranch,
                              onConfirm: {
                                  guard !pendingMergeBranch.isEmpty else { return }
                                  rps.runMerge(branch: pendingMergeBranch)
                                  showMergePicker = false
                                  pendingMergeBranch = ""
                              })
        }
        .popover(isPresented: $showRebasePicker, arrowEdge: .bottom) {
            branchPickerSheet(title: "Rebase current onto",
                              actionLabel: "Rebase",
                              selection: $pendingRebaseOnto,
                              onConfirm: {
                                  guard !pendingRebaseOnto.isEmpty else { return }
                                  rps.runRebase(onto: pendingRebaseOnto)
                                  showRebasePicker = false
                                  pendingRebaseOnto = ""
                              })
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
                onSelect: onSelect,
                onUseOurs: { file in rps.useOurs(file: file) },
                onUseTheirs: { file in rps.useTheirs(file: file) },
                onMarkResolved: { file in rps.markResolved(file: file) }
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
                onSelect: onSelectCommit,
                onCopySHA: copyCommitSHA,
                onLoadOlder: { Task { @MainActor in await rps.loadOlder() } },
                rps: rps
            )
        }
    }

    private var branchOpsToolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Merge branch into this worktree…") { openMergePicker() }
                Button("Rebase this worktree onto…")      { openRebasePicker() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Branch")
                        .font(.system(size: 11))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.05))
    }

    @ViewBuilder
    private func branchPickerSheet(title: String,
                                   actionLabel: String,
                                   selection: Binding<String>,
                                   onConfirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            BranchPicker(
                selection: selection,
                branches: branchesForPicker,
                isLoading: branchesLoading,
                errorMessage: nil
            )
            .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") {
                    showMergePicker = false
                    showRebasePicker = false
                }
                Button(actionLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.wrappedValue.isEmpty)
            }
        }
        .padding(12)
    }

    private func openMergePicker() {
        Task { await loadBranches() }
        showMergePicker = true
    }

    private func openRebasePicker() {
        Task { await loadBranches() }
        showRebasePicker = true
    }

    private func loadBranches() async {
        branchesLoading = true
        defer { branchesLoading = false }
        let svc = GitService()
        if let list = try? await svc.branches(at: rps.worktree.path) {
            branchesForPicker = list
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
}
