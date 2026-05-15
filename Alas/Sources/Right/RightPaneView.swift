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
                    onOpenFileSearch: { state.isSearchOpen = true }
                )

                switch rps.activeTab {
                case .changes:
                    ChangesTabView(rps: rps, appState: state, onSelect: onSelectChangedFile, onSelectCommit: onSelectCommit)
                case .files:
                    FilesTabView(
                        nodes: rps.fileTree,
                        openPaths: Binding(
                            get: { rps.openPaths },
                            set: { rps.openPaths = $0 }
                        ),
                        onSelectFile: onSelectTreeFile
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
    }
}
