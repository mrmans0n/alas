import Foundation

/// Merges repo-defined MCP servers into the effective per-session list.
/// App-level servers always win by name; repo servers attach only when
/// approved, staying quiet when declined or disabled. Pure: no filesystem,
/// no logging, no persisted state.
enum RepoMCPResolver {

    enum SkipReason: Equatable {
        /// An app-level server of the same name replaces the repo one.
        case shadowedByApp
        /// The user disabled this repo server for the project.
        case disabled
        /// The user declined this server's config.
        case declined
        /// No trust decision recorded yet - drives the approval banner.
        case notApproved
    }

    struct Skipped: Equatable {
        var server: ProjectMCPServer
        var reason: SkipReason
    }

    struct Result: Equatable {
        /// App servers plus repo servers cleared to attach, in stable order.
        var active: [ProjectMCPServer]
        var skipped: [Skipped]
        /// Repo servers with no recorded trust decision yet.
        var pendingApproval: [ProjectMCPServer]
    }

    /// Rule order per repo server: shadowed by an app-level name first, then
    /// the disable list, then the trust state. Assumes the repo list is
    /// already deduplicated upstream; duplicates are processed independently.
    static func merge(
        appServers: [ProjectMCPServer],
        repoServers: [ProjectMCPServer],
        disabledNames: Set<String>,
        trust: [String: RepoMCPTrustState]
    ) -> Result {
        let appNames = Set(appServers.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        var result = Result(active: appServers, skipped: [], pendingApproval: [])

        for server in repoServers {
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if appNames.contains(name) {
                result.skipped.append(Skipped(server: server, reason: .shadowedByApp))
            } else if disabledNames.contains(name) {
                result.skipped.append(Skipped(server: server, reason: .disabled))
            } else {
                switch trust[RepoMCPTrust.hash(for: server)] {
                case .approved:
                    result.active.append(server)
                case .declined:
                    result.skipped.append(Skipped(server: server, reason: .declined))
                case nil:
                    result.pendingApproval.append(server)
                    result.skipped.append(Skipped(server: server, reason: .notApproved))
                }
            }
        }
        return result
    }
}