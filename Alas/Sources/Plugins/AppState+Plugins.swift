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
            lastMessage: { [weak self] id in
                guard let self else { return .unknownSession }
                for worktree in self.projectsManager.worktreesByProject[project.id] ?? [] {
                    guard self.agentSidebarRollup(for: worktree).active.contains(where: {
                        PluginWorkspaceSnapshot.SessionInput(row: $0).id == id
                    }) else { continue }
                    // Terminal sessions have no live ACP session and so no transcript.
                    let messages = self.acpManager(forWorktreeId: worktree.id)?.liveSession(for: id)?.transcript.messages ?? []
                    for message in messages.reversed() {
                        guard case .agent(_, _, let text) = message else { continue }
                        let trimmed = text.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return .text(trimmed) }
                    }
                    return .none
                }
                return .unknownSession
            },
            agents: { [weak self] in
                guard let self else { return [] }
                return self.agentRegistry.enabled()
                    .filter { ACPLaunchCatalog.spec(for: $0.id) != nil }
                    .map { PluginAgent(id: $0.id, name: $0.displayName) }
            },
            startTask: { [weak self] request, completion in
                // The host outlives project edits, so use the project as it is now: a rename
                // changes the worktree path template's `{repo}`.
                guard let self else { return .rejected(code: -32003, message: "Alas is shutting down") }
                guard let current = self.projects.first(where: { $0.id == project.id }) else {
                    return .rejected(code: -32003, message: "\(project.name) is no longer in Alas")
                }
                return self.startPluginTask(request, project: current, completion: completion)
            },
            notify: { [weak self] title, body in
                // In-app notifications live on a worktree: the selected one when it is in this project.
                // ponytail: otherwise the project's first worktree, unseen until the user goes there;
                // route through the attention inbox if plugins need to reach other projects.
                guard let self else { return }
                let worktrees = self.projectsManager.worktreesByProject[project.id] ?? []
                guard let target = worktrees.first(where: { $0.id == self.selectedWorktreeId }) ?? worktrees.first else { return }
                self.inAppNotifications.post(
                    body.isEmpty ? title : "\(title)\n\(body)", severity: .information, worktreeID: target.id)
            },
            runs: { [weak self] in
                guard let self else { return [] }
                return (self.projectsManager.worktreesByProject[project.id] ?? []).flatMap { worktree in
                    self.runRecords.records(worktreeID: worktree.id).map { record in
                        var outcome: RunOutcome?
                        if case .finished(let finished) = record.status { outcome = finished }
                        return PluginRunState(run: record.id, worktree: worktree.id, script: record.scriptKey, outcome: outcome)
                    }
                }.sorted { $0.run < $1.run }
            },
            reviews: { [weak self] in
                guard let self else { return [] }
                return (self.projectsManager.worktreesByProject[project.id] ?? []).compactMap { worktree in
                    // ponytail: only worktrees whose right pane has loaded its review loop; the loop runs per pane.
                    guard let snapshot = self.rightPaneStore.activeState(worktreeId: worktree.id)?.reviewLoop.snapshot else {
                        return nil
                    }
                    return PluginReviewState(snapshot: snapshot, worktree: worktree.id)
                }
            },
            sendToSession: { [weak self] id, text in
                // Only live agent sessions of this project's worktrees; terminal sessions take no prompts.
                guard let self, let worktree = (self.projectsManager.worktreesByProject[project.id] ?? []).first(where: {
                    self.acpManager(forWorktreeId: $0.id)?.liveSession(for: id) != nil
                }) else { return false }
                Task { @MainActor in
                    await self.sendPrompt(for: id, worktreeID: worktree.id, text: text, attachments: [], onResult: { _ in })
                }
                return true
            },
            startRun: { [weak self] worktreeID, key in
                guard let self else { return "Alas is shutting down" }
                return await self.startPluginRun(worktreeID: worktreeID, scriptKey: key, projectID: project.id)
            },
            runOutput: { [weak self] runID in
                guard let self else { return .unknownRun }
                return await self.pluginRunOutput(runID, projectID: project.id)
            },
            addReviewComment: { [weak self] comment, author in
                guard let self else { return "Alas is shutting down" }
                guard let worktree = self.projectsManager.worktreesByProject[project.id]?.first(where: { $0.id == comment.worktree })
                else { return "unknown worktree \(comment.worktree)" }
                let response = await self.makeCLICommandRouter(sessionWorktreeLookup: { _ in nil }).service.reviewCommentAdd(
                    origin: worktree, path: comment.path, startLine: comment.line, endLine: nil, side: nil,
                    body: comment.body, sessionID: nil, projectWorktrees: [worktree], author: .agent(name: author))
                switch response {
                case .error(let message), .errorWithExitCode(let message, _): return message
                case .ok, .text: return nil
                }
            },
            worktreePath: { [weak self] id in
                // Processes and files run on this Mac, so remote worktrees are out of reach.
                guard let worktree = self?.projectsManager.worktreesByProject[project.id]?.first(where: { $0.id == id }),
                      RemoteHostRegistry.shared.host(forPath: worktree.path.path) == nil
                else { return nil }
                return worktree.path
            })
    }

    /// Starts a run script for a plugin the way the Run tab's start button does. Refuses one that is already running
    /// rather than focusing its terminal, which would move the user's selection.
    private func startPluginRun(worktreeID: String, scriptKey: String, projectID: String) async -> String? {
        guard let worktree = projectsManager.worktreesByProject[projectID]?.first(where: { $0.id == worktreeID }) else {
            return "unknown worktree \(worktreeID)"
        }
        let remoteHost = RemoteHostRegistry.shared.host(forPath: worktree.path.path)
        switch await RunScriptStore.discoverScripts(worktreeRoot: worktree.path, remoteHost: remoteHost) {
        case .failed(let message):
            return message
        case .scripts(let scripts):
            guard let script = scripts.first(where: { $0.key == scriptKey }) else { return "unknown run script \(scriptKey)" }
            if runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive == true
                || runningScriptTab(for: script, in: worktree) != nil {
                return "\(script.key) is already running"
            }
            runOrFocusScript(script, in: worktree)
            return nil
        }
    }

    /// A run of the project: its kept output once it finished.
    private func pluginRunOutput(_ runID: String, projectID: String) async -> PluginRunOutput {
        let worktreeIDs = Set((projectsManager.worktreesByProject[projectID] ?? []).map(\.id))
        for worktreeID in worktreeIDs {
            guard let record = runRecords.records(worktreeID: worktreeID).first(where: { $0.id == runID }) else { continue }
            if record.status.isActive { return .notFinished }
            // A run that just finished may still be on its way to the history store.
            await flushRunHistoryPersistence(worktreeID: worktreeID)
        }
        let entry: RunHistoryEntry?
        if let transient = worktreeIDs.lazy.compactMap({ self.transientRunReport(worktreeID: $0, runID: runID) }).first {
            entry = transient
        } else {
            entry = try? await runHistoryStore?.entry(id: runID)
        }
        guard let entry, worktreeIDs.contains(entry.worktreeID) else { return .unknownRun }
        switch entry.output {
        case .available(let text, _): return .text(text)
        case .unavailable: return .unavailable
        }
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
        switch await createWorktreeAtFreeDestination(rendered: branch, project: project) {
        case .failure(let failure): return Task.isCancelled ? cancelled : failure.message
        case .success(let created): worktree = created
        }
        let surface = WorktreeLaunchSurface.acp(agentId: agentId, preparedPrompt: prepared)
        do {
            try await launchWorktreeSurface(surface, worktree: worktree, project: project)
        } catch {
            if Task.isCancelled || error is CancellationError { return cancelled }
            // Thrown only by the agent check before any session exists, so Retry Launch is safe.
            markWorktreeLaunchFailed(worktree: worktree, projectId: project.id, error: error, launchSurface: surface)
            return error.localizedDescription
        }
        // As for scheduled chat sessions: the launch returns normally when the session could not
        // be opened or its agent did not start, so check what it left behind.
        guard !Task.isCancelled else { return cancelled }
        // Not marked as a failed launch: the session is already registered under its prepared id,
        // so Retry Launch would create it a second time. Shown in the app, as for scheduled runs.
        func failed(_ message: String) -> String {
            inAppNotifications.post(message, severity: .error, worktreeID: worktree.id)
            return message
        }
        guard let session = acpManager(forWorktreeId: worktree.id)?.liveSession(for: prepared.sessionID) else {
            return failed("Could not open a chat session for \(agentId) in \(worktree.branch).")
        }
        if let reason = session.lastError {
            return failed("\(agentId) could not start in \(worktree.branch): \(reason)")
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
        guard let manager = pluginManager, let projectId = selectedPluginProjectID else { return [] }
        return manager.plugins
            .filter { manager.host(pluginID: $0.id, projectID: projectId)?.state == .active }
            .flatMap { plugin in
                plugin.manifest.tabs.map {
                    PluginTabState(pluginID: plugin.id, contributionID: $0.id, title: $0.title)
                }
            }
    }

    /// The right pane's plugin panels for `projectID`.
    func pluginPanels(projectID: String) -> [PluginPanelItem] {
        guard let manager = pluginManager else { return [] }
        return PluginPanelItem.items(manager.plugins.map {
            ($0.manifest, manager.host(pluginID: $0.id, projectID: projectID) != nil)
        })
    }

    /// Inline panels at `location` from plugins running in `projectID`, placed for the worktree or run shown there.
    func pluginPanelTargets(
        _ location: PluginPanelLocation, projectID: String?, worktree: String? = nil, run: String? = nil
    ) -> [PluginPanelTarget] {
        guard let manager = pluginManager, let projectID else { return [] }
        return manager.plugins.flatMap { plugin -> [PluginPanelTarget] in
            guard let host = manager.host(pluginID: plugin.id, projectID: projectID), host.state == .active else { return [] }
            return plugin.manifest.panels.filter { $0.location == location }.map {
                PluginPanelTarget(host: host, place: PluginPanelPlace(panel: $0.id, worktree: worktree, run: run), title: $0.title)
            }
        }
    }

    /// The commands `slot` shows for `projectID`, from plugins running there.
    func pluginCommands(_ slot: PluginCommandSlot, projectID: String?) -> [PluginCommandItem] {
        guard let manager = pluginManager, let projectID else { return [] }
        return PluginCommandRouting.items(
            in: slot, projectID: projectID,
            plugins: manager.plugins.map {
                ($0.manifest, manager.host(pluginID: $0.id, projectID: projectID)?.state == .active)
            })
    }

    var selectedPluginProjectID: String? {
        selectedWorktreeId.flatMap { worktree(withId: $0)?.projectId }
    }

    /// `worktreeID` is the worktree the slot acts on and `detail` what its row names (see `PluginCommandRouting.target`);
    /// slots that act on the project ignore both.
    func runPluginCommand(_ item: PluginCommandItem, slot: PluginCommandSlot, worktreeID: String? = nil, detail: String? = nil) {
        guard let host = pluginManager?.host(pluginID: item.pluginID, projectID: item.projectID),
              let target = PluginCommandRouting.target(for: slot, worktreeID: worktreeID, detail: detail)
        else { return }
        Task { await host.runCommand(item.command.id, target: target) }
    }

    /// Badges plugins running in `projectID` put on one row, in plugin order.
    func pluginDecorations(
        _ slot: PluginDecorationSlot, projectID: String, worktree: String? = nil, target: String
    ) -> [PluginDecorationItem] {
        guard let manager = pluginManager else { return [] }
        let key = PluginDecorationKey(slot: slot, worktree: worktree, target: target)
        return manager.plugins.flatMap { plugin -> [PluginDecorationItem] in
            guard let host = manager.host(pluginID: plugin.id, projectID: projectID), host.state == .active else { return [] }
            return (host.decorations[key] ?? []).enumerated().map {
                PluginDecorationItem(pluginID: plugin.id, projectID: projectID, key: key, index: $0.offset, decoration: $0.element)
            }
        }
    }

    func runPluginDecoration(_ item: PluginDecorationItem) {
        guard let command = item.decoration.command,
              let host = pluginManager?.host(pluginID: item.pluginID, projectID: item.projectID),
              let target = PluginCommandRouting.target(for: item.key)
        else { return }
        Task { await host.runCommand(command, target: target) }
    }

    /// Long-running plugin processes in `worktreeID`, for the Run tab.
    func pluginProcessRuns(projectID: String, worktreeID: String) -> [PluginProcessItem] {
        guard let manager = pluginManager else { return [] }
        return manager.plugins.flatMap { plugin -> [PluginProcessItem] in
            guard let host = manager.host(pluginID: plugin.id, projectID: projectID) else { return [] }
            return host.processRuns.filter { $0.worktree == worktreeID }.map {
                PluginProcessItem(pluginID: plugin.id, projectID: projectID, pluginName: plugin.manifest.name, run: $0)
            }
        }
    }

    func stopPluginProcess(_ item: PluginProcessItem) {
        pluginManager?.host(pluginID: item.pluginID, projectID: item.projectID)?.stopProcess(item.run.id)
    }

    func openPluginTab(_ tab: PluginTabState) {
        guard let worktreeId = selectedWorktreeId else { return }
        tabs.openOrFocusPluginTab(worktreeId: worktreeId, state: tab)
        activateWorktreeCenterTab(worktreeId: worktreeId, tabId: tab.id)
    }
}
