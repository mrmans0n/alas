import SwiftUI

/// The right pane for a selected peer worktree: its changes and files,
/// read-only, and its sessions. Run is offered by hosts that serve their
/// scripts; schedules only make sense on this Mac and are not offered.
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
    @State private var runRefreshGeneration = 0

    var body: some View {
        let tabs = self.tabs
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
                        tabContent(shownTab(in: tabs))
                            .scrollIndicators(.hidden)
                    }
                    // Short content (a one-line message) must not let the
                    // stack shrink and float to the vertical center.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { railBodyWidth = $0 }
                    .transition(PaneCollapseMotion.transition(
                        edge: .trailing,
                        width: railBodyWidth,
                        reduceMotion: reduceMotion
                    ))
                }
                RightPaneRail(
                    activeTab: shownTab(in: tabs),
                    collapsed: collapsed,
                    changesCount: changesCount,
                    activeRunCount: activeRunCount,
                    tabs: tabs,
                    onAction: { handle($0, tabs: tabs) }
                )
            }
            .sidebarChromeTheme(textContrast: override.textContrast)
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasSelectRightPaneTab)) { notification in
            guard let raw = notification.object as? String,
                  let tab = RightPaneTab(rawValue: raw),
                  tabs.contains(tab)
            else { return }
            handle(RightPaneRailAction.resolve(tapped: tab, active: shownTab(in: tabs), collapsed: collapsed), tabs: tabs)
        }
        .onChange(of: client.selectedWorktree) { _, _ in openPaths = [] }
        .onChange(of: state.config.changes.comparisonMode) { _, _ in
            client.reloadWorkspace()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Icon(name: "branch", size: 10, color: theme.color("fg-muted"))
            // The peer's name already shows in the center pane's tab bar.
            Text(client.selectedWorktreeGroup?.worktree?.branch ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ToolbarBtn(icon: "arrow.clockwise", tooltip: "Refresh from peer") {
                client.reloadWorkspace()
                runRefreshGeneration += 1
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func tabContent(_ shownTab: RightPaneTab) -> some View {
        if shownTab == .agent {
            agentTab
        } else if shownTab == .run, let runTarget, let hosts = client.hosts {
            // Runs come from the host channel, so they need no session.
            NativePeerRunTabView(
                hosts: hosts,
                serverId: runTarget.serverId,
                worktree: runTarget.worktree,
                hostName: client.selectedWorktreePeer?.name ?? "The host",
                refreshGeneration: runRefreshGeneration,
                consoleIds: Set(client.consoles?.consoles[runTarget.serverId]?.map(\.consoleId) ?? []),
                openConsole: { client.selectConsole(serverId: runTarget.serverId, consoleId: $0) }
            )
        } else if !client.canReadWorkspace {
            // Changes and files are served per session, or per worktree by a
            // host that reads worktrees.
            NativePeerRailMessage(text: "Select a session to see this worktree's changes and files.")
        } else if shownTab == .files {
            filesTab
        } else {
            NativePeerChangesView(
                changes: client.workspace.changes,
                worktreePath: URL(fileURLWithPath: client.workspaceWorktreePath ?? "/"),
                commitFiles: client.workspace.commitFiles,
                onLoadCommitFiles: { client.loadCommitFiles(sha: $0) },
                onOpen: { client.open($0) }
            )
            .id(client.selectedSessionId ?? client.selectedWorktree?.worktreeId)
        }
    }

    private var agentTab: some View {
        let canOpen = client.selectedWorktree.map { client.canOpenSessionTabs(serverId: $0.serverId) } ?? false
        return VStack(spacing: 0) {
            if let error = client.sessionTabError {
                NativePeerRailMessage(text: error)
            }
            AgentTabView(
                rollup: AgentSidebarRollupBuilder.peer(client.selectedWorktreeGroup?.sessions ?? []),
                agentLookup: { agentID in
                    state.agent(id: agentID == AgentKind.cursor.rawValue ? "cursor-agent" : agentID)
                },
                actions: AgentSidebarActions(
                    onFocus: { rowID in
                        if case .acp(let sessionID) = rowID { client.openSession(sessionID) }
                    },
                    onInterrupt: { _ in },
                    onFollowUp: { _, _ in },
                    onDelegate: nil
                ),
                followUps: .constant([:]),
                disabledReason: { row in
                    row.state == .detached && !canOpen
                        ? "\(client.selectedWorktreePeer?.name ?? "This Mac") needs a newer Alas to open past sessions."
                        : nil
                }
            )
            .id(client.selectedWorktree)
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
                    worktreePath: URL(fileURLWithPath: client.workspaceWorktreePath ?? "/"),
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

    /// A folder project has no Changes tab, so it shows Files in its place.
    private var isFolder: Bool { client.selectedWorktreeGroup?.isFolder == true }
    /// The selected worktree on a host that serves its Run tab.
    private var runTarget: (serverId: String, worktree: PeerHostWorktree)? {
        guard let selection = client.selectedWorktree, let host = client.selectedWorktreeGroup?.host,
              client.hosts?.servesRuns(serverId: selection.serverId) == true
        else { return nil }
        return (selection.serverId, host)
    }

    private var tabs: [RightPaneTab] { RightPaneTab.peerAvailable(isFolder: isFolder, servesRuns: runTarget != nil) }

    /// Keeps the folder rule (Files in place of Changes) and drops a Run tab
    /// the host no longer serves.
    private func shownTab(in tabs: [RightPaneTab]) -> RightPaneTab {
        tabs.contains(activeTab) ? activeTab : tabs[0]
    }

    private var activeRunCount: Int {
        guard let runTarget else { return 0 }
        let worktreeID = runTarget.worktree.snapshot.worktree.id
        return client.hosts?.runs[runTarget.serverId]?.count(where: { $0.worktreeID == worktreeID && $0.status.isActive }) ?? 0
    }

    private var changesCount: Int {
        if case .loaded(let changes) = client.workspace.changes { return changes.branchFiles.count }
        return client.selectedWorktreeGroup?.worktree?.changedFileCount ?? 0
    }

    private func handle(_ action: RightPaneRailAction, tabs: [RightPaneTab]) {
        let outcome = RightPaneRailModel.apply(
            action,
            currentTab: shownTab(in: tabs),
            currentVisible: state.config.rightPaneVisible
        )
        activeTab = outcome.tab
        if state.config.rightPaneVisible != outcome.visible {
            state.config.rightPaneVisible = outcome.visible
            state.saveConfig()
        }
    }
}
