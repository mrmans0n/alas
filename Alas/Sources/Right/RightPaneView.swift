import SwiftUI
import Combine

struct RightPaneView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    let onSelectChangedFile: (ChangedFile) -> Void
    let onSelectTreeFile: (FileTreeNode) -> Void
    let onSelectCommit: (CommitInfo) -> Void
    let onEditCommit: (CommitInfo, String) -> Void
    let onReviewCommit: (CommitInfo) -> Void
    var collapsed: Bool = false
    @Environment(\.theme) var theme
    @State private var rps: RightPaneState?
    @State private var agentManager: ACPSessionManager?
    @State private var agentSidebarRevision = 0

    init(
        state: AppState,
        worktree: Worktree,
        collapsed: Bool = false,
        onSelectChangedFile: @escaping (ChangedFile) -> Void,
        onSelectTreeFile: @escaping (FileTreeNode) -> Void,
        onSelectCommit: @escaping (CommitInfo) -> Void,
        onEditCommit: @escaping (CommitInfo, String) -> Void,
        onReviewCommit: @escaping (CommitInfo) -> Void
    ) {
        self.state = state
        self.worktree = worktree
        self.collapsed = collapsed
        self.onSelectChangedFile = onSelectChangedFile
        self.onSelectTreeFile = onSelectTreeFile
        self.onSelectCommit = onSelectCommit
        self.onEditCommit = onEditCommit
        self.onReviewCommit = onReviewCommit
        // Resolve without activating: the cached state (if any) gives us
        // something to render immediately, and `.task` handles the mutating
        // activation + refresh off the view-update path.
        let initialState = state.rightPaneStore.activeState(worktreeId: worktree.id)
        initialState?.activeTab = RightPaneTab.visible(
            initialState?.activeTab ?? .changes,
            agentTabEnabled: state.config.agentTabEnabled,
            runTabEnabled: state.config.runTabEnabled
        )
        _rps = State(initialValue: initialState)
    }

    var body: some View {
        let _ = agentSidebarRevision
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            if let rps = rps, rps.worktree.id == worktree.id {
                presentation(rps: rps)
                .sidebarChromeTheme(textContrast: override.textContrast)
                .onReceive(NotificationCenter.default.publisher(for: .alasSelectRightPaneTab)) { notification in
                    handleTabShortcut(notification, rps: rps)
                }
                .task(id: worktree.id) {
                    agentManager = state.acpManager(for: worktree)
                }
                .background {
                    if let agentManager, agentManager.worktreeId == worktree.id {
                        AgentSidebarManagerObserver(manager: agentManager) {
                            agentSidebarRevision &+= 1
                        }
                    }
                }
                .onChange(of: state.config.runTabEnabled) {
                    rps.activeTab = RightPaneTab.visible(
                        rps.activeTab,
                        agentTabEnabled: state.config.agentTabEnabled,
                        runTabEnabled: state.config.runTabEnabled
                    )
                }
                .onChange(of: state.config.agentTabEnabled) {
                    rps.activeTab = RightPaneTab.visible(
                        rps.activeTab,
                        agentTabEnabled: state.config.agentTabEnabled,
                        runTabEnabled: state.config.runTabEnabled
                    )
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
                .alert(
                    "Cherry-pick commit?",
                    isPresented: Binding(
                        get: { rps.pendingCherryPickSHA != nil },
                        set: { if !$0 { rps.cancelCherryPick() } }
                    ),
                    presenting: rps.pendingCherryPickSHA,
                    actions: { sha in
                        Button("Cherry-pick \(sha.prefix(7))") {
                            rps.confirmCherryPick()
                        }
                        Button("Cancel", role: .cancel) {
                            rps.cancelCherryPick()
                        }
                    },
                    message: { _ in
                        Text("Apply this commit to the current branch.")
                    }
                )
                .sheet(
                    isPresented: Binding(
                        get: { rps.pendingStashChanges },
                        set: { if !$0 { rps.cancelStashChanges() } }
                    )
                ) {
                    StashChangesSheet(
                        onStash: { message, includeUntracked in
                            rps.stashChanges(message: message, includeUntracked: includeUntracked)
                        },
                        onCancel: { rps.cancelStashChanges() }
                    )
                }
                .alert(
                    PendingStashDrop.alertTitle(for: rps.pendingStashDrop ?? .placeholder),
                    isPresented: Binding(
                        get: { rps.pendingStashDrop != nil },
                        set: { if !$0 { rps.cancelDropStash() } }
                    ),
                    presenting: rps.pendingStashDrop,
                    actions: { pending in
                        Button("Drop", role: .destructive) {
                            rps.confirmDropStash(pending)
                        }
                        Button("Cancel", role: .cancel) {
                            rps.cancelDropStash()
                        }
                    },
                    message: { pending in
                        Text(PendingStashDrop.alertMessage(for: pending))
                    }
                )
            } else {
                RightPaneLoadingSkeletonView(activeTab: .changes)
                    .sidebarChromeTheme(textContrast: override.textContrast)
            }
        }
        // Force a refresh whenever the user (re-)selects this worktree, when
        // its branch changes, or when relevant settings change. The
        // FSEvent watcher is the primary update path, but if it ever misses a
        // burst (debouncer starved, stream hiccup) re-selection is the user's
        // expected escape hatch — switching away and back should surface current
        // state. Activation happens inside the task, not during body evaluation,
        // so `RightPaneStore` mutations don't run inside a view update.
        .task(id: "\(worktree.id)\u{0000}\(worktree.branch)\u{0000}\(state.config.worktrees.baseBranch)\u{0000}\(state.config.changes.comparisonMode.rawValue)") {
            if rps?.worktree.id != worktree.id {
                rps = nil
            }
            let activated = state.rightPaneStore.state(
                for: worktree,
                baseBranch: state.config.worktrees.baseBranch,
                comparisonMode: state.config.changes.comparisonMode
            )
            rps = activated
            await activated.refresh(forceReviewLoopRemote: true)
        }
        .onAppear {
            state.rightPaneStore.prepareForVisiblePane(worktreeId: worktree.id)
        }
        .onChange(of: worktree.id) { _, worktreeId in
            state.rightPaneStore.consumePendingRevealForVisiblePane(worktreeId: worktreeId)
        }
        // When the right pane is hidden or unmounted (no worktree selected),
        // stop the active state's filesystem watcher and 5-min sync timer
        // so they don't keep running with no UI consumer. Re-mounting
        // restarts via `state(for:)`'s activate hook.
        .onDisappear {
            state.rightPaneStore.deactivate()
        }
    }

    @ViewBuilder
    private func tabContent(rps: RightPaneState) -> some View {
        if rps.hasLoadedSnapshot || (rps.activeTab == .agent && state.config.agentTabEnabled) {
            switch rps.activeTab {
            case .changes:
                ChangesTabView(
                    rps: rps,
                    appState: state,
                    onSelect: onSelectChangedFile,
                    onSelectCommit: onSelectCommit,
                    onEditCommit: onEditCommit,
                    onReviewCommit: onReviewCommit
                )
            case .files:
                FilesTabView(
                    nodes: rps.fileTree,
                    fileTreeGeneration: rps.fileTreeGeneration,
                    worktreePath: worktree.path,
                    openPaths: Binding(
                        get: { rps.openPaths },
                        set: { rps.openPaths = $0 }
                    ),
                    onSelectFile: onSelectTreeFile,
                    onFileHistory: { node in
                        state.openFileHistory(relativePath: node.path, worktreeId: worktree.id)
                    },
                    onCreateFile: { path in
                        state.newFile(in: worktree.id, directoryPath: path) {
                            Task { await rps.refresh() }
                        }
                    },
                    onCreateFolder: { path in
                        state.newFolder(in: worktree.id, directoryPath: path) {
                            Task { await rps.refresh() }
                        }
                    },
                    shouldAutoLoadChildren: { path, childrenState in
                        rps.shouldAutoLoadFileTreeChildren(path: path, childrenState: childrenState)
                    },
                    onLoadChildren: { rps.loadFileTreeChildren(path: $0) },
                    showIgnored: state.config.files.showIgnored,
                    revealPath: rps.revealPath,
                    revealTick: rps.revealTick,
                    onClearReveal: { rps.clearReveal() },
                    worktreeRoot: rps.worktree.path
                )
            case .agent:
                Group {
                    if let agentManager, agentManager.worktreeId == worktree.id {
                        AgentWorktreeTabView(state: state, worktree: worktree, manager: agentManager)
                            .id(worktree.id)
                    } else {
                        ProgressView("Loading sessions…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            case .run:
                RunTabView(state: state, worktree: worktree)
            }
        } else {
            RightPaneLoadingSkeletonView(activeTab: rps.activeTab)
        }
    }

    @ViewBuilder
    private func presentation(rps: RightPaneState) -> some View {
        if state.config.rightPaneRailEnabled {
            HStack(spacing: 0) {
                if !collapsed {
                    VStack(spacing: 0) {
                        RightPaneToolbar(
                            tab: rps.activeTab,
                            branch: rps.currentBranch,
                            totalAdd: rps.displayChanges.reduce(0) { $0 + $1.add },
                            totalDel: rps.displayChanges.reduce(0) { $0 + $1.del },
                            activeAgentCount: agentRollup.active.count,
                            waitingAgentCount: waitingAgentCount,
                            runningScriptNames: runningScriptNames,
                            showIgnored: state.config.files.showIgnored,
                            onToggleShowIgnored: {
                                state.config.files.showIgnored.toggle()
                                state.saveConfig()
                            },
                            onSearch: { state.openSearchOverlay() }
                        )
                        // Hides the indicators of every SwiftUI ScrollView in
                        // the tab bodies (Files, Agent, Run). The Changes tab
                        // scrolls through AppKit, which this cannot reach — it
                        // opts out via `AppKitDiffScroller.hidesScroller`.
                        tabContent(rps: rps)
                            .scrollIndicators(.hidden)
                    }
                }
                RightPaneRail(
                    activeTab: rps.activeTab,
                    collapsed: collapsed,
                    changesCount: rps.displayChanges.count,
                    activeAgentCount: agentRollup.active.count,
                    activeRunCount: runningScriptNames.count,
                    showAgentTab: state.config.agentTabEnabled,
                    showRunTab: state.config.runTabEnabled,
                    onAction: { action in handle(action, rps: rps) }
                )
            }
        } else {
            VStack(spacing: 0) {
                RightPaneTabBar(
                    activeTab: Binding(
                        get: { rps.activeTab },
                        set: { rps.activeTab = $0 }
                    ),
                    changesCount: rps.displayChanges.count,
                    totalAdd: rps.displayChanges.reduce(0) { $0 + $1.add },
                    totalDel: rps.displayChanges.reduce(0) { $0 + $1.del },
                    onHidePane: {
                        state.config.rightPaneVisible = false
                        state.saveConfig()
                    },
                    showIgnored: state.config.files.showIgnored,
                    onToggleShowIgnored: {
                        state.config.files.showIgnored.toggle()
                        state.saveConfig()
                    },
                    showAgentTab: state.config.agentTabEnabled,
                    showRunTab: state.config.runTabEnabled,
                    activeRunCount: state.runRecords
                        .records(worktreeID: worktree.id)
                        .count { $0.status.isActive },
                    activeAgentCount: state.agentSidebarRollup(for: worktree).active.count
                )
                tabContent(rps: rps)
            }
        }
    }

    /// Keyboard equivalent of tapping a rail tab. Handled here rather than in
    /// `AppState` because `collapsed` is the layout's *effective* state: when a
    /// narrow window makes `ThreePaneSizing` auto-collapse the pane it is true
    /// while `config.rightPaneVisible` is still true, and resolving from the
    /// preference alone would collapse a pane the user sees as already closed.
    private func handleTabShortcut(_ notification: Notification, rps: RightPaneState) {
        guard let raw = notification.object as? String,
              let tab = RightPaneTab(rawValue: raw),
              state.acceptsRightPaneTabShortcut(tab)
        else { return }
        handle(
            RightPaneRailAction.resolve(tapped: tab, active: rps.activeTab, collapsed: collapsed),
            rps: rps
        )
    }

    private func handle(_ action: RightPaneRailAction, rps: RightPaneState) {
        let outcome = RightPaneRailModel.apply(
            action,
            currentTab: rps.activeTab,
            currentVisible: state.config.rightPaneVisible
        )
        if rps.activeTab != outcome.tab {
            rps.activeTab = outcome.tab
        }
        if state.config.rightPaneVisible != outcome.visible {
            state.config.rightPaneVisible = outcome.visible
            state.saveConfig()
        }
    }

    private var agentRollup: AgentSidebarRollup {
        state.agentSidebarRollup(for: worktree)
    }

    private var waitingAgentCount: Int {
        agentRollup.active.count { $0.state == .awaitingInput || $0.state == .permissionRequest }
    }

    private var runningScriptNames: [String] {
        state.runRecords
            .records(worktreeID: worktree.id)
            .filter { $0.status.isActive }
            .map(\.scriptName)
    }
}

private struct AgentSidebarManagerObserver: View {
    @ObservedObject var manager: ACPSessionManager
    let onChange: () -> Void

    var body: some View {
        let sessionChanges = Publishers.MergeMany(manager.sessions.values.map(\.objectWillChange))

        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(manager.objectWillChange) { _ in
                onChange()
            }
            .onReceive(sessionChanges) { _ in
                onChange()
            }
    }
}
