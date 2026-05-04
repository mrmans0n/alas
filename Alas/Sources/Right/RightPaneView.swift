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
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            VStack(spacing: 0) {
                ChangesSectionView(
                    changes: rps.changes,
                    onSelect: onSelectChangedFile,
                    onRefresh: { Task { await rps.refresh() } }
                )
                .frame(minHeight: 200)
                Divider().opacity(0.5)
                FilesSectionView(
                    nodes: rps.fileTree,
                    openPaths: Binding(
                        get: { rps.openPaths },
                        set: { rps.openPaths = $0 }
                    ),
                    onSelectFile: onSelectTreeFile
                )
                .frame(minHeight: 180)
            }
        }
    }
}
