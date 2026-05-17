import AppKit
import SwiftUI

struct RootView: View {
    @Bindable var state: AppState
    @State private var showNewProject = false
    @State private var editingProject: ProjectConfig?
    @State private var removingProject: ProjectConfig?
    @State private var showNewWorktree = false
    @State private var newWorktreePresetProjectId: String?
    @State private var collapsedProjects: Set<String> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Group {
                if state.projects.isEmpty {
                    EmptyState(
                        canCreateWorktree: false,
                        onAddProject: { showNewProject = true },
                        onNewWorktree: { showNewWorktree = true }
                    )
                } else {
                    ThreePaneLayout(
                        sidebarWidth: Binding(
                            get: { state.config.sidebarWidth },
                            set: { state.config.sidebarWidth = $0 }
                        ),
                        rightWidth: Binding(
                            get: { state.config.rightPaneWidth },
                            set: { state.config.rightPaneWidth = $0 }
                        ),
                        rightVisible: state.config.rightPaneVisible,
                        onWidthsChanged: { state.saveConfig() },
                        sidebar: {
                            SidebarView(
                                state: state,
                                collapsedProjects: $collapsedProjects,
                                onSettings: { openSettingsWindow() },
                                onAddProject: { showNewProject = true },
                                onEditProject: { projectId in
                                    editingProject = state.projects.first { $0.id == projectId }
                                },
                                onRemoveProject: { projectId in
                                    removingProject = state.projects.first { $0.id == projectId }
                                },
                                onNewWorktree: { projectId in
                                    newWorktreePresetProjectId = projectId
                                    showNewWorktree = true
                                }
                            )
                        },
                        center: {
                            centerContent()
                        },
                        right: {
                            if let wt = selectedWorktree() {
                                RightPaneView(
                                    state: state,
                                    worktree: wt,
                                    onSelectChangedFile: { file in
                                        openOrFocusDiff(worktree: wt, path: file.path, staged: file.stage == .staged)
                                    },
                                    onSelectTreeFile: { node in
                                        openOrFocusEditor(worktree: wt, path: node.path)
                                    },
                                    onSelectCommit: { commit in
                                        openOrFocusCommit(worktree: wt, commit: commit)
                                    }
                                )
                            } else {
                                EmptyView()
                            }
                        }
                    )
                }
            }
            FileSearchDialog(appState: state)
        }
        .environment(\.theme, state.themeStore.current)
        .onChange(of: state.themeStore.current.id) { _, _ in
            WindowAppearance.apply(darkMode: state.themeStore.current.darkMode)
        }
        .background(WindowConfigurator())
        .frame(minWidth: 700, minHeight: 600)
        .ignoresSafeArea()
        .modifier(RootCommandHandlers(
            state: state,
            showNewWorktree: $showNewWorktree,
            showNewProject: $showNewProject,
            selectedWorktree: selectedWorktree,
            openSettings: openSettingsWindow
        ))
        .sheet(isPresented: $showNewProject) {
            NewProjectDialog(state: state, presented: $showNewProject)
        }
        .sheet(item: $editingProject) { project in
            EditProjectDialog(
                state: state,
                presented: Binding(
                    get: { editingProject != nil },
                    set: { if !$0 { editingProject = nil } }
                ),
                project: project
            )
        }
        .sheet(isPresented: $showNewWorktree, onDismiss: { newWorktreePresetProjectId = nil }) {
            NewWorktreeDialog(
                state: state,
                presented: $showNewWorktree,
                presetProjectId: newWorktreePresetProjectId
            )
        }
        .alert(
            "'\(state.pendingForceDeleteWorktree?.branch ?? "")' \(state.pendingForceDeleteWorktree?.reason.alertTitleSuffix ?? "requires force delete.")",
            isPresented: Binding(
                get: { state.pendingForceDeleteWorktree != nil },
                set: { if !$0 { state.cancelForceDeletePendingWorktree() } }
            ),
            actions: {
                Button("Force Delete", role: .destructive) {
                    state.confirmForceDeletePendingWorktree()
                }
                Button("Cancel", role: .cancel) {
                    state.cancelForceDeletePendingWorktree()
                }
            },
            message: {
                Text(state.pendingForceDeleteWorktree?.reason.alertMessage ?? "Force delete?")
            }
        )
        .alert(
            "Remove \u{201C}\(removingProject?.name ?? "")\u{201D}?",
            isPresented: Binding(
                get: { removingProject != nil },
                set: { if !$0 { removingProject = nil } }
            ),
            presenting: removingProject,
            actions: { project in
                Button("Remove", role: .destructive) {
                    state.removeProject(id: project.id)
                    removingProject = nil
                }
                Button("Cancel", role: .cancel) {
                    removingProject = nil
                }
            },
            message: { _ in
                Text("Alas will stop tracking this project and its worktrees. No files will be deleted from disk. You can re-add it later.")
            }
        )
        .task {
            state.startHarness()
            if await state.projectsManager.refreshAll() {
                state.saveProjects()
            }
            // Worktrees now exist — load any persisted tab files for them. Init
            // can't do this because refreshAll runs async after init.
            state.reloadTabs()
            if state.selectedWorktreeId == nil {
                state.selectedWorktreeId = firstWorktreeId()
            }
            state.startAllProjectGitWatchers()
            state.rescanAgents()
        }
    }

    private func openSettingsWindow() {
        openWindow(id: "settings")
    }

    @ViewBuilder
    private func centerContent() -> some View {
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: state.selectedWorktreeId,
            projects: state.projects,
            projectsManager: state.projectsManager
        )
        switch resolver.resolve() {
        case .worktree(let wt):
            CenterPaneView(state: state, worktree: wt)
        case .deleting(let wt):
            DeletingWorktreeView(worktree: wt)
        case .deleteFailed(let wt, let message):
            DeleteFailedWorktreeView(
                worktree: wt,
                message: message,
                onRetry: { state.deleteWorktree(wt) },
                onCopyError: {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(message, forType: .string)
                }
            )
        case .empty:
            EmptyTabView(onNewTerminal: {})
        }
    }

    private func selectedWorktree() -> Worktree? {
        guard let id = state.selectedWorktreeId else { return nil }
        for project in state.projects {
            if let wt = state.projectsManager.visibleWorktrees(projectId: project.id).first(where: { $0.id == id }) {
                // Do not treat a creating/deleting/failed-create row as the active worktree.
                if let op = state.projectsManager.operationState(for: wt.id) {
                    switch op {
                    case .creating, .deleting, .createFailed:
                        return nil
                    case .deleteFailed:
                        break
                    }
                }
                return wt
            }
        }
        return nil
    }

    private func firstWorktreeId() -> String? {
        state.firstVisibleWorktreeId()
    }

    private func openOrFocusDiff(worktree: Worktree, path: String, staged: Bool) {
        if ImageFileType.isSupported(relativePath: path) {
            state.openFile(relativePath: path, worktreeId: worktree.id)
            return
        }

        let existing = state.tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .diff(let s) = tab { return s.relativePath == path && s.staged == staged } else { return false }
        }
        if let existing {
            state.tabs.activate(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let title = staged
                ? "\((path as NSString).lastPathComponent) (staged)"
                : (path as NSString).lastPathComponent
            let tab = state.tabs.appendDiff(
                worktreeId: worktree.id,
                title: title,
                relativePath: path,
                staged: staged
            )
            state.tabs.activate(worktreeId: worktree.id, tabId: tab.id)
        }
    }

    private func openOrFocusEditor(worktree: Worktree, path: String) {
        state.openFile(relativePath: path, worktreeId: worktree.id)
    }

    private func openOrFocusCommit(worktree: Worktree, commit: CommitInfo) {
        let existing = state.tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .commit(let s) = tab { return s.sha == commit.sha } else { return false }
        }
        if let existing {
            state.tabs.activate(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let title = "\(commit.shortSha) \(commit.subject)"
            let tab = state.tabs.appendCommit(worktreeId: worktree.id, sha: commit.sha, title: title)
            state.tabs.activate(worktreeId: worktree.id, tabId: tab.id)
        }
    }
}

private struct RootCommandHandlers: ViewModifier {
    @Bindable var state: AppState
    @Binding var showNewWorktree: Bool
    @Binding var showNewProject: Bool
    let selectedWorktree: () -> Worktree?
    let openSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(RootBaseHandlers(
                state: state,
                showNewWorktree: $showNewWorktree,
                showNewProject: $showNewProject,
                selectedWorktree: selectedWorktree,
                openSettings: openSettings
            ))
            .modifier(RootPaneHandlers(
                state: state,
                selectedWorktree: selectedWorktree
            ))
    }
}

private struct RootBaseHandlers: ViewModifier {
    @Bindable var state: AppState
    @Binding var showNewWorktree: Bool
    @Binding var showNewProject: Bool
    let selectedWorktree: () -> Worktree?
    let openSettings: () -> Void

    func body(content: Content) -> some View {
        let a = content
            .onReceive(NotificationCenter.default.publisher(for: .alasToggleRightPane)) { _ in
                state.config.rightPaneVisible.toggle()
                state.saveConfig()
            }
        let b = a
            .onReceive(NotificationCenter.default.publisher(for: .alasCreateProject)) { _ in
                showNewProject = true
            }
        let c = b
            .onReceive(NotificationCenter.default.publisher(for: .alasNewWorktree)) { _ in
                showNewWorktree = true
            }
        let d = c
            .onReceive(NotificationCenter.default.publisher(for: .alasNewTerminalTab)) { _ in
                if let wt = selectedWorktree() { _ = try? state.openTerminalTab(for: wt) }
            }
        let e = d
            .onReceive(NotificationCenter.default.publisher(for: .alasCloseTab)) { _ in
                if let wt = selectedWorktree() {
                    state.handleCloseShortcut(worktreeId: wt.id)
                }
            }
        let f = e
            .onReceive(NotificationCenter.default.publisher(for: .alasActivateTabByNumber)) { notification in
                guard let number = notification.object as? Int,
                      let wt = selectedWorktree() else { return }
                state.tabs.activateTabNumber(number, worktreeId: wt.id)
            }
        let g = f
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveActiveTab)) { _ in
                if let wt = selectedWorktree() {
                    state.saveActiveTab(worktreeId: wt.id)
                }
            }
        let h = g
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveActiveTabAs)) { _ in
                if let wt = selectedWorktree() {
                    state.saveActiveTabAs(worktreeId: wt.id)
                }
            }
        let i = h
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveAllTabs)) { _ in
                state.saveAllTabs()
            }
        let j = i
            .onReceive(NotificationCenter.default.publisher(for: .alasRevertActiveTab)) { _ in
                if let wt = selectedWorktree() {
                    state.revertActiveTab(worktreeId: wt.id)
                }
            }
        let k = j
            .onReceive(NotificationCenter.default.publisher(for: .alasNewFile)) { _ in
                if let wt = selectedWorktree() {
                    state.newFile(in: wt.id)
                }
            }
        let l = k
            .onReceive(NotificationCenter.default.publisher(for: .alasRenameActiveFile)) { _ in
                if let wt = selectedWorktree() {
                    state.renameActiveFile(worktreeId: wt.id)
                }
            }
        let m = l
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenSettings)) { _ in
                openSettings()
            }
        let n = m
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenSearch)) { _ in
                state.search.open()
                state.isSearchOpen = true
            }
        let o = n
            .onReceive(NotificationCenter.default.publisher(for: .alasRefreshWorktrees)) { _ in
                let beforeIds = state.allWorktreeIds()
                Task {
                    let changed = await state.projectsManager.refreshAll()
                    if changed {
                        state.saveProjects()
                    }
                    state.cleanupMissingWorktrees(beforeIds: beforeIds)
                }
            }
        return o
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                state.stopAllProjectGitWatchers()
                state.tabs.snapshotDirtyBuffersForQuit()
            }
    }
}

private struct RootPaneHandlers: ViewModifier {
    @Bindable var state: AppState
    let selectedWorktree: () -> Worktree?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .alasSplitRight)) { _ in
                if let wt = selectedWorktree() { state.splitFocusedPane(worktreeId: wt.id, axis: .vertical) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasSplitDown)) { _ in
                if let wt = selectedWorktree() { state.splitFocusedPane(worktreeId: wt.id, axis: .horizontal) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusPaneLeft)) { _ in
                if let wt = selectedWorktree() { state.focusPane(worktreeId: wt.id, direction: .left) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusPaneRight)) { _ in
                if let wt = selectedWorktree() { state.focusPane(worktreeId: wt.id, direction: .right) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusPaneUp)) { _ in
                if let wt = selectedWorktree() { state.focusPane(worktreeId: wt.id, direction: .up) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusPaneDown)) { _ in
                if let wt = selectedWorktree() { state.focusPane(worktreeId: wt.id, direction: .down) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasResizePaneLeft)) { _ in
                if let wt = selectedWorktree() { state.resizePane(worktreeId: wt.id, direction: .left) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasResizePaneRight)) { _ in
                if let wt = selectedWorktree() { state.resizePane(worktreeId: wt.id, direction: .right) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasResizePaneUp)) { _ in
                if let wt = selectedWorktree() { state.resizePane(worktreeId: wt.id, direction: .up) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasResizePaneDown)) { _ in
                if let wt = selectedWorktree() { state.resizePane(worktreeId: wt.id, direction: .down) }
            }
    }
}

extension Notification.Name {
    static let alasToggleRightPane   = Notification.Name("AlasToggleRightPane")
    static let alasCreateProject     = Notification.Name("AlasCreateProject")
    static let alasNewWorktree       = Notification.Name("AlasNewWorktree")
    static let alasRefreshWorktrees  = Notification.Name("AlasRefreshWorktrees")
    static let alasNewTerminalTab  = Notification.Name("AlasNewTerminalTab")
    static let alasCloseTab        = Notification.Name("AlasCloseTab")
    static let alasActivateTabByNumber = Notification.Name("AlasActivateTabByNumber")
    static let alasOpenSettings    = Notification.Name("AlasOpenSettings")
    static let alasOpenSearch      = Notification.Name("AlasOpenSearch")
    static let alasSaveActiveTab   = Notification.Name("AlasSaveActiveTab")
    static let alasSaveActiveTabAs = Notification.Name("AlasSaveActiveTabAs")
    static let alasSaveAllTabs     = Notification.Name("AlasSaveAllTabs")
    static let alasRevertActiveTab = Notification.Name("AlasRevertActiveTab")
    static let alasNewFile         = Notification.Name("AlasNewFile")
    static let alasRenameActiveFile = Notification.Name("AlasRenameActiveFile")
    static let alasSplitRight       = Notification.Name("AlasSplitRight")
    static let alasSplitDown        = Notification.Name("AlasSplitDown")
    static let alasFocusPaneLeft    = Notification.Name("AlasFocusPaneLeft")
    static let alasFocusPaneRight   = Notification.Name("AlasFocusPaneRight")
    static let alasFocusPaneUp      = Notification.Name("AlasFocusPaneUp")
    static let alasFocusPaneDown    = Notification.Name("AlasFocusPaneDown")
    static let alasResizePaneLeft   = Notification.Name("AlasResizePaneLeft")
    static let alasResizePaneRight  = Notification.Name("AlasResizePaneRight")
    static let alasResizePaneUp     = Notification.Name("AlasResizePaneUp")
    static let alasResizePaneDown   = Notification.Name("AlasResizePaneDown")
    static let alasShowFindReplace  = Notification.Name("AlasShowFindReplace")
    static let codeEditorDidAttach  = Notification.Name("CodeEditorDidAttach")
    static let codeEditorDidDetach  = Notification.Name("CodeEditorDidDetach")
}
