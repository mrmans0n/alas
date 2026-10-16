import Foundation

/// What a gateway asks of the host besides session verbs: the lists it
/// serves and the sessions it creates. `host(_:caller:)` asks the host; tests
/// substitute calls they can hold back to pin ordering.
@_spi(Testing) public struct RemoteGatewayHostCalls {
    public var worktrees: @MainActor () async -> [RemoteWorktreeOption]
    public var projects: @MainActor () async -> [RemoteProjectOption]
    public var branches: @MainActor (_ projectID: String) async -> RemoteBranchListResult
    public var agents: @MainActor () -> [RemoteAgentOption]
    public var createSession: @MainActor (_ request: RemoteSessionCreation, _ caller: HostCaller) async -> RemoteCreateSessionResult
    public var createWorktreeSession: @MainActor (_ request: RemoteWorktreeSessionCreation, _ caller: HostCaller) async -> RemoteCreateWorktreeSessionResult

    public init(
        worktrees: @escaping @MainActor () async -> [RemoteWorktreeOption],
        projects: @escaping @MainActor () async -> [RemoteProjectOption],
        branches: @escaping @MainActor (_ projectID: String) async -> RemoteBranchListResult,
        agents: @escaping @MainActor () -> [RemoteAgentOption],
        createSession: @escaping @MainActor (_ request: RemoteSessionCreation, _ caller: HostCaller) async -> RemoteCreateSessionResult = { _, _ in
            .failure("Could not create session.")
        },
        createWorktreeSession: @escaping @MainActor (_ request: RemoteWorktreeSessionCreation, _ caller: HostCaller) async -> RemoteCreateWorktreeSessionResult = { _, _ in
            .failure(stage: .worktree, message: "Could not create worktree.", worktreeId: nil)
        }
    ) {
        self.worktrees = worktrees
        self.projects = projects
        self.branches = branches
        self.agents = agents
        self.createSession = createSession
        self.createWorktreeSession = createWorktreeSession
    }

    /// The host's lists and creations; empty and refused without a host.
    public static func host(_ host: AlasHost?) -> RemoteGatewayHostCalls {
        guard let host else {
            return RemoteGatewayHostCalls(
                worktrees: { [] }, projects: { [] },
                branches: { _ in .failure("Repository is no longer available.") }, agents: { [] }
            )
        }
        let core = host.core
        return RemoteGatewayHostCalls(
            worktrees: { [weak core] in await core?.remoteWorktreeOptions() ?? [] },
            projects: { [weak core] in core?.remoteProjectOptions() ?? [] },
            branches: { [weak core] projectID in
                await core?.remoteBranches(projectID: projectID) ?? .failure("Repository is no longer available.")
            },
            agents: { [weak core] in core?.remoteAgentOptions() ?? [] },
            createSession: { [weak host] request, caller in
                await host?.remoteCreateSession(request, caller: caller) ?? .failure("Could not create session.")
            },
            createWorktreeSession: { [weak host] request, caller in
                await host?.remoteCreateWorktreeSession(request, caller: caller)
                    ?? .failure(stage: .worktree, message: "Could not create worktree.", worktreeId: nil)
            }
        )
    }
}
