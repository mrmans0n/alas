import Foundation

/// Where a gateway reads the lists it serves. `host(_:)` reads them from the
/// host; tests substitute reads they can hold back to pin ordering.
@_spi(Testing) public struct RemoteGatewayReads {
    public var worktrees: @MainActor () async -> [RemoteWorktreeOption]
    public var projects: @MainActor () async -> [RemoteProjectOption]
    public var branches: @MainActor (_ projectID: String) async -> RemoteBranchListResult
    public var agents: @MainActor () -> [RemoteAgentOption]

    public init(
        worktrees: @escaping @MainActor () async -> [RemoteWorktreeOption],
        projects: @escaping @MainActor () async -> [RemoteProjectOption],
        branches: @escaping @MainActor (_ projectID: String) async -> RemoteBranchListResult,
        agents: @escaping @MainActor () -> [RemoteAgentOption]
    ) {
        self.worktrees = worktrees
        self.projects = projects
        self.branches = branches
        self.agents = agents
    }

    /// The host's lists; empty without a host.
    public static func host(_ host: AlasHost?) -> RemoteGatewayReads {
        guard let core = host?.core else {
            return RemoteGatewayReads(
                worktrees: { [] }, projects: { [] },
                branches: { _ in .failure("Repository is no longer available.") }, agents: { [] }
            )
        }
        return RemoteGatewayReads(
            worktrees: { [weak core] in await core?.remoteWorktreeOptions() ?? [] },
            projects: { [weak core] in core?.remoteProjectOptions() ?? [] },
            branches: { [weak core] projectID in
                await core?.remoteBranches(projectID: projectID) ?? .failure("Repository is no longer available.")
            },
            agents: { [weak core] in core?.remoteAgentOptions() ?? [] }
        )
    }
}
