import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasSessions

/// Which delegations a host's recovery takes on.
@_spi(AppHost) public enum DelegationRecoveryScope: Sendable {
    case all
    /// Children a paired Mac started, and messages waiting for them.
    case peerChildren

    func covers(_ record: ACPDelegationRecord?) -> Bool {
        // A child running on a paired Mac has nothing here to recover.
        guard record?.peerServerId == nil else { return false }
        return switch self {
        case .all: true
        case .peerChildren: record.flatMap { ACPPeerParent.serverId(from: $0.parentSessionId) } != nil
        }
    }
}

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

    /// Starts waking parents with the outcomes paired Macs' children leave
    /// behind. Call it once the projects and worktrees are loaded: finding a
    /// parent that has no live session, and telling a deleted parent from one
    /// whose worktree is not loaded yet, both go through them. Recovery's own
    /// order does not matter to it. The collector takes over the peers'
    /// outbox and availability signals and hands them to the coordinator's
    /// waits, so it must be the only one installing them. It need not have
    /// any peers yet: collection starts when `delegationPeers` is set.
    @_spi(AppHost) public func startCollectingPeerOutcomes() {
        guard !collectsPeerOutcomes else { return }
        collectsPeerOutcomes = true
        bindPeerOutboxCollector()
    }

    /// Replaces the collector with one over the current `delegationPeers`. A
    /// client replaced since cannot reach its peers, and the new one's signals
    /// would go nowhere. The cursor is stored, so nothing is collected twice.
    func bindPeerOutboxCollector() {
        guard collectsPeerOutcomes else { return }
        guard let peers = delegationPeers else {
            peerOutboxCollector = nil
            return
        }
        let orchestration = orchestration
        let collector = ACPPeerOutboxCollector(
            peers: peers,
            persistence: orchestrationPersistence,
            // The record lets delivery find a parent that has no live session.
            deliver: { await orchestration.deliverPendingMessages(to: $0.parentSessionId, callerParent: $0) },
            parentIsGone: { await orchestration.parentIsGone(of: $0) },
            outboxChanged: { orchestration.peerOutboxDidChange(serverId: $0) },
            availabilityChanged: { orchestration.peerAvailabilityChanged(serverId: $0) },
            collected: { orchestration.peerEntryCollected($0) },
            childBlocked: { [weak self] in self?.peerChildBlocked?($0, $1, $2) },
            retryStarts: { await orchestration.retryPeerStarts(serverId: $0) },
            schedule: { delay, work in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    await work()
                }
            }
        )
        peerOutboxCollector = collector
        collector.start()
    }

    /// Makes a peer's link being refused, or the peer being forgotten here,
    /// reach delegation: on the app and on a headless host, which has no
    /// collector but keeps outcomes for peers to collect.
    @_spi(AppHost) public func watchForRevokedPeers(of peers: RemotePeerManager) {
        peers.onPeerRevoked = { [weak self] serverId, name, forgotten in
            guard let orchestration = self?.orchestration else { return }
            Task { @MainActor in
                await orchestration.peerRevoked(serverId: serverId, name: name, forgotten: forgotten)
            }
        }
    }

    /// Finishes what delegations were doing when the host last stopped:
    /// children still being set up are started or failed, children with a
    /// turn in flight are attached again, and messages waiting for a session
    /// are delivered. Everything outside `scope` is left as it is. A host
    /// stopping meanwhile leaves the rest for its next start: what its
    /// shutdown refuses is not a failed child.
    @_spi(AppHost) public func recoverDelegations(_ scope: DelegationRecoveryScope = .all) async {
        guard let records = try? await orchestrationPersistence.incompleteDelegations() else { return }
        for record in records where scope.covers(record) {
            guard !isStopping else { return }
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
            rememberDelegatedSessionParent(childID: record.childSessionId, parentID: record.parentSessionId)
            let sessionAlreadyPersisted = await manager.persistedSessionRow(id: record.childSessionId) != nil
            if sessionAlreadyPersisted {
                _ = manager.placeholderSession(id: record.childSessionId)
                await manager.hydrateIfNeeded(id: record.childSessionId)
            } else {
                // What a paired Mac's child was allowed is not stored, and
                // this Mac's default could exceed it.
                let isPeerChild = ACPPeerParent.serverId(from: record.parentSessionId) != nil
                _ = manager.createSession(
                    id: record.childSessionId,
                    agentId: record.agentId,
                    autoRunDefault: !isPeerChild && environment.configuration().harness.acpAutoRunByDefault
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
            guard !isStopping else { return }
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
        await attachDelegatedChildrenWithPendingTurns(scope)
        await drainRecoveredDelegatedMessageTargets(scope)
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
    private func attachDelegatedChildrenWithPendingTurns(_ scope: DelegationRecoveryScope) async {
        guard let records = try? await orchestrationPersistence.readyDelegations() else { return }
        let tasks = records.filter(scope.covers).map { record in
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
              FileManager.default.fileExists(atPath: delegatedSessionsDB(childWorktreeId).path),
              let persistedQueue = try? await ACPSessionPersistence(
                  path: delegatedSessionsDB(childWorktreeId).path
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
        rememberDelegatedSessionParent(childID: childId, parentID: record.parentSessionId)
        await manager.hydrateIfNeeded(id: childId)
        // The attach repoints the child's socket link once it holds the
        // session's lease (the env providers run after lease acquisition).
        await manager.attach(to: childId, freshlyCreated: false)
        guard !isStopping else { return }
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

    private func drainRecoveredDelegatedMessageTargets(_ scope: DelegationRecoveryScope) async {
        guard let targetSessionIds = try? await orchestrationPersistence.pendingMessageTargetSessionIds() else {
            return
        }
        for sessionId in targetSessionIds {
            let childRecord = try? await orchestrationPersistence.parent(childSessionId: sessionId)
            guard scope.covers(childRecord) else { continue }
            if let childRecord {
                rememberDelegatedSessionParent(childID: childRecord.childSessionId, parentID: childRecord.parentSessionId)
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
