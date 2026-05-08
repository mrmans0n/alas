import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState
    @Binding var collapsedProjects: Set<String>
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onNewWorktree: (_ projectId: String?) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        ZStack {
            VisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow)
            VStack(spacing: 0) {
                SidebarHeaderView(onSettings: onSettings, onAddProject: onAddProject)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.projects) { project in
                            RepoGroupView(
                                project: project,
                                worktrees: state.projectsManager.worktrees(projectId: project.id),
                                collapsed: Binding(
                                    get: { collapsedProjects.contains(project.id) },
                                    set: { collapsed in
                                        if collapsed { collapsedProjects.insert(project.id) }
                                        else { collapsedProjects.remove(project.id) }
                                    }
                                ),
                                selectedWorktreeId: state.selectedWorktreeId,
                                onSelect: { wt in state.selectedWorktreeId = wt.id },
                                onNewWorktree: { onNewWorktree(project.id) }
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}
