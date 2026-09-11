import Foundation

struct AttentionReturnDestination {
    let worktreeID: String?
    let activeTabID: TabID?
}

extension AppState {
    var attentionAggregation: AttentionAggregation {
        let document = attentionStore.document
        let liveSignals = currentAttentionSignals.compactMap { signal -> AttentionLiveSignal? in
            guard let observation = document.observations[signal.sourceKey],
                  observation.isActive, observation.fingerprint == signal.fingerprint,
                  let eventID = observation.eventID else { return nil }
            return AttentionLiveSignal(eventID: eventID, signal: signal, isCurrentlyActive: true)
        }
        return AttentionSignalAggregator.aggregate(
            liveSignals: liveSignals, document: document, worktrees: attentionWorktrees
        )
    }

    var attentionWorktrees: [AttentionWorktree] {
        projects.flatMap { project in
            projectsManager.worktrees(projectId: project.id).map {
                AttentionWorktree(worktree: $0, project: project)
            }
        }
    }

    /// Read producer-owned state each time; persisted observations only identify occurrences.
    var currentAttentionSignals: [AttentionSignal] {
        var signals = harness.activityBySession.flatMap { sessionID, activity -> [AttentionSignal] in
            guard let worktree = attentionWorktree(forSessionID: sessionID),
                  let context = attentionContext(for: worktree) else { return [] }
            return AttentionProducer.harness(
                sessionID: sessionID, agent: activity.agent, state: activity.state,
                body: activity.lastBody, owner: context.owner, display: context.display
            ).compactMap(\.activeSignal)
        }
        for entry in attentionWorktrees {
            for failure in runScriptFailureQueue.failures(for: entry.worktree.id) {
                signals += AttentionProducer.script(
                    failure: failure,
                    owner: .make(worktree: entry.worktree, project: entry.project),
                    display: entry.resolved.display
                ).compactMap(\.activeSignal)
            }
        }
        return signals
    }

    func openAttentionInbox() {
        guard !isAttentionInboxOpen else { return }
        attentionReturnDestination = AttentionReturnDestination(
            worktreeID: selectedWorktreeId,
            activeTabID: selectedWorktreeId.flatMap { tabs.activeTabId(forWorktree: $0) }
        )
        isAttentionInboxOpen = true
    }

    func closeAttentionInbox() {
        guard isAttentionInboxOpen else { return }
        isAttentionInboxOpen = false
        guard let destination = attentionReturnDestination else { return }
        attentionReturnDestination = nil
        selectedWorktreeId = destination.worktreeID
        if let worktreeID = destination.worktreeID {
            if let tabID = destination.activeTabID,
               tabs.tabs(forWorktree: worktreeID).contains(where: { $0.id == tabID }) {
                tabs.activate(worktreeId: worktreeID, tabId: tabID)
            } else if destination.activeTabID == nil {
                tabs.clearActiveTab(worktreeId: worktreeID)
            }
        }
    }

    /// Snapshot reconciliation cannot invent events when previous acknowledgments are unknown.
    func reconcileAttention(liveSignals: [AttentionSignal], at date: Date = Date()) {
        for signal in liveSignals {
            if attentionStore.loadError != nil,
               attentionStore.document.observations[signal.sourceKey] == nil {
                if attentionSuppressedStartupSignals[signal.sourceKey] == nil {
                    attentionSuppressedStartupSignals[signal.sourceKey] = signal.fingerprint
                }
            }
            observeAttention(.active(signal), at: date)
        }
    }

    func observeAttention(_ observation: AttentionObservation, at date: Date = Date()) {
        switch observation {
        case .active(let signal):
            guard attentionSuppressedStartupSignals[signal.sourceKey] != signal.fingerprint else { return }
            attentionSuppressedStartupSignals[signal.sourceKey] = nil
            registerAttentionAlias(for: signal)
        case .inactive(let sourceKey):
            attentionSuppressedStartupSignals[sourceKey] = nil
        }
        attentionStore.observe(observation, at: date)
    }

    func attentionContext(for worktree: Worktree) -> (owner: AttentionWorktreeIdentity, display: AttentionWorktreeDisplaySnapshot)? {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return nil }
        return (.make(worktree: worktree, project: project), AttentionWorktree(worktree: worktree, project: project).resolved.display)
    }

    func attentionWorktree(for owner: AttentionWorktreeIdentity) -> Worktree? {
        let worktrees = attentionWorktrees
        let resolver = AttentionWorktreeResolver(worktrees: worktrees, aliases: attentionStore.document.aliases)
        guard let resolved = resolver.resolve(owner) else { return nil }
        return worktrees.first { $0.worktree.id == resolved.id && $0.project.id == resolved.projectID }?.worktree
    }

    func attentionWorktree(forSessionID sessionID: String) -> Worktree? {
        let worktrees = attentionWorktrees
        if let session = terminal.registry.session(for: sessionID),
           let worktree = worktrees.first(where: { $0.worktree.id == session.worktreeId })?.worktree {
            return worktree
        }
        return worktrees.first { entry in
            tabs.tabs(forWorktree: entry.worktree.id).contains { tab in
                switch tab {
                case .terminal(let state):
                    state.root.leaves().contains { $0.id == sessionID || $0.sessionId == sessionID }
                case .acpSession(let state):
                    state.sessionId == sessionID
                default:
                    false
                }
            }
        }?.worktree
    }

    func observeHarnessAttention(_ transition: HarnessActivityTransition) {
        let firstObservation = attentionObservedHarnessSessions.insert(transition.sessionID).inserted
        // Forget can arrive after the tab or session owner has already been removed.
        guard let state = transition.state else {
            for suffix in ["awaiting", "permission"] {
                observeAttention(.inactive(sourceKey: .init(rawValue: "session:\(transition.sessionID):\(suffix)")), at: transition.occurredAt)
            }
            return
        }
        guard let worktree = attentionWorktree(forSessionID: transition.sessionID),
              let context = attentionContext(for: worktree) else { return }
        let observations = AttentionProducer.harness(
            sessionID: transition.sessionID, agent: transition.agent, state: state,
            body: transition.body, owner: context.owner, display: context.display
        )
        if firstObservation, attentionStore.loadError != nil {
            reconcileAttention(liveSignals: observations.compactMap(\.activeSignal), at: transition.occurredAt)
        } else {
            for observation in observations { observeAttention(observation, at: transition.occurredAt) }
        }
        if state == .idle, !(firstObservation && attentionStore.loadError != nil) {
            attentionStore.appendHistory(AttentionProducer.finished(
                sessionID: transition.sessionID, agent: transition.agent,
                owner: context.owner, display: context.display
            ), at: transition.occurredAt)
        }
    }

    private func registerAttentionAlias(for signal: AttentionSignal) {
        guard signal.owner.lineageID != nil else { return }
        let legacyOwner = AttentionWorktreeIdentity(
            projectID: signal.owner.projectID, location: signal.owner.location,
            lineageID: nil, legacyPath: signal.display.path
        )
        attentionStore.registerAlias(from: legacyOwner, to: signal.owner)
    }
}
