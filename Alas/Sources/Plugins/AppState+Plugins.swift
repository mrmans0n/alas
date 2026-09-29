import Foundation

extension AppState {
    /// Plugin actions scoped to `project`: a snapshot of its worktrees, and
    /// switching only to worktrees that belong to it.
    func pluginHostActions(for project: ProjectConfig) -> PluginHostActions {
        PluginHostActions(
            snapshot: { [weak self] in
                self?.pluginWorkspaceSnapshot(projectId: project.id) ?? PluginWorkspaceSnapshot(worktrees: [])
            },
            switchWorktree: { [weak self] id in
                guard let self,
                      self.projectsManager.worktreesByProject[project.id]?.contains(where: { $0.id == id }) == true
                else { return false }
                self.focusGlobalWorktree(id: id, projectId: project.id)
                return true
            },
            focusSession: { _ in false })  // Task 5 wires this
    }

    private func pluginWorkspaceSnapshot(projectId: String) -> PluginWorkspaceSnapshot {
        let worktrees = projectsManager.worktreesByProject[projectId] ?? []
        return PluginWorkspaceSnapshot(
            worktrees: worktrees.map { worktree in
                PluginWorkspaceSnapshot.WorktreeInput(
                    worktree: worktree,
                    dirty: WorktreeStatusStore.shared.status(forPath: worktree.path.path),
                    sessions: agentSidebarRollup(for: worktree).active.map(PluginWorkspaceSnapshot.SessionInput.init(row:)))
            },
            selectedWorktreeId: selectedWorktreeId)
    }
}
