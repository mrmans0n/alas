import Foundation

/// What a host adds to the core's worktree and Workspace lifecycles: the
/// app closes its terminals, asks about repository hooks and refreshes what
/// it shows. Every requirement has a default, which is what a host without
/// a UI gets (`HeadlessHostEnvironment`): nothing extra is stopped, nobody
/// is asked, and unapproved hooks are skipped.
@MainActor
public protocol AlasHostEnvironment: AnyObject {
    /// Stops everything using a worktree that is about to go: its agent
    /// sessions by default. The app also kills its terminals, waiting for
    /// them, and closes its tabs. Throwing refuses the operation.
    func quiesceWorktree(_ worktree: Worktree, in core: AlasCoreContext) async throws
    /// Whether an interrupted checkpoint restore must be recovered before the
    /// worktree can be removed.
    func checkpointRecoveryBlocksRemoval(_ worktree: Worktree) async -> Bool
    /// Starts background cleanup of a removed worktree's staged files.
    func launchWorktreeCleanup(_ ticket: WorktreeTrashCleanupTicket) throws
    /// Re-reads a project's worktrees after a creation or removal. Returns
    /// whether the project list changed and still needs saving.
    func refreshProjectWorktrees(_ projectID: String, in core: AlasCoreContext) async throws -> Bool
    /// Reads repository hooks from a worktree.
    var repoHookLoader: RepoHookLoader { get }
    /// Asks about unapproved repository hooks.
    var repoHookPrompter: RepoHookPrompter { get }
    /// The global startup scripts.
    func globalTerminalConfig() -> AppConfig.Terminal
    /// Stops everything running in a Workspace checkout before a lifecycle
    /// operation touches it.
    func stopWorkspaceCheckoutSessions(_ checkout: WorkspaceCheckout, in core: AlasCoreContext) async throws
    /// Approves and prepares a Workspace member's repository hook. Nil skips it.
    func resolveWorkspaceRepoHook(_ request: WorkspaceRepoHookRequest) async throws -> String?
    /// Starts and hosts run scripts.
    var runLauncher: any RunLauncher { get }
    /// Whether new sessions may use `agentID`, in a project on `remoteHost`
    /// when it is set.
    func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool
    /// Whether an interrupted checkpoint restore keeps new agent sessions out
    /// of `owner` now.
    func checkpointRecoveryBlocksSessions(owner: SessionOwnerID, in core: AlasCoreContext) async -> Bool
    /// Whether `owner` takes a new session right now, read synchronously after
    /// the last suspension of a creation: the app's own view of a checkout
    /// or worktree being archived, deleted or changed.
    func admitsSessionCreation(owner: SessionOwnerID, in core: AlasCoreContext) -> Bool
    /// The session manager for a worktree, created on first use. Throws while
    /// another operation holds the worktree.
    func sessionManager(for worktree: Worktree, in core: AlasCoreContext) throws -> ACPSessionManager
    /// The session manager for a Workspace checkout, created on first use.
    /// Throws a `SessionRefusal` when the checkout cannot host sessions now.
    func sessionManager(forCheckout checkout: WorkspaceCheckout, in core: AlasCoreContext) async throws -> ACPSessionManager
    /// The app's settings, such as the base branch worktrees compare with.
    func configuration() -> AppConfig
    /// The agents new sessions may use, installed and not turned off.
    func enabledAgents() -> [AgentDefinition]
    /// The models and thinking levels agents advertised, when the host keeps them.
    var modelCatalog: ACPAgentModelCatalog? { get }
    /// The index of each worktree's files, shared with the app's own pickers.
    var fileIndex: FileIndex { get }
    /// The configured agent `id`, enabled or not.
    func agent(id: String) -> AgentDefinition?
    /// The owner of terminal session `id`, which only a host with terminals knows.
    func terminalSessionOwner(_ sessionID: String) -> SessionOwnerID?
    /// The Workspace checkout `id` as the host has it loaded; nil where it
    /// keeps none loaded, which only callers in a checkout need.
    func workspaceCheckout(id: UUID) -> WorkspaceCheckout?
    /// How commands reach a remote checkout's host.
    var workspaceRemoteTransport: WorkspaceRemoteTransport { get }
    /// Which instance of the host this is: session leases and delegations
    /// are claimed in its name.
    var instanceID: String { get }
    /// The agents that can run in `worktree`, on its project's host, as of a
    /// fresh check.
    func agentAvailability(in worktree: Worktree, core: AlasCoreContext) async -> AgentAvailabilityState
    /// Creates a worktree for a delegated session without changing what the
    /// user is looking at, recording its prepared destination through
    /// `recordDestination` before anything is created.
    func createDelegatedWorktree(
        projectID: String, branch: String, base: String?,
        recordDestination: @MainActor (URL) async throws -> Void, in core: AlasCoreContext
    ) async -> Result<Worktree, ACPSessionOrchestrationCoordinator.WorktreeCreationError>
    /// A delegated session's parent was recorded or loaded.
    func delegatedSessionParentsChanged()
}

extension AlasHostEnvironment {
    public func quiesceWorktree(_ worktree: Worktree, in core: AlasCoreContext) async throws {
        await core.disposeSessionManager(owner: .worktree(worktree.id))
    }

    public func checkpointRecoveryBlocksRemoval(_ worktree: Worktree) async -> Bool {
        await AlasCoreContext.hasPendingCheckpointRecovery(worktree)
    }

    public func launchWorktreeCleanup(_ ticket: WorktreeTrashCleanupTicket) throws {
        try WorktreeTrashCleaner.launch(ticket)
    }

    public func refreshProjectWorktrees(_ projectID: String, in core: AlasCoreContext) async throws -> Bool {
        try await core.projects.refreshWorktrees(projectId: projectID)
    }

    public var repoHookLoader: RepoHookLoader { RepoHookLoader() }

    public var repoHookPrompter: RepoHookPrompter { .skipping }

    public func globalTerminalConfig() -> AppConfig.Terminal { AppConfig.defaults.terminal }

    public func configuration() -> AppConfig { AppConfig.defaults }

    /// The built-in agents in their default state; a headless host does not
    /// detect what is installed.
    public func enabledAgents() -> [AgentDefinition] {
        AgentConfiguredCatalog.enabled(builtinState: AppConfig.defaults.agents.builtinState, customs: [])
    }

    public var modelCatalog: ACPAgentModelCatalog? { nil }

    /// A fresh index; a host that keeps one shares it instead.
    public var fileIndex: FileIndex { FileIndex() }

    public func agent(id: String) -> AgentDefinition? {
        AgentConfiguredCatalog.all(builtinState: AppConfig.defaults.agents.builtinState, customs: []).first { $0.id == id }
    }

    public func terminalSessionOwner(_ sessionID: String) -> SessionOwnerID? { nil }

    public func workspaceCheckout(id: UUID) -> WorkspaceCheckout? { nil }

    public var workspaceRemoteTransport: WorkspaceRemoteTransport { WorkspaceRemoteTransport() }

    public var instanceID: String { HostInstance.id }

    public func agentAvailability(in worktree: Worktree, core: AlasCoreContext) async -> AgentAvailabilityState {
        .available(enabledAgents())
    }

    public func createDelegatedWorktree(
        projectID: String, branch: String, base: String?,
        recordDestination: @MainActor (URL) async throws -> Void, in core: AlasCoreContext
    ) async -> Result<Worktree, ACPSessionOrchestrationCoordinator.WorktreeCreationError> {
        .failure(.init(message: "This host does not create worktrees for delegated sessions."))
    }

    public func delegatedSessionParentsChanged() {}

    /// Ends the checkout's agent sessions, as a removal ends a worktree's.
    public func stopWorkspaceCheckoutSessions(_ checkout: WorkspaceCheckout, in core: AlasCoreContext) async throws {
        await core.disposeSessionManager(owner: .workspaceCheckout(checkout.id, checkout.executionLocation))
    }

    public func resolveWorkspaceRepoHook(_ request: WorkspaceRepoHookRequest) async throws -> String? { nil }

    public var runLauncher: any RunLauncher { HeadlessRunLauncher.shared }

    /// A worktree's own restore journals decide; a checkout has none of its own.
    public func checkpointRecoveryBlocksSessions(owner: SessionOwnerID, in core: AlasCoreContext) async -> Bool {
        guard case .worktree(let worktreeID) = owner else { return false }
        guard let worktree = core.projects.worktreesByProject.values.lazy.flatMap({ $0 }).first(where: { $0.id == worktreeID }) else {
            return true
        }
        return await AlasCoreContext.hasPendingCheckpointRecovery(worktree)
    }

    public func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool {
        ACPLaunchCatalog.specs.contains { $0.agentID == agentID }
    }

    /// A headless host's teardown removes the owner's manager at once, which
    /// creation checks on its own.
    public func admitsSessionCreation(owner: SessionOwnerID, in core: AlasCoreContext) -> Bool { true }

    /// Local worktrees only: a remote project's agent runs on its host,
    /// which only the app reaches.
    public func sessionManager(for worktree: Worktree, in core: AlasCoreContext) throws -> ACPSessionManager {
        guard core.projects.projects.first(where: { $0.id == worktree.projectId })?.host == nil else {
            throw SessionRefusal.ownerUnavailable(reason: "Sessions in remote worktrees start from the app.")
        }
        return try core.sessionManager(for: worktree)
    }

    public func sessionManager(forCheckout checkout: WorkspaceCheckout, in core: AlasCoreContext) async throws -> ACPSessionManager {
        try core.sessionManager(forCheckout: checkout)
    }
}

/// A host without a UI: every requirement keeps its default.
public final class HeadlessHostEnvironment: AlasHostEnvironment {
    public let fileIndex = FileIndex()

    public init() {}
}

/// This process, as a host instance; one that keeps its own id says so.
enum HostInstance {
    static let id = UUID().uuidString
}
