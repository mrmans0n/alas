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
                }) else { return "unknown session \(id)" }
                // Answered once the session accepted or refused the prompt (no writer lease, signed out, …).
                let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    var resumed = false
                    Task { @MainActor in
                        await self.sendPrompt(for: id, worktreeID: worktree.id, text: text, attachments: [], onResult: { ok in
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(returning: ok)
                        })
                    }
                }
                return accepted ? nil : "the session did not accept the prompt"
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
            worktreeLocation: { [weak self] id in
                guard let worktree = self?.projectsManager.worktreesByProject[project.id]?.first(where: { $0.id == id })
                else { return nil }
                if let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path) {
                    return .remote(host: host, root: RemotePath.realPath(worktree.path.path))
                }
                return .local(worktree.path)
            })
    }

    /// Starts a run script for a plugin the way the Run tab's start button does: a finished run, or one whose
    /// terminal is still open after it ended, is restarted. Refuses one that is actively running rather than
    /// focusing its terminal, which would move the user's selection.
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
            let record = runRecords.record(worktreeID: worktree.id, scriptKey: script.key)
            if record?.status.isActive == true { return "\(script.key) is already running" }
            // A refusal goes back to the plugin rather than into an alert in front of the user.
            let result: RunScriptLaunchStart
            if case .finished? = record?.status {
                result = restartScript(script, in: worktree, presentsLaunchFailure: false)
            } else if scriptTab(for: script, in: worktree) != nil {
                result = restartScript(script, in: worktree, presentsLaunchFailure: false)
            } else {
                result = launchScript(script, in: worktree, presentsLaunchFailure: false)
            }
            switch result {
            case .started, .alreadyStarting: return nil
            case .projectUnavailable: return "the project is unavailable"
            case let .refused(title, message): return "\(title): \(message)"
            }
        }
    }

    /// A run of the project: its kept output once it finished.
    private func pluginRunOutput(_ runID: String, projectID: String) async -> PluginRunOutput {
        let worktreeIDs = Set((projectsManager.worktreesByProject[projectID] ?? []).map(\.id))
        for worktreeID in worktreeIDs {
            if runRecords.records(worktreeID: worktreeID).first(where: { $0.id == runID })?.status.isActive == true {
                return .notFinished
            }
        }
        // A run that just finished may still be on its way to the history store, even one a newer run of the same
        // script has since replaced in the records.
        for worktreeID in worktreeIDs { await flushRunHistoryPersistence(worktreeID: worktreeID) }
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
        let project = projects.first { $0.id == projectId }
        return PluginWorkspaceSnapshot(
            worktrees: worktrees.map { worktree in
                PluginWorkspaceSnapshot.WorktreeInput(
                    worktree: worktree,
                    dirty: WorktreeStatusStore.shared.status(forPath: worktree.path.path),
                    sessions: agentSidebarRollup(for: worktree).active.map(PluginWorkspaceSnapshot.SessionInput.init(row:)),
                    isMain: project.map { projectsManager.isMain(worktree, in: $0) } ?? false)
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
    func runPluginCommand(
        _ item: PluginCommandItem, slot: PluginCommandSlot, worktreeID: String? = nil, detail: String? = nil, text: String? = nil
    ) {
        guard let host = pluginManager?.host(pluginID: item.pluginID, projectID: item.projectID),
              let target = PluginCommandRouting.target(for: slot, worktreeID: worktreeID, detail: detail, text: text)
        else { return }
        openPluginTab(forCommand: item.command.id, pluginID: item.pluginID, projectID: item.projectID, worktreeID: worktreeID)
        Task { await host.runCommand(item.command.id, target: target) }
    }

    /// Opens the tab an API 8 command names, in a worktree of the project the command ran in: the one it acts on,
    /// else the selected one, else the project's main worktree. A worktree other than the selected one is selected,
    /// as plugin tabs live in the selected worktree's center pane.
    private func openPluginTab(forCommand commandID: String, pluginID: String, projectID: String, worktreeID: String?) {
        guard let manifest = pluginManager?.plugins.first(where: { $0.id == pluginID })?.manifest,
              let opens = manifest.commands.first(where: { $0.id == commandID })?.opens,
              let tab = manifest.tabs.first(where: { $0.id == opens }),
              let worktree = worktreeID
              ?? (selectedPluginProjectID == projectID ? selectedWorktreeId : nil)
              ?? projectsManager.visibleMainWorktree(projectId: projectID)?.id
        else { return }
        if worktree != selectedWorktreeId { selectWorktree(id: worktree) }
        openPluginTab(PluginTabState(pluginID: pluginID, contributionID: tab.id, title: tab.title), worktreeID: worktree)
    }

    /// The instance whose configure panel Settings → Plugins shows (API 9): the selected project's, else any running one.
    func pluginConfigureHost(_ plugin: PluginManager.Plugin) -> PluginHost? {
        guard let manager = pluginManager else { return nil }
        if let projectID = selectedPluginProjectID, let host = manager.host(pluginID: plugin.id, projectID: projectID),
           host.state == .active {
            return host
        }
        return manager.hosts(for: plugin).map(\.host).first { $0.state == .active }
    }

    /// Slash prompts of the plugins running in `projectID`, in plugin order.
    func pluginPrompts(projectID: String) -> [PluginPromptItem] {
        guard let manager = pluginManager else { return [] }
        return PluginPromptItem.items(manager.plugins.map { plugin in
            let host = manager.host(pluginID: plugin.id, projectID: projectID)
            // Prompts the instance set at runtime (API 9) follow the manifest's.
            var manifest = plugin.manifest
            manifest.prompts += host?.runtimePrompts ?? []
            return (manifest, host?.state == .active)
        })
    }

    func expandPluginPrompt(_ item: PluginPromptItem, projectID: String, args: String, session: String) async -> PluginPromptExpansion {
        guard let host = pluginManager?.host(pluginID: item.pluginID, projectID: projectID) else {
            return .failed("The plugin that adds /\(item.prompt.name) is not running.")
        }
        return await host.expandPrompt(item.prompt.name, args: args, session: session)
    }

    /// Names of the plugins running in `projectID` that add context to its prompts, for the composer's chip.
    func pluginContextProviders(projectID: String) -> [String] {
        guard let manager = pluginManager else { return [] }
        return manager.plugins.compactMap {
            manager.host(pluginID: $0.id, projectID: projectID)?.providesContext == true ? $0.manifest.name : nil
        }
    }

    /// Context the plugins running in `worktree`'s project add to a prompt of `session`, one block per plugin, each
    /// naming its plugin so the agent can tell where it came from.
    func pluginPromptContext(session: String, worktree: Worktree) async -> [String] {
        guard let manager = pluginManager else { return [] }
        var blocks: [String] = []
        // ponytail: one provider after another; each is bounded by the per-call time limit, so a handful stays fast.
        for plugin in manager.plugins {
            guard let host = manager.host(pluginID: plugin.id, projectID: worktree.projectId), host.providesContext,
                  let text = await host.provideContext(session: session, worktree: worktree.id)
            else { continue }
            blocks.append("Context from the Alas plugin \(plugin.manifest.name):\n\n\(text)")
        }
        return blocks
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
        // A worktree row's target is the worktree; other badges carry theirs in the key, or none.
        let worktreeID = item.key.slot == .worktreeRow ? item.key.target : item.key.worktree
        openPluginTab(forCommand: command, pluginID: item.pluginID, projectID: item.projectID, worktreeID: worktreeID)
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

    func openPluginTab(_ tab: PluginTabState, worktreeID: String? = nil) {
        guard let worktreeId = worktreeID ?? selectedWorktreeId else { return }
        tabs.openOrFocusPluginTab(worktreeId: worktreeId, state: tab)
        activateWorktreeCenterTab(worktreeId: worktreeId, tabId: tab.id)
    }
}
