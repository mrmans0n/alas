import SwiftUI
import AppKit

struct SidebarView: View {
    @Bindable var state: AppState
    @Binding var collapsedProjects: Set<String>
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onEditProject: (_ projectId: String) -> Void
    let onRemoveProject: (_ projectId: String) -> Void
    let onNewWorktree: (_ projectId: String?) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        ZStack {
            SidebarMaterialBackground(choice: state.config.sidebarMaterial)
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
                                operationState: { wt in
                                    state.projectsManager.operationState(for: wt.id)
                                },
                                harnessSummary: { worktreeId in
                                    let ids = state.tabs.tabs(forWorktree: worktreeId).flatMap { tab -> [String] in
                                        if case .terminal(let s) = tab { return s.root.leaves().map(\.sessionId) }
                                        return []
                                    }
                                    return state.harness.summary(forSessionIds: ids)
                                },
                                onSelect: { wt in state.selectedWorktreeId = wt.id },
                                onNewWorktree: { onNewWorktree(project.id) },
                                onEditProject: { onEditProject(project.id) },
                                onRemoveProject: { onRemoveProject(project.id) },
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
                                onDelete: { wt in state.deleteWorktree(wt) },
                                onActivateHarness: { wt in
                                    let ids = state.tabs.tabs(forWorktree: wt.id).flatMap { tab -> [String] in
                                        if case .terminal(let s) = tab { return s.root.leaves().map(\.sessionId) }
                                        return []
                                    }
                                    guard let summary = state.harness.summary(forSessionIds: ids) else { return }
                                    state.activateHarnessSession(
                                        projectId: project.id,
                                        worktreeId: wt.id,
                                        sessionId: summary.primarySessionId
                                    )
                                },
                                onCopyError: { message in
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(message, forType: .string)
                                },
                                onRetryCreate: { wt in
                                    let retryBase: String
                                    if let op = state.projectsManager.operationState(for: wt.id),
                                       case .createFailed(_, let base) = op {
                                        retryBase = base
                                    } else {
                                        retryBase = state.config.worktrees.baseBranch
                                    }
                                    state.createWorktree(
                                        projectId: project.id,
                                        base: retryBase,
                                        branch: wt.branch,
                                        destination: wt.path,
                                        runStartup: false,
                                        openTerminal: false
                                    )
                                },
                                onRetryDelete: { wt in state.deleteWorktree(wt) },
                                onRemoveFailed: { wt in
                                    state.removeFailedOptimisticWorktree(id: wt.id, projectId: project.id)
                                },
                                onDropWorktree: { draggedId, destinationId in
                                    state.projectsManager.reorderWorktree(
                                        projectId: project.id,
                                        movingId: draggedId,
                                        destinationId: destinationId
                                    )
                                    state.saveProjects()
                                }
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}
