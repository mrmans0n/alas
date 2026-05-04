import SwiftUI

struct RootView: View {
    @Bindable var state: AppState
    @State private var showNewProject = false
    @State private var showNewWorktree = false
    @State private var collapsedProjects: Set<String> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
                            onNewWorktree: { showNewWorktree = true }
                        )
                    },
                    center: {
                        if let wt = selectedWorktree() {
                            CenterPaneView(state: state, worktree: wt)
                        } else {
                            EmptyTabView(onNewTerminal: {})
                        }
                    },
                    right: {
                        if let wt = selectedWorktree() {
                            RightPaneView(
                                state: state,
                                worktree: wt,
                                onSelectChangedFile: { file in
                                    openOrFocusDiff(worktree: wt, path: file.path)
                                },
                                onSelectTreeFile: { node in
                                    openOrFocusEditor(worktree: wt, path: node.path)
                                }
                            )
                        } else {
                            EmptyView()
                        }
                    }
                )
            }
        }
        .environment(\.theme, state.themeStore.current)
        .background(WindowConfigurator())
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .alasToggleRightPane)) { _ in
            state.config.rightPaneVisible.toggle()
            state.saveConfig()
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasNewWorktree)) { _ in
            showNewWorktree = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasNewTerminalTab)) { _ in
            if let wt = selectedWorktree() { try? state.openTerminalTab(for: wt) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasCloseTab)) { _ in
            if let wt = selectedWorktree(), let active = state.tabs.activeTabId(forWorktree: wt.id) {
                state.closeTab(worktreeId: wt.id, tabId: active)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasOpenSettings)) { _ in
            openSettingsWindow()
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectDialog(state: state, presented: $showNewProject)
        }
        .sheet(isPresented: $showNewWorktree) {
            NewWorktreeDialog(state: state, presented: $showNewWorktree)
        }
        .task {
            state.startHarness()
            await state.projectsManager.refreshAll()
            // Worktrees now exist — load any persisted tab files for them. Init
            // can't do this because refreshAll runs async after init.
            state.reloadTabs()
            if state.selectedWorktreeId == nil {
                state.selectedWorktreeId = state.projects
                    .flatMap { state.projectsManager.worktrees(projectId: $0.id) }
                    .first?.id
            }
        }
    }

    private func openSettingsWindow() {
        openWindow(id: "settings")
    }

    private func selectedWorktree() -> Worktree? {
        guard let id = state.selectedWorktreeId else { return nil }
        for project in state.projects {
            if let wt = state.projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }

    private func openOrFocusDiff(worktree: Worktree, path: String) {
        let existing = state.tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .diff(let s) = tab { return s.relativePath == path } else { return false }
        }
        if let existing {
            state.tabs.activate(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let tab = state.tabs.appendDiff(
                worktreeId: worktree.id,
                title: (path as NSString).lastPathComponent,
                relativePath: path
            )
            state.tabs.activate(worktreeId: worktree.id, tabId: tab.id)
        }
    }

    private func openOrFocusEditor(worktree: Worktree, path: String) {
        let existing = state.tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .editor(let s) = tab { return s.relativePath == path } else { return false }
        }
        if let existing {
            state.tabs.activate(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let tab = state.tabs.appendEditor(
                worktreeId: worktree.id,
                title: (path as NSString).lastPathComponent,
                relativePath: path
            )
            state.tabs.activate(worktreeId: worktree.id, tabId: tab.id)
        }
    }
}

extension Notification.Name {
    static let alasToggleRightPane = Notification.Name("AlasToggleRightPane")
    static let alasNewWorktree     = Notification.Name("AlasNewWorktree")
    static let alasNewTerminalTab  = Notification.Name("AlasNewTerminalTab")
    static let alasCloseTab        = Notification.Name("AlasCloseTab")
    static let alasOpenSettings    = Notification.Name("AlasOpenSettings")
}
