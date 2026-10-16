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
    func stopWorkspaceCheckoutSessions(_ checkout: WorkspaceCheckout) async throws
    /// Approves and prepares a Workspace member's repository hook. Nil skips it.
    func resolveWorkspaceRepoHook(_ request: WorkspaceRepoHookRequest) async throws -> String?
    /// Starts and hosts run scripts.
    var runLauncher: any RunLauncher { get }
    /// Whether new sessions may use `agentID`, in a project on `remoteHost`
    /// when it is set.
    func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool
    /// The session manager for a Workspace checkout, created on first use.
    /// Throws a `SessionRefusal` when the checkout cannot host sessions now.
    func sessionManager(forCheckout checkout: WorkspaceCheckout, in core: AlasCoreContext) async throws -> ACPSessionManager
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

    public func stopWorkspaceCheckoutSessions(_ checkout: WorkspaceCheckout) async throws {}

    public func resolveWorkspaceRepoHook(_ request: WorkspaceRepoHookRequest) async throws -> String? { nil }

    public var runLauncher: any RunLauncher { HeadlessRunLauncher.shared }

    public func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool {
        ACPLaunchCatalog.specs.contains { $0.agentID == agentID }
    }

    public func sessionManager(forCheckout checkout: WorkspaceCheckout, in core: AlasCoreContext) async throws -> ACPSessionManager {
        try core.sessionManager(forCheckout: checkout)
    }
}

/// A host without a UI: every requirement keeps its default.
public final class HeadlessHostEnvironment: AlasHostEnvironment {
    public init() {}
}
