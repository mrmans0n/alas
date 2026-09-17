import Foundation

extension AppState {
    /// The repo-local `.alas/config.json` for a worktree, or nil when the repo
    /// has none. A config that is present but broken also reads as nil here —
    /// `RepoConfigStore` logs that case.
    func repoConfig(worktreeRoot: URL) -> RepoConfig? {
        repoConfigStore.config(worktreeRoot: worktreeRoot)
    }

    /// The icon a project displays once its repo's `.alas/` layer is applied.
    ///
    /// An explicit app icon and every remote project keep their own icon and
    /// never touch the filesystem. Otherwise the repo's primary checkout is
    /// consulted, so the result does not depend on which worktree has focus.
    ///
    /// This runs on sidebar render paths and staging a repo icon reads and
    /// hashes the image, so the icon is looked up first against a stats-only
    /// probe of every candidate file: a hit returns without reading anything,
    /// and the resolve below runs only on a miss. The key covers the whole
    /// candidate chain, so a fallback that becomes usable — or a head file that
    /// becomes unusable while a fallback changes — is picked up on the next
    /// render.
    func effectiveIcon(for project: ProjectConfig) -> ProjectIcon {
        guard project.host == nil else { return project.icon }
        let checkout = URL(fileURLWithPath: project.path, isDirectory: true)
        let repoConfig = repoConfig(worktreeRoot: checkout)
        let appIcon = project.icon

        let chain = RepoIconResolver.sourceChain(
            repoConfig: repoConfig,
            appIcon: appIcon,
            primaryCheckout: checkout,
            store: repoConfigStore
        )
        guard !chain.isEmpty else {
            // No usable repo file: resolving costs the same stats and reads
            // nothing, so there is nothing to cache either.
            return RepoIconResolver.resolve(
                appIcon: appIcon,
                projectID: project.id,
                repoConfig: repoConfig,
                primaryCheckout: checkout,
                store: repoConfigStore,
                stagingRoot: repoIconStagingRoot
            ).icon
        }

        let key = RepoIconDisplayCache.Key(chain: chain, appIcon: appIcon)
        if let cached = repoIconDisplayCache.icon(for: key, projectID: project.id) {
            return cached
        }

        let resolution = RepoIconResolver.resolve(
            appIcon: appIcon,
            projectID: project.id,
            repoConfig: repoConfig,
            primaryCheckout: checkout,
            store: repoConfigStore,
            stagingRoot: repoIconStagingRoot
        )
        repoIconDisplayCache.store(resolution, chain: chain, appIcon: appIcon, projectID: project.id)
        return resolution.icon
    }

    /// Records trust decisions for a batch of repo-defined MCP servers.
    func approveRepoMCPServers(projectId: String, servers: [ProjectMCPServer]) {
        for server in servers {
            projectsManager.setRepoMCPTrust(
                projectId: projectId,
                hash: RepoMCPTrust.hash(for: server),
                state: .approved
            )
        }
        saveProjects()
    }

    /// Approves a repo-defined MCP server by name, so a declined server can be
    /// reconsidered from the MCP status control without editing projects.json.
    /// Resolves the server from the worktree's repo config. Refuses when the
    /// name's current config is not the recorded declined one: a changed
    /// definition is a new, unreviewed decision and belongs to the trust
    /// banner instead of reusing the stale row's approval.
    func approveRepoMCPServer(projectId: String, worktreeRoot: URL, name: String) {
        guard let server = repoConfig(worktreeRoot: worktreeRoot)?.mcpServers
            .first(where: { $0.name == name }),
            projectsManager.repoMCPTrustState(projectId: projectId, for: server) == .declined
        else {
            return
        }
        approveRepoMCPServers(projectId: projectId, servers: [server])
    }

    /// Declines a batch of repo-defined MCP servers.
    func declineRepoMCPServers(projectId: String, servers: [ProjectMCPServer]) {
        for server in servers {
            projectsManager.setRepoMCPTrust(
                projectId: projectId,
                hash: RepoMCPTrust.hash(for: server),
                state: .declined
            )
        }
        saveProjects()
    }

    /// Enables/disables a repo-defined MCP server for this project by name.
    func setRepoMCPServerDisabled(projectId: String, name: String, disabled: Bool) {
        projectsManager.setRepoMCPServerDisabled(
            projectId: projectId,
            name: name,
            disabled: disabled
        )
        saveProjects()
    }

    /// Which repo-defined servers still need a trust decision for this
    /// worktree's session. Remote projects stay silent.
    func repoMCPTrustDecision(
        worktreeRoot: URL,
        project: ProjectConfig
    ) -> RepoMCPTrustBannerDecision {
        RepoMCPTrustBannerPolicy.decision(
            project: project,
            repoConfig: project.host == nil ? repoConfig(worktreeRoot: worktreeRoot) : nil
        )
    }

    /// Display name of the repo default agent (`.alas/config.json`) when
    /// the id names an installed, enabled agent. Nil otherwise.
    func repoDefaultAgentDisplayName(repoPath: String, agents: [AgentDefinition]) -> String? {
        guard let candidate = repoConfig(
            worktreeRoot: URL(fileURLWithPath: repoPath, isDirectory: true)
        )?.defaultAgent,
           let agent = agents.first(where: { $0.id == candidate }),
           agent.isEnabled else {
            return nil
        }
        return agent.displayName
    }
}
