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
            startTask: { [weak self] request, completion in
                self?.startPluginTask(request, project: project, completion: completion)
                    ?? .rejected(code: -32003, message: "Alas is shutting down")
            })
    }

    /// Starts a plugin task on the scheduled-run path: a new worktree, created without changing
    /// the selection, with an agent chat session that sends `request.prompt` straight away.
    /// Returns before any of that happens; `completion` is called once, later, with nil on
    /// success or the reason it failed.
    func startPluginTask(
        _ request: PluginTaskRequest,
        project: ProjectConfig,
        completion: @escaping @MainActor (String?) -> Void
    ) -> PluginTaskStart {
        guard let agentId = request.agent
            ?? defaultAgentID(projectId: project.id, worktreeRoot: URL(fileURLWithPath: project.path))
        else {
            return .rejected(code: -32003, message: "no agent is configured for \(project.name)")
        }
        // Also catches an unknown id: only a known ACP agent can take the prompt as a message.
        guard ACPLaunchCatalog.spec(for: agentId) != nil else {
            return .rejected(code: -32602, message: "agent \(agentId) cannot take a prompt")
        }
        let branch = PluginTaskBranch.name(title: request.title, requested: request.branch)
        let prepared = PreparedWorktreeACPPrompt(
            sessionID: UUID().uuidString,
            promptID: UUID(),
            text: request.prompt,
            sendsAutomatically: true,
            modelID: nil)
        // Spawned, never awaited here: the host records the session id only after this returns,
        // so the completion must not run before then.
        Task { @MainActor in
            completion(await self.runPluginTask(prepared, agentId: agentId, branch: branch, project: project))
        }
        // The reply names the requested branch. When it is taken, `reserveWorktreeDestination`
        // creates a suffixed one instead, and the plugin learns the real name from the snapshot.
        return .started(sessionId: prepared.sessionID, branch: branch)
    }

    /// Nil when the agent came up with the prompt, otherwise why not.
    private func runPluginTask(
        _ prepared: PreparedWorktreeACPPrompt,
        agentId: String,
        branch: String,
        project: ProjectConfig
    ) async -> String? {
        let cancelled = "The task was cancelled before its agent started."
        let worktree: Worktree
        switch await reserveWorktreeDestination(rendered: branch, project: project) {
        case .failure(let failure):
            return failure.message
        case let .success((branch, destination, base)):
            defer { releaseWorktreeDestination(projectID: project.id, branch: branch, destination: destination) }
            guard !Task.isCancelled else { return cancelled }
            switch await createWorktreeAndWait(
                projectId: project.id, base: base, branch: branch, destination: destination, runStartup: true
            ) {
            case .failure(let failure): return failure.message
            case .success(let created): worktree = created
            }
        }
        let surface = WorktreeLaunchSurface.acp(agentId: agentId, preparedPrompt: prepared)
        do {
            try await launchWorktreeSurface(surface, worktree: worktree, project: project)
        } catch {
            if Task.isCancelled || error is CancellationError { return cancelled }
            markWorktreeLaunchFailed(worktree: worktree, projectId: project.id, error: error, launchSurface: surface)
            return error.localizedDescription
        }
        // As for scheduled chat sessions: the launch returns normally when the session could not
        // be opened or its agent did not start, so check what it left behind.
        guard !Task.isCancelled else { return cancelled }
        guard let session = acpManager(forWorktreeId: worktree.id)?.liveSession(for: prepared.sessionID) else {
            return "Could not open a chat session for \(agentId) in \(worktree.branch)."
        }
        if let reason = session.lastError {
            return "\(agentId) could not start in \(worktree.branch): \(reason)"
        }
        return nil
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
