import Foundation

extension AppState {
    func startPluginsIfEnabled() async {
        guard config.pluginsEnabled, pluginManager == nil else { return }
        let manager = PluginManager(
            projects: { [weak self] in self?.projects ?? [] },
            actions: { [weak self] project in self?.pluginHostActions(for: project) ?? .inert })
        pluginManager = manager
        await manager.reload()
    }

    func setPluginsEnabled(_ enabled: Bool) async {
        config.pluginsEnabled = enabled
        _ = saveConfig()
        if enabled {
            await startPluginsIfEnabled()
        } else if let manager = pluginManager {
            pluginManager = nil
            await manager.shutdown()
        }
    }

    /// Plugin actions scoped to `project`: a snapshot of its worktrees, and
    /// switching and focusing only within it.
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
            focusSession: { [weak self] id in
                guard let self else { return false }
                // Only sessions the snapshot exposes, so a plugin cannot reach another project's sessions.
                for worktree in self.projectsManager.worktreesByProject[project.id] ?? [] {
                    guard let row = self.agentSidebarRollup(for: worktree).active.first(where: {
                        PluginWorkspaceSnapshot.SessionInput(row: $0).id == id
                    }) else { continue }
                    self.focusGlobalWorktree(id: worktree.id, projectId: project.id)
                    // The sidebar's own path: unlike activating an existing tab, it reopens a session
                    // whose tab was closed, so a click never reports success while doing nothing.
                    Task { @MainActor in await self.focusAgentSidebarRow(row.id, in: worktree) }
                    return true
                }
                return false
            },
            // Replaced by the real start once tasks land.
            startTask: { _, _ in .rejected(code: -32003, message: "tasks are not available yet") })
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

extension AppState {
    /// Tab contributions of plugins running for the selected worktree's project.
    func pluginTabContributions() -> [PluginTabState] {
        guard let manager = pluginManager,
              let worktreeId = selectedWorktreeId,
              let projectId = worktree(withId: worktreeId)?.projectId
        else { return [] }
        return manager.plugins
            .filter { manager.host(pluginID: $0.id, projectID: projectId)?.state == .active }
            .flatMap { plugin in
                plugin.manifest.tabs.map {
                    PluginTabState(pluginID: plugin.id, contributionID: $0.id, title: $0.title)
                }
            }
    }

    func openPluginTab(_ tab: PluginTabState) {
        guard let worktreeId = selectedWorktreeId else { return }
        tabs.openOrFocusPluginTab(worktreeId: worktreeId, state: tab)
        activateWorktreeCenterTab(worktreeId: worktreeId, tabId: tab.id)
    }
}
