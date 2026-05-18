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
