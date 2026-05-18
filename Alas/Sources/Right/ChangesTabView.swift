import SwiftUI
import AppKit

struct ChangesTabView: View {
    @Bindable var rps: RightPaneState
    @Bindable var appState: AppState
    let onSelect: (ChangedFile) -> Void
    let onSelectCommit: (CommitInfo) -> Void

    private var stagedCount: Int {
        rps.changes.filter { $0.stage == .staged }.count
    }
    private var stagedAdd: Int {
        rps.changes.filter { $0.stage == .staged }.reduce(0) { $0 + $1.add }
    }
    private var stagedDel: Int {
        rps.changes.filter { $0.stage == .staged }.reduce(0) { $0 + $1.del }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if stagedCount > 0 {
                    CommitComposerView(
                        state: rps.composer,
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
                    changes: rps.changes,
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
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(file.path, forType: .string)
                    },
                    onCopyFull: { file in
                        let absolute = rps.worktree.path.appendingPathComponent(file.path).path
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(absolute, forType: .string)
                    },
                    onRevealInFinder: { file in
                        let url = rps.worktree.path.appendingPathComponent(file.path)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    onCopyDiff: { file in rps.copyDiff(for: file.path) },
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
                    expanded: $rps.commitsExpanded,
                    onSelect: onSelectCommit,
                    onCopySHA: copyCommitSHA,
                    onLoadOlder: { Task { @MainActor in await rps.loadOlder() } }
                )
            }
        }
        .alert(
            PendingDiscard.alertTitle(for: rps.pendingDiscard ?? .placeholder),
            isPresented: Binding(
                get: { rps.pendingDiscard != nil },
                set: { if !$0 { rps.cancelDiscard() } }
            ),
            presenting: rps.pendingDiscard,
            actions: { _ in
                Button("Discard", role: .destructive) {
                    Task { @MainActor in await rps.confirmDiscard() }
                }
                Button("Cancel", role: .cancel) {
                    rps.cancelDiscard()
                }
            },
            message: { p in
                Text(PendingDiscard.alertMessage(for: p))
            }
        )
    }

    private var branchName: String? {
        // The worktree branch is already in `Worktree.branch`; fall back to
        // nil so the composer renders "(detached)" when we don't have one.
        let b = rps.worktree.branch
        return b.isEmpty ? nil : b
    }

    private func handleGenerate() {
        // Re-click while busy = cancel the in-flight generation.
        if rps.composer.busy {
            rps.cancelGenerate()
            return
        }
        guard let agent = appState.agent(id: appState.config.changes.aiToolId) else { return }
        rps.generate(promptOverride: appState.config.changes.prompt, agent: agent)
    }

    private func copyCommitSHA(_ commit: CommitInfo) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commit.sha, forType: .string)
    }
}
