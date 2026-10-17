import Foundation

extension SessionsAPI {
    /// The enabled ACP agents a session of `projectID` can start: on a
    /// project with its own host, only those that can run there.
    public func agents(projectID: String) -> [AgentDefinition] {
        let remote = core.projects.projects.first { $0.id == projectID }?.host != nil
        return core.environment.enabledAgents().filter { agent in
            ACPLaunchCatalog.spec(for: agent.id) != nil && (!remote || agent.canRunOnRemoteHost)
        }
    }

    /// The text of the latest agent message in loaded session `sessionID`;
    /// nil when it has none or is not loaded.
    public func lastAgentReply(_ sessionID: String) -> String? {
        guard let messages = core.sessionManagers.values.lazy.compactMap({ $0.liveSession(for: sessionID) }).first?.transcript.messages
        else { return nil }
        for message in messages.reversed() {
            guard case .agent(_, _, let text) = message else { continue }
            let trimmed = text.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

extension WorktreesAPI {
    /// Where worktree `worktreeID` of `projectID` lives: on this Mac, or on
    /// its SSH host at a real path there.
    public func location(of worktreeID: String, projectID: String) -> PluginWorktreeLocation? {
        guard let worktree = core.projects.worktrees(projectId: projectID).first(where: { $0.id == worktreeID }) else { return nil }
        if let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path) {
            return .remote(host: host, root: RemotePath.realPath(worktree.path.path))
        }
        return .local(worktree.path)
    }
}
