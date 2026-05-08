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
                SidebarHeaderView(onSettings: onSettings)
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
                Divider().opacity(0.5)
                HStack(spacing: 6) {
                    AlasButton(title: "Add repository", icon: "folder-plus", style: .normal, action: onAddProject)
                        .frame(maxWidth: .infinity)
                    Button(action: onSettings) {
                        Icon(name: "gear", size: 13)
                            .frame(width: 32, height: 26)
                            .background(theme.color("bg-3"))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }
        }
    }
}
