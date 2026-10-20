import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasACP

extension SessionsAPI {
    /// The enabled ACP agents a session of `projectID` can start: on a
    /// project with its own host, only those that can run there.
    public func agents(projectID: String) -> [AgentDefinition] {
        let remote = core.projects.projects.first { $0.id == projectID }?.host != nil
        return core.environment.enabledAgents().filter { agent in
            ACPLaunchCatalog.spec(for: agent.id) != nil && (!remote || agent.canRunOnRemoteHost)
        }
    }

    /// The agent a new session of `projectID` in `worktreeRoot` starts when
    /// none is named: the project's own, else the repository's enabled
    /// default (local projects only), else the global one. Nil when that
    /// agent cannot run on the project's host.
    public func defaultAgent(projectID: String, worktreeRoot: URL) -> String? {
        let project = core.projects.projects.first { $0.id == projectID }
        let scripts = project?.startupScripts ?? .defaults
        var repoDefault: String?
        if project?.host == nil,
           let candidate = core.repoConfigStore.config(worktreeRoot: worktreeRoot)?.defaultAgent,
           core.environment.agent(id: candidate)?.isEnabled == true {
            repoDefault = candidate
        }
        let resolved = scripts.defaultAgentID(
            repoDefaultAgent: repoDefault,
            globalAgentID: core.environment.configuration().agents.worktreeAutoLaunch.agentId
        )
        if project?.host != nil, let resolved, core.environment.agent(id: resolved)?.canRunOnRemoteHost == false {
            return nil
        }
        return resolved
    }

    /// The text of the latest agent message in loaded session `sessionID`,
    /// of `owner` when given (ids are not unique across owners); nil when it
    /// has none or is not loaded.
    public func lastAgentReply(_ sessionID: String, owner: SessionOwnerID? = nil) -> String? {
        guard let messages = managers(of: owner).lazy.compactMap({ $0.liveSession(for: sessionID) }).first?.transcript.messages
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
    /// The worktree's Git status as last scanned: its changed files and
    /// conflicts.
    public func gitStatus(of worktree: Worktree) -> WorktreeDirtyState {
        WorktreeStatusStore.shared.status(forPath: worktree.path.path)
    }

    /// Whether `worktree` is its project's main checkout.
    public func isMain(_ worktree: Worktree) -> Bool {
        core.projects.projects.first { $0.id == worktree.projectId }.map { core.projects.isMain(worktree, in: $0) } ?? false
    }

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
