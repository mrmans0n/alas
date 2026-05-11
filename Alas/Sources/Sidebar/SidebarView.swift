import SwiftUI
import AppKit

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
                SidebarHeaderView(
                    onSettings: onSettings,
                    onAddProject: onAddProject,
                    onSearch: {
                        NotificationCenter.default.post(name: .alasOpenSearch, object: nil)
                    }
                )
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.projects) { project in
                            RepoGroupView(
                                project: project,
                                worktrees: state.projectsManager.visibleWorktrees(projectId: project.id),
                                collapsed: Binding(
                                    get: { collapsedProjects.contains(project.id) },
                                    set: { collapsed in
                                        if collapsed { collapsedProjects.insert(project.id) }
                                        else { collapsedProjects.remove(project.id) }
                                    }
                                ),
                                selectedWorktreeId: state.selectedWorktreeId,
                                onSelect: { wt in state.selectedWorktreeId = wt.id },
                                onNewWorktree: { onNewWorktree(project.id) },
                                onRenameProject: { state.renameProject(id: project.id) },
                                onOpenTerminal: { wt in
                                    state.selectedWorktreeId = wt.id
                                    _ = try? state.openTerminalTab(for: wt)
                                },
                                onCopyPath: { wt in
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(wt.path.path, forType: .string)
                                },
                                onCopyBranch: { wt in
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(wt.branch, forType: .string)
                                },
                                onRevealInFinder: { wt in
                                    NSWorkspace.shared.activateFileViewerSelecting([wt.path])
                                },
                                onArchive: { wt in state.archiveWorktree(wt) },
                                onDelete: { wt in state.deleteWorktree(wt) }
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}
