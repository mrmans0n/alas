import Foundation

extension AppState {
    /// Records a finished turn of a session of `owner`, and the usage limit that stopped it, then tells plugins.
    func recordTurnUsage(_ completion: ACPTurnCompletion, owner: SessionOwnerID) {
        guard let store = usageHistory, let session = acpManager(for: owner)?.liveSession(for: completion.sessionId) else { return }
        let worktree = owner.worktreeID
        let project = worktree.flatMap { self.worktree(withId: $0)?.projectId }
        let agent = session.agentId
        // The model the prompt went out with: a stopped turn's result can come after the user switched models.
        let model = completion.model ?? session.currentModel
        // A turn's usage can be held for an earlier one's, so it ended when the runner says.
        let endedAt = completion.endedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
        let episode = completion.result == .limited ? session.usageLimit.map {
            UsageLimitEpisode($0, session: completion.sessionId, project: project, worktree: worktree, agent: session.agentId)
        } : nil
        // Everything but the cost is captured now, so the row is written even if the session goes away meanwhile. In
        // completion order per session, since each turn's cost is measured from the previous row's.
        usageRecording.enqueue(completion.sessionId) { [weak self] in
            let input = UsageTurnInput(
                completion: completion, agent: agent, model: model, cumulativeCost: await completion.cost?.resolve(),
                project: project, worktree: worktree, endedAt: endedAt)
            if let episode { try? await store.record(episode) }
            guard let turn = try? await store.record(input) else { return }
            await self?.pluginManager?.turnFinished(turn)
        }
    }
}
