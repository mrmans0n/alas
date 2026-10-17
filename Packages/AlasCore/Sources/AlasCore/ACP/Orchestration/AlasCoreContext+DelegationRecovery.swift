import Foundation

extension AlasCoreContext {
    /// Delivers the messages waiting for session `sessionID`, one delivery
    /// at a time per session.
    @_spi(AppHost) public func deliverPendingDelegatedMessages(to sessionID: String, manager: ACPSessionManager) async {
        await orchestration.deliverPendingMessages(to: sessionID, manager: manager)
    }

    /// A message arrived for session `sessionID`: it is delivered, and the
    /// session counts it as work toward its next prompt until then.
    @_spi(AppHost) public func delegatedMessageAvailable(_ sessionID: String, in manager: ACPSessionManager) {
        let session = manager.liveSession(for: sessionID)
        session?.nextPromptWorkCount += 1
        Task { @MainActor [weak self] in
            defer { session?.nextPromptWorkCount -= 1 }
            await self?.deliverPendingDelegatedMessages(to: sessionID, manager: manager)
        }
    }

    /// The session manager delegation uses for `worktree`. One busy with an
    /// operation stays, as the app's own lookup keeps it.
    func orchestrationManager(for worktree: Worktree) -> ACPSessionManager? {
        (try? environment.sessionManager(for: worktree, in: self)) ?? sessionManagers[.worktree(worktree.id)]
    }

    func worktree(withId id: String) -> Worktree? {
        projectAndWorktree(withWorktreeId: id)?.worktree
    }

    /// Every worktree a project lists, hidden ones included.
    func allWorktreeIds() -> Set<String> {
        Set(projects.projects.flatMap { projects.worktrees(projectId: $0.id).map(\.id) })
    }

    /// Finishes what delegations were doing when the host last stopped:
    /// children still being set up are started or failed, children with a
    /// turn in flight are attached again, and messages waiting for a session
    /// are delivered.
    @_spi(AppHost) public func recoverDelegations() async {
        guard let records = try? await orchestrationPersistence.incompleteDelegations() else { return }
        for record in records {
            let worktree = record.childWorktreeId.flatMap(worktree(withId:))
                ?? worktree(atPersistedDestinationPath: record.worktreeRequest.destinationPath)
            guard let worktree,
                  let manager = orchestrationManager(for: worktree)
            else {
                await orchestration.markChildFailed(
                    childSessionId: record.childSessionId,
                    message: "Alas stopped before delegated session setup completed."
                )
                continue
            }
            if record.childWorktreeId != worktree.id {
                try? await orchestrationPersistence.updateChildWorktree(
                    childSessionId: record.childSessionId,
                    worktreeId: worktree.id,
                    phase: .starting,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
            }
            environment.delegatedSessionParentChanged(childID: record.childSessionId, parentID: record.parentSessionId)
            let sessionAlreadyPersisted = await manager.persistedSessionRow(id: record.childSessionId) != nil
            if sessionAlreadyPersisted {
                _ = manager.placeholderSession(id: record.childSessionId)
                await manager.hydrateIfNeeded(id: record.childSessionId)
            } else {
                _ = manager.createSession(
                    id: record.childSessionId,
                    agentId: record.agentId,
                    autoRunDefault: environment.configuration().harness.acpAutoRunByDefault
                )
            }
            let restoredPendingPrompt = record.pendingInitialPrompt != nil
            // With a model selection, the initial prompt waits until the
            // selection is reapplied on the attached session, below. A crash
            // after it was queued but before the child was marked ready leaves
            // it in the hydrated queue, where attach would dispatch it before
            // the selection is re-verified, whether or not the record's
            // pending copy was already cleared.
            var promptAwaitingSelection: String?
            if record.modelSelection != nil {
                // A restored tab may already be attaching this session; its
                // attach arms the same hold, and with it held the prompt can
                // be withheld even from an attached runner.
                manager.holdPromptsForDelegatedSelection(record.childSessionId)
                let withheld = manager.withholdQueuedDelegatedPrompt(
                    messageId: orchestration.initialPromptSource(for: record).messageId,
                    in: record.childSessionId
                )
                promptAwaitingSelection = record.pendingInitialPrompt ?? withheld
            }
            if promptAwaitingSelection != nil {
                // Queued once the selection is acknowledged.
            } else if let prompt = record.pendingInitialPrompt {
                let accepted = await manager.enqueueDelegatedPrompt(
                    text: prompt,
                    source: ACPDelegatedPromptSource(
                        sessionId: record.parentSessionId,
                        messageId: ACPSessionOrchestrationPolicy.initialPromptMessageId(
                            childSessionId: record.childSessionId
                        )
                    ),
                    into: record.childSessionId
                )
                guard accepted else {
                    await orchestration.markChildFailed(
                        childSessionId: record.childSessionId,
                        message: "Could not restore delegated session prompt."
                    )
                    continue
                }
            } else if !sessionAlreadyPersisted {
                await orchestration.markChildFailed(
                    childSessionId: record.childSessionId,
                    message: "Could not restore delegated session prompt."
                )
                continue
            }
            await manager.attach(to: record.childSessionId, freshlyCreated: !sessionAlreadyPersisted)
            guard let session = manager.liveSession(for: record.childSessionId),
                  session.agentState == .ready
            else {
                await orchestration.markChildFailed(
                    childSessionId: record.childSessionId,
                    message: recoveredDelegatedSessionFailureMessage(manager.liveSession(for: record.childSessionId))
                )
                continue
            }
            if let prompt = promptAwaitingSelection, let selection = record.modelSelection {
                guard await orchestration.queueInitialPromptAfterModelSelection(
                    selection, record: record, prompt: prompt, manager: manager
                ) else { continue }
            }
            if restoredPendingPrompt {
                try? await orchestrationPersistence.clearPendingInitialPrompt(
                    childSessionId: record.childSessionId,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
            }
            let markedReady = (try? await orchestrationPersistence.updatePhase(
                childSessionId: record.childSessionId,
                phase: .ready,
                failureMessage: nil,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )) != nil
            // Held until `.ready` is durable, as in the coordinator's start.
            if record.modelSelection != nil, markedReady {
                manager.releaseDelegatedSelectionHold(record.childSessionId)
            }
            await deliverPendingDelegatedMessages(to: record.childSessionId, manager: manager)
        }
        await attachDelegatedChildrenWithPendingTurns()
        await drainRecoveredDelegatedMessageTargets()
    }

    /// Re-attaches ready delegated children that had a turn in flight, or
    /// waiting to go out, when Alas last quit. Their adapters run in brokers
    /// that survive the quit, so a child may still be working, or may have
    /// finished while the app was down. Nothing else attaches a child without
    /// an open tab, and without an attach its turn completion never reaches
    /// the parent and its `session_send` has no live session to come from.
    /// The attach repoints the child's socket link (`acpSessionSocketPath`)
    /// and resends the queued prompt under its original broker operation, so
    /// the broker hands back the running or finished turn and the usual
    /// outcome follows.
    private func attachDelegatedChildrenWithPendingTurns() async {
        guard let records = try? await orchestrationPersistence.readyDelegations() else { return }
        let tasks = records.map { record in
            Task { @MainActor [weak self] in
                await self?.attachDelegatedChildWithPendingTurn(record)
            }
        }
        for task in tasks { await task.value }
    }

    private func attachDelegatedChildWithPendingTurn(_ record: ACPDelegationRecord) async {
        let childId = record.childSessionId
        // Read the queue from the store the child was persisted in, which
        // stays keyed by the worktree id recorded at creation even if the
        // worktree is no longer known under it.
        guard let childWorktreeId = record.childWorktreeId,
              FileManager.default.fileExists(atPath: Paths.acpSessionsDB(forWorktreeId: childWorktreeId).path),
              let persistedQueue = try? await ACPSessionPersistence(
                  path: Paths.acpSessionsDB(forWorktreeId: childWorktreeId).path
              ).loadQueue(sessionId: childId),
              ACPSessionOrchestrationPolicy.needsRestartAttach(phase: record.phase, queueHead: persistedQueue.first)
        else { return }
        guard let worktree = worktree(withId: childWorktreeId),
              let manager = orchestrationManager(for: worktree),
              await manager.persistedSessionRow(id: childId) != nil,
              manager.placeholderSession(id: childId) != nil
        else {
            // The parent is waiting on this turn; say it is gone rather than
            // leave the child `ready` forever.
            await orchestration.markChildFailed(
                childSessionId: childId,
                message: "Alas restarted, and the delegated session's worktree is no longer available."
            )
            return
        }
        environment.delegatedSessionParentChanged(childID: childId, parentID: record.parentSessionId)
        await manager.hydrateIfNeeded(id: childId)
        // The attach repoints the child's socket link once it holds the
        // session's lease (the env providers run after lease acquisition).
        await manager.attach(to: childId, freshlyCreated: false)
        // Another live instance holding the child's lease runs it and owns
        // the outcome. Anything else that is not a ready writer is a failed
        // attach: a failure releases the lease, so ownership alone cannot
        // tell the two apart.
        guard !manager.isMirror(sessionId: childId) else { return }
        let session = manager.liveSession(for: childId)
        let attachFailure = manager.isWriter(for: childId) && session?.agentState == .ready
            ? nil
            : recoveredDelegatedSessionFailureMessage(session)
        if let loss = ACPSessionOrchestrationPolicy.restartedTurnLoss(
            attachFailure: attachFailure,
            queueHead: session?.queue.first
        ) {
            await orchestration.markChildFailed(childSessionId: childId, message: loss)
        }
    }

    private func recoveredDelegatedSessionFailureMessage(_ session: ACPSession?) -> String {
        guard let session else { return "Could not restore delegated ACP session." }
        switch session.setupState {
        case .needsSetup(let reason), .setupError(let reason):
            return reason
        case .needsAuth(_, let reason):
            return reason ?? "ACP session needs authentication."
        case .checking, .ready:
            break
        }
        if case .failed(let reason) = session.agentState {
            return reason
        }
        return "Could not restore delegated ACP session."
    }

    private func drainRecoveredDelegatedMessageTargets() async {
        guard let targetSessionIds = try? await orchestrationPersistence.pendingMessageTargetSessionIds() else {
            return
        }
        for sessionId in targetSessionIds {
            let childRecord = try? await orchestrationPersistence.parent(childSessionId: sessionId)
            if let childRecord {
                environment.delegatedSessionParentChanged(childID: childRecord.childSessionId, parentID: childRecord.parentSessionId)
            }
            guard let manager = await acpManagerForPersistedSession(
                sessionId: sessionId,
                preferredWorktreeId: childRecord?.childWorktreeId ?? childRecord?.worktreeRequest.worktreeId
            ) else { continue }
            await deliverPendingDelegatedMessages(to: sessionId, manager: manager)
            await scheduleRecoveredDelegatedMessageRetry(to: sessionId, manager: manager)
        }
    }

    private func scheduleRecoveredDelegatedMessageRetry(to sessionId: String, manager: ACPSessionManager) async {
        guard let remaining = try? await orchestrationPersistence.pendingMessages(targetSessionId: sessionId),
              !remaining.isEmpty
        else { return }
        Task { @MainActor [weak self, weak manager] in
            try? await Task.sleep(nanoseconds: 61_000_000_000)
            guard let self, let manager else { return }
            await self.deliverPendingDelegatedMessages(to: sessionId, manager: manager)
        }
    }

    private func acpManagerForPersistedSession(
        sessionId: String,
        preferredWorktreeId: String?
    ) async -> ACPSessionManager? {
        var worktreeIds: [String] = []
        if let preferredWorktreeId {
            worktreeIds.append(preferredWorktreeId)
        }
        worktreeIds.append(contentsOf: allWorktreeIds().filter { $0 != preferredWorktreeId }.sorted())
        for worktreeId in worktreeIds {
            guard let worktree = worktree(withId: worktreeId),
                  let manager = orchestrationManager(for: worktree),
                  let row = await manager.persistedSessionRow(id: sessionId),
                  !row.archived
            else { continue }
            _ = manager.placeholderSession(id: sessionId)
            await manager.hydrateIfNeeded(id: sessionId)
            return manager
        }
        return nil
    }

    private func worktree(atPersistedDestinationPath path: String?) -> Worktree? {
        guard let path, !path.isEmpty else { return nil }
        let targetPath = URL(fileURLWithPath: path).standardizedFileURL.path
        for project in projects.projects {
            if let worktree = projects.worktrees(projectId: project.id).first(where: {
                $0.path.standardizedFileURL.path == targetPath
            }) {
                return worktree
            }
        }
        return nil
    }
}
