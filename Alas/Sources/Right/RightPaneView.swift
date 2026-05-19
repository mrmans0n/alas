import SwiftUI

struct RightPaneView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    let onSelectChangedFile: (ChangedFile) -> Void
    let onSelectTreeFile: (FileTreeNode) -> Void
    let onSelectCommit: (CommitInfo) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        let rps = state.rightPaneStore.state(for: worktree, baseBranch: state.config.worktrees.baseBranch)
        ZStack {
            SidebarMaterialBackground(choice: state.config.sidebarMaterial)
            VStack(spacing: 0) {
                RightPaneTabBar(
                    activeTab: Binding(
                        get: { rps.activeTab },
                        set: { rps.activeTab = $0 }
                    ),
                    changesCount: rps.changes.count,
                    totalAdd: rps.changes.reduce(0) { $0 + $1.add },
                    totalDel: rps.changes.reduce(0) { $0 + $1.del },
                    onHidePane: {
                        state.config.rightPaneVisible = false
                        state.saveConfig()
                    },
                    showIgnored: state.config.files.showIgnored,
                    onToggleShowIgnored: {
                        state.config.files.showIgnored.toggle()
                        state.saveConfig()
                    }
                )

                switch rps.activeTab {
                case .changes:
                    ChangesTabView(rps: rps, appState: state, onSelect: onSelectChangedFile, onSelectCommit: onSelectCommit)
                case .files:
                    FilesTabView(
                        nodes: rps.fileTree,
                        fileTreeGeneration: rps.fileTreeGeneration,
                        openPaths: Binding(
                            get: { rps.openPaths },
                            set: { rps.openPaths = $0 }
                        ),
                        onSelectFile: onSelectTreeFile,
                        shouldAutoLoadChildren: { path, childrenState in
                            rps.shouldAutoLoadFileTreeChildren(path: path, childrenState: childrenState)
                        },
                        onLoadChildren: { rps.loadFileTreeChildren(path: $0) },
                        showIgnored: state.config.files.showIgnored
                    )
                }
            }
        }
        // Force a refresh whenever the user (re-)selects this worktree. The
        // FSEvent watcher is the primary update path, but if it ever misses
        // a burst (debouncer starved, stream hiccup) re-selection is the
        // user's expected escape hatch — switching away and back should
        // surface current state.
        .task(id: worktree.id) {
            await rps.refresh()
        }
        // Host the discard confirmation here (not on ChangesTabView) so
        // diff-tab Discard actions still present the alert when the right
        // pane is on the Files tab — `requestDiscardFile` sets pending state
        // regardless of which child view is mounted.
        .alert(
            PendingDiscard.alertTitle(for: rps.pendingDiscard ?? .placeholder),
            isPresented: Binding(
                get: { rps.pendingDiscard != nil },
                set: { if !$0 { rps.cancelDiscard() } }
            ),
            presenting: rps.pendingDiscard,
            actions: { _ in
                Button("Discard", role: .destructive) {
                    if let pending = rps.pendingDiscard {
                        rps.pendingDiscard = nil
                        Task { @MainActor in await rps.confirmDiscard(pending) }
                    }
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
}
