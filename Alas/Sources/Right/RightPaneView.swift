import SwiftUI

struct RightPaneView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    let onSelectChangedFile: (ChangedFile) -> Void
    let onSelectTreeFile: (FileTreeNode) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        let rps = state.rightPaneStore.state(for: worktree)
        ZStack {
            VisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow)
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
                    ChangesTabView(rps: rps, onSelect: onSelectChangedFile)
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
    }
}
