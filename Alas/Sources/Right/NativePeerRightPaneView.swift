import SwiftUI

/// The right pane for a selected peer session: the peer worktree's changes
/// and files, read-only. Tabs that only make sense on this Mac (agent, run,
/// schedules) are not offered.
struct NativePeerRightPaneView: View {
    @Bindable var state: AppState
    @Bindable var client: NativePeerSessions
    var collapsed: Bool = false

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeTab: RightPaneTab = .changes
    @State private var openPaths: Set<String> = []
    @State private var bookmarkOpenPaths: Set<String> = []
    @State private var railBodyWidth: Double = 0

    var body: some View {
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            HStack(spacing: 0) {
                if !collapsed {
                    VStack(spacing: 0) {
                        toolbar
                        tabContent
                            .scrollIndicators(.hidden)
                    }
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { railBodyWidth = $0 }
                    .transition(PaneCollapseMotion.transition(
                        edge: .trailing,
                        width: railBodyWidth,
                        reduceMotion: reduceMotion
                    ))
                }
                RightPaneRail(
                    activeTab: activeTab,
                    collapsed: collapsed,
                    changesCount: changesCount,
                    tabs: RightPaneTab.peerAvailable,
                    onAction: handle
                )
            }
            .sidebarChromeTheme(textContrast: override.textContrast)
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasSelectRightPaneTab)) { notification in
            guard let raw = notification.object as? String,
                  let tab = RightPaneTab(rawValue: raw),
                  RightPaneTab.peerAvailable.contains(tab)
            else { return }
            handle(RightPaneRailAction.resolve(tapped: tab, active: activeTab, collapsed: collapsed))
        }
        .onChange(of: client.selectedSessionId) { _, _ in openPaths = [] }
        .onChange(of: state.config.changes.comparisonMode) { _, _ in
            client.reloadWorkspace()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Icon(name: "branch", size: 10, color: theme.color("fg-muted"))
            Text([client.selectedPeer?.name, client.selectedRow?.worktree?.branch]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ToolbarBtn(icon: "arrow.clockwise", tooltip: "Refresh from peer") {
                client.reloadWorkspace()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var tabContent: some View {
        if activeTab == .files {
            filesTab
        } else {
            NativePeerChangesView(
                changes: client.workspace.changes,
                worktreePath: URL(fileURLWithPath: client.selectedRow?.worktree?.path ?? "/"),
                commitFiles: client.workspace.commitFiles,
                onLoadCommitFiles: { client.loadCommitFiles(sha: $0) },
                onOpen: { client.open($0) }
            )
            .id(client.selectedSessionId)
        }
    }

    @ViewBuilder
    private var filesTab: some View {
        switch client.workspace.fileTree {
        case .idle, .loading:
            RightPaneLoadingSkeletonView(activeTab: .files)
        case .failed(let message):
            NativePeerRailMessage(text: message)
        case .loaded(let nodes):
            VStack(spacing: 0) {
                if client.workspace.fileTreeTruncated {
                    NativePeerRailMessage(text: "The peer shortened one or more directory listings.")
                }
                FilesTabView(
                    nodes: nodes,
                    fileTreeGeneration: 0,
                    fileTreeRefreshRevision: client.workspace.fileTreeRevision,
                    // Only used to build copied full paths; the path is the peer's.
                    worktreePath: URL(fileURLWithPath: client.selectedRow?.worktree?.path ?? "/"),
                    openPaths: $openPaths,
                    onSelectFile: { client.open(.file(path: $0.path)) },
                    onFileHistory: { _ in },
                    onCreateFile: { _ in },
                    onCreateFolder: { _ in },
                    shouldAutoLoadChildren: { client.workspace.shouldLoadChildren(path: $0, childrenState: $1) },
                    onLoadChildren: { client.loadFileTreeChildren(path: $0) },
                    showIgnored: false,
                    revealPath: nil,
                    revealTick: 0,
                    onClearReveal: {},
                    bookmarkOpenPaths: $bookmarkOpenPaths,
                    readOnly: true
                )
            }
        }
    }

    private var changesCount: Int {
        if case .loaded(let changes) = client.workspace.changes {
            return Set((changes.staged + changes.unstaged).map(\.path)).count
        }
        return client.selectedRow?.worktree?.changedFileCount ?? 0
    }

    private func handle(_ action: RightPaneRailAction) {
        let outcome = RightPaneRailModel.apply(
            action,
            currentTab: activeTab,
            currentVisible: state.config.rightPaneVisible
        )
        activeTab = outcome.tab
        if state.config.rightPaneVisible != outcome.visible {
            state.config.rightPaneVisible = outcome.visible
            state.saveConfig()
        }
    }
}
