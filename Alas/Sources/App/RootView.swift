import AppKit
import SwiftUI

struct RootView: View {
    @Bindable var state: AppState
    @State private var showNewProject = false
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
                                onNewWorktree: { projectId in
                                    newWorktreePresetProjectId = projectId
                                    showNewWorktree = true
                                }
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
                                        openOrFocusDiff(worktree: wt, path: file.path, staged: file.stage == .staged)
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
            FileSearchDialog(appState: state)
        }
        .environment(\.theme, state.themeStore.current)
        .onChange(of: state.themeStore.current.id) { _, _ in
            WindowAppearance.apply(darkMode: state.themeStore.current.darkMode)
        }
        .background(WindowConfigurator())
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea()
        .modifier(RootCommandHandlers(
            state: state,
            showNewWorktree: $showNewWorktree,
            selectedWorktree: selectedWorktree,
            openSettings: openSettingsWindow
        ))
        .sheet(isPresented: $showNewProject) {
            NewProjectDialog(state: state, presented: $showNewProject)
        }
        .sheet(isPresented: $showNewWorktree, onDismiss: { newWorktreePresetProjectId = nil }) {
            NewWorktreeDialog(
                state: state,
                presented: $showNewWorktree,
                presetProjectId: newWorktreePresetProjectId
            )
        }
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
        }
    }

    private func openSettingsWindow() {
        openWindow(id: "settings")
    }

    private func selectedWorktree() -> Worktree? {
        guard let id = state.selectedWorktreeId else { return nil }
        for project in state.projects {
            if let wt = state.projectsManager.visibleWorktrees(projectId: project.id).first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }

    private func firstWorktreeId() -> String? {
        for project in state.projects {
            if let worktree = state.projectsManager.visibleWorktrees(projectId: project.id).first {
                return worktree.id
            }
        }
        return nil
    }

    private func openOrFocusDiff(worktree: Worktree, path: String, staged: Bool) {
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
}

private struct RootCommandHandlers: ViewModifier {
    @Bindable var state: AppState
    @Binding var showNewWorktree: Bool
    let selectedWorktree: () -> Worktree?
    let openSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .alasToggleRightPane)) { _ in
                state.config.rightPaneVisible.toggle()
                state.saveConfig()
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasNewWorktree)) { _ in
                showNewWorktree = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasNewTerminalTab)) { _ in
                if let wt = selectedWorktree() { _ = try? state.openTerminalTab(for: wt) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasCloseTab)) { _ in
                if let wt = selectedWorktree(), let active = state.tabs.activeTabId(forWorktree: wt.id) {
                    state.closeTab(worktreeId: wt.id, tabId: active)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasActivateTabByNumber)) { notification in
                guard let number = notification.object as? Int,
                      let wt = selectedWorktree() else { return }
                state.tabs.activateTabNumber(number, worktreeId: wt.id)
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveActiveTab)) { _ in
                if let wt = selectedWorktree() {
                    state.saveActiveTab(worktreeId: wt.id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveActiveTabAs)) { _ in
                if let wt = selectedWorktree() {
                    state.saveActiveTabAs(worktreeId: wt.id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveAllTabs)) { _ in
                state.saveAllTabs()
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasRevertActiveTab)) { _ in
                if let wt = selectedWorktree() {
                    state.revertActiveTab(worktreeId: wt.id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasNewFile)) { _ in
                if let wt = selectedWorktree() {
                    state.newFile(in: wt.id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasRenameActiveFile)) { _ in
                if let wt = selectedWorktree() {
                    state.renameActiveFile(worktreeId: wt.id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenSettings)) { _ in
                openSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenSearch)) { _ in
                state.search.open()
                state.isSearchOpen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                state.tabs.snapshotDirtyBuffersForQuit()
            }
    }
}

extension Notification.Name {
    static let alasToggleRightPane = Notification.Name("AlasToggleRightPane")
    static let alasNewWorktree     = Notification.Name("AlasNewWorktree")
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
}
