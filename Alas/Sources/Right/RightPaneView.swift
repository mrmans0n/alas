import SwiftUI

struct RightPaneView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    let onSelectChangedFile: (ChangedFile) -> Void
    let onSelectTreeFile: (FileTreeNode) -> Void
    let onSelectCommit: (CommitInfo) -> Void
    let onEditCommit: (CommitInfo, String) -> Void
    let onReviewCommit: (CommitInfo) -> Void
    @Environment(\.theme) var theme
    @State private var rps: RightPaneState?

    init(
        state: AppState,
        worktree: Worktree,
        onSelectChangedFile: @escaping (ChangedFile) -> Void,
        onSelectTreeFile: @escaping (FileTreeNode) -> Void,
        onSelectCommit: @escaping (CommitInfo) -> Void,
        onEditCommit: @escaping (CommitInfo, String) -> Void,
        onReviewCommit: @escaping (CommitInfo) -> Void
    ) {
        self.state = state
        self.worktree = worktree
        self.onSelectChangedFile = onSelectChangedFile
        self.onSelectTreeFile = onSelectTreeFile
        self.onSelectCommit = onSelectCommit
        self.onEditCommit = onEditCommit
        self.onReviewCommit = onReviewCommit
        // Resolve without activating: the cached state (if any) gives us
        // something to render immediately, and `.task` handles the mutating
        // activation + refresh off the view-update path.
        _rps = State(initialValue: state.rightPaneStore.activeState(worktreeId: worktree.id))
    }

    var body: some View {
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            if let rps = rps, rps.worktree.id == worktree.id {
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
                        }
                    )

                    if rps.hasLoadedSnapshot {
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
                        }
                    } else {
                        RightPaneLoadingSkeletonView(activeTab: rps.activeTab)
                    }
                }
                .sidebarChromeTheme(textContrast: override.textContrast)
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
                        get: { rps.pendingParkChanges },
                        set: { if !$0 { rps.cancelParkChanges() } }
                    )
                ) {
                    ParkChangesSheet(
                        onPark: { message, includeUntracked in
                            rps.parkChanges(message: message, includeUntracked: includeUntracked)
                        },
                        onCancel: { rps.cancelParkChanges() }
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
        // When the right pane is hidden or unmounted (no worktree selected),
        // stop the active state's filesystem watcher and 5-min sync timer
        // so they don't keep running with no UI consumer. Re-mounting
        // restarts via `state(for:)`'s activate hook.
        .onDisappear {
            state.rightPaneStore.deactivate()
        }
    }
}
