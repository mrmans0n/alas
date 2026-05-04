import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState
    @Binding var collapsedProjects: Set<String>
    let onSettings: () -> Void
    let onNewWorktree: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        ZStack {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            VStack(spacing: 0) {
                SidebarHeaderView(
                    onSettings: onSettings,
                    onNewWorktree: onNewWorktree
                )
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
                                onSelect: { wt in state.selectedWorktreeId = wt.id }
                            )
                        }
                    }
                    .padding(.top, 8)
                }
                Divider().opacity(0.5)
                HStack(spacing: 6) {
                    AlasButton(title: "New worktree", icon: "plus", style: .normal, action: onNewWorktree)
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
