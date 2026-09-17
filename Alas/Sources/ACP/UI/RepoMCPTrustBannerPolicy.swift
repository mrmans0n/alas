import Foundation

/// Pure decision for the repo-MCP trust banner: which repo-defined servers
/// still need a trust decision. Kept out of the SwiftUI struct so tests can
/// call it without a view hierarchy.
struct RepoMCPTrustBannerDecision: Equatable {
    /// Repo-defined servers with no recorded decision, in file order.
    let pendingServers: [ProjectMCPServer]
    var isVisible: Bool { !pendingServers.isEmpty }
}

enum RepoMCPTrustBannerPolicy {
    /// Repo servers with no recorded trust decision for the given config.
    /// Remote projects and missing/broken repo configs stay silent: a
    /// `.malformed` file contributes no servers exactly like `.missing`.
    static func decision(project: ProjectConfig, repoConfig: RepoConfig?) -> RepoMCPTrustBannerDecision {
        guard project.host == nil else {
            return RepoMCPTrustBannerDecision(pendingServers: [])
        }
        let merge = RepoMCPResolver.merge(
            appServers: project.mcpServers,
            repoServers: repoConfig?.mcpServers ?? [],
            disabledNames: Set(project.disabledRepoMCPServers),
            trust: project.repoMCPTrust
        )
        return RepoMCPTrustBannerDecision(pendingServers: merge.pendingApproval)
    }
}
