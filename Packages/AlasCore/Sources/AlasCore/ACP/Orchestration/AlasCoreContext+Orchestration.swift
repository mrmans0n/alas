import Foundation

extension AlasCoreContext {
    func makeOrchestrationCoordinator() -> ACPSessionOrchestrationCoordinator {
        ACPSessionOrchestrationCoordinator(
            environment: .init(
                persistence: orchestrationPersistence,
                instanceId: environment.instanceID,
                now: { Int64(Date().timeIntervalSince1970) },
                nowMillis: { Int64(Date().timeIntervalSince1970 * 1000) },
                blockedRequestKeys: { [weak self] sessionID in
                    guard let manager = self?.sessionManagers.values.first(where: { $0.liveSession(for: sessionID) != nil }) else { return [] }
                    return manager.blockedRequestKeys(for: sessionID)
                },
                escalationDelaySeconds: { [weak self] in
                    self?.environment.configuration().harness.acpDelegatedBlockerEscalationSeconds ?? 30
                },
                scheduleEscalationCheck: { delay, work in
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        await work()
                    }
                },
                makeID: { UUID().uuidString },
                worktree: { [weak self] id in self?.projectAndWorktree(withWorktreeId: id)?.worktree },
                existingWorktree: { [weak self] projectID, selector in
                    guard let worktrees = self?.projects.visibleWorktrees(projectId: projectID) else { return nil }
                    if let exact = worktrees.first(where: { $0.id == selector }) { return exact }
                    if case .matched(let worktree) = AlasCLIWorktreeResolver.resolve(target: selector, worktrees: worktrees) {
                        return worktree
                    }
                    return nil
                },
                configuredAgents: { [weak self] in
                    guard let agents = self?.environment.configuration().agents else { return [] }
                    let acpIDs = Set(ACPLaunchCatalog.specs.map(\.agentID))
                    return AgentConfiguredCatalog.enabled(builtinState: agents.builtinState, customs: agents.userAgents).map {
                        ACPOrchestrationAgent(id: $0.id, isEnabled: true, isACPCapable: acpIDs.contains($0.id))
                    }
                },
                availableAgents: { [weak self] _, worktree in
                    guard let self else { return [] }
                    let acpIDs = Set(ACPLaunchCatalog.specs.map(\.agentID))
                    return await environment.agentAvailability(in: worktree, core: self).agents.map {
                        ACPOrchestrationAgent(id: $0.id, isEnabled: true, isACPCapable: acpIDs.contains($0.id))
                    }
                },
                delegationAgents: { [weak self] _, worktree in
                    guard let self else { return [] }
                    let agents = environment.configuration().agents
                    let configured = AgentConfiguredCatalog.all(builtinState: agents.builtinState, customs: agents.userAgents)
                    var availability = await environment.agentAvailability(in: worktree, core: self)
                    if case .local = executionTarget(of: worktree) {
                        // The registry only refreshes on a rescan, so confirm
                        // the binaries are still there. Keeping the registry
                        // as a precondition means discovery never offers an
                        // agent that `session_new` would still reject.
                        let installed = await AgentDetector.scanCurrentEnvironment(agents: configured)
                        availability = .available(availability.agents.filter { installed.contains($0.id) })
                    }
                    let catalog = environment.modelCatalog
                    return ACPSessionOrchestrationPolicy.delegationAgents(
                        configured: configured,
                        acpAgentIDs: Set(ACPLaunchCatalog.specs.map(\.agentID)),
                        availability: availability,
                        catalog: { (catalog?.models(for: $0) ?? [], catalog?.launchReport(for: $0) ?? .notObserved) }
                    )
                },
                launchModels: { [weak self] agentID, worktree in
                    guard let self else { return nil }
                    let host: String? = switch executionTarget(of: worktree) {
                    case .local: nil
                    case .ssh(let host): host
                    }
                    return environment.modelCatalog?.launchModels(for: agentID, host: host)
                },
                sessionLocation: { [weak self] sessionID in self?.acpSessionLocation(sessionID) },
                referencedSessionLocation: { [weak self] sessionID, projectID in
                    await self?.acpReferencedSessionLocation(sessionID, projectID: projectID, loadingFullTranscript: true)
                },
                manager: { [weak self] worktree in self?.orchestrationManager(for: worktree) },
                newWorktreeDestination: { [weak self] projectID, branch in
                    guard let self, let project = projects.projects.first(where: { $0.id == projectID }) else { return nil }
                    let worktrees = environment.configuration().worktrees
                    return WorktreeLifecycle.delegatedWorktreeDestination(
                        rendered: WorktreePathTemplateRenderer.render(
                            template: worktrees.pathTemplate, worktreeRoot: worktrees.rootPath, repoName: project.name, branch: branch
                        ),
                        projectPath: project.path
                    )
                },
                createWorktree: { [weak self] projectID, branch, base, recordDestination in
                    guard let self else { return .failure(.init(message: "Alas is not available.")) }
                    return await environment.createDelegatedWorktree(
                        projectID: projectID, branch: branch, base: base, recordDestination: recordDestination, in: self
                    )
                },
                rememberParent: { [weak self] childID, parentID in
                    self?.environment.delegatedSessionParentChanged(childID: childID, parentID: parentID)
                },
                autoRunDefault: { [weak self] in self?.environment.configuration().harness.acpAutoRunByDefault ?? false },
                notifyChanged: {},
                admitsNewSessions: { [weak self] worktree in self?.projects.admitsNewWork(in: worktree) ?? false }
            )
        )
    }

    /// Where agents for `worktree` run: on its project's host, or here.
    func executionTarget(of worktree: Worktree) -> AgentExecutionTarget {
        AgentExecutionTarget.resolve(
            worktreePath: worktree.path,
            remoteHost: projectAndWorktree(withWorktreeId: worktree.id)?.project.host
        )
    }

    /// A stored, unarchived session of `projectID` that a delegation names,
    /// loaded and retained until `release` is called.
    @_spi(AppHost) public func acpReferencedSessionLocation(
        _ sessionID: String, projectID: String, loadingFullTranscript: Bool
    ) async -> ACPSessionOrchestrationCoordinator.SessionLocation? {
        for (worktree, manager) in await acpProjectManagers(projectId: projectID, loadingRecentRows: false) {
            // Check both the store, which another instance may have archived
            // since this one cached the row, and the cached row. Queued local
            // writes land first, so a just-created session is in the store
            // and a local archive is in both.
            await manager.flushPersistence()
            guard let stored = try? await manager.persistence.loadSession(id: sessionID), !stored.archived,
                  let cached = await manager.persistedSessionRow(id: sessionID), !cached.archived,
                  manager.placeholderSession(id: sessionID) != nil
            else { continue }
            manager.retainSession(id: sessionID)
            let release: () -> Void = { [weak manager] in manager?.releaseSession(id: sessionID) }
            await manager.hydrateIfNeeded(id: sessionID)
            if loadingFullTranscript { await manager.awaitBackfill(id: sessionID) }
            guard manager.liveSession(for: sessionID) != nil else {
                release()
                return nil
            }
            return .init(
                origin: ACPOrchestrationSessionOrigin(sessionId: sessionID, projectId: worktree.projectId, worktreeId: worktree.id),
                manager: manager,
                release: release
            )
        }
        return nil
    }
}
