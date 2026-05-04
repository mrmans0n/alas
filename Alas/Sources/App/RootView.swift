import SwiftUI

struct RootView: View {
    @Bindable var state: AppState
    @State private var showNewProject = false
    @State private var showNewWorktree = false
    @State private var collapsedProjects: Set<String> = []

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
                            onSearch: {},
                            onSettings: {},
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
                    right: { RightPlaceholder() }
                )
            }
        }
        .environment(\.theme, state.themeStore.current)
        .background(WindowConfigurator())
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea()
        .sheet(isPresented: $showNewProject) {
            NewProjectDialog(state: state, presented: $showNewProject)
        }
        .sheet(isPresented: $showNewWorktree) {
            NewWorktreeDialog(state: state, presented: $showNewWorktree)
        }
        .task {
            await state.projectsManager.refreshAll()
            if state.selectedWorktreeId == nil {
                state.selectedWorktreeId = state.projects
                    .flatMap { state.projectsManager.worktrees(projectId: $0.id) }
                    .first?.id
            }
        }
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
}
