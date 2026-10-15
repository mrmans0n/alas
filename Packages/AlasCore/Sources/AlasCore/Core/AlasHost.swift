import Foundation

/// The public entry point to the core: value snapshots and verbs for each
/// domain. It is a thin facade over `AlasCoreContext`, which does the work;
/// the app holds both while its callers move over.
@MainActor
public final class AlasHost {
    let core: AlasCoreContext
    /// Started by the first snapshot: nobody holds a cursor before it.
    private var eventSource: HostEventSource?

    public init(core: AlasCoreContext) {
        self.core = core
    }

    public var projects: ProjectsAPI { ProjectsAPI(core: core) }
    public var worktrees: WorktreesAPI { WorktreesAPI(core: core) }
    public var workspaces: WorkspacesAPI { WorkspacesAPI(core: core) }
    public var runs: RunsAPI { RunsAPI(core: core) }

    /// Everything the host holds, as values. Projects, worktrees and runs
    /// describe one moment; Workspace checkouts are read from their own
    /// store (an unreadable one throws) and describe the moment they were
    /// loaded, just before. Clients kept current by the host's events
    /// reconcile the two.
    ///
    /// Its cursor follows every change it shows: subscribe after it for
    /// the ones that come next.
    public func snapshot() async throws -> HostSnapshot {
        // Loaded first: the in-memory state is read after it with no
        // suspension in between, so that part describes one moment.
        // Whatever changed since the source last looked is published before
        // the cursor is read, so the cursor covers what this shows.
        let source = events
        let workspaceCheckouts = try await source.loadCheckouts()
        source.refreshInMemoryState()
        return HostSnapshot(
            cursor: source.log.cursor,
            projects: projects.list(),
            worktrees: worktrees.list(includingArchived: true),
            workspaceCheckouts: workspaceCheckouts,
            runs: runs.list()
        )
    }

    /// The changes after `cursor`, from a snapshot. A subscriber that falls
    /// behind, or whose cursor is too old, gets `.resync`.
    public func subscribe(after cursor: HostCursor) -> HostSubscription {
        events.log.subscribe(after: cursor)
    }

    private var events: HostEventSource {
        if let eventSource { return eventSource }
        let source = HostEventSource(core: core)
        eventSource = source
        return source
    }
}

/// The host's state, as `AlasHost.snapshot()` describes it.
public struct HostSnapshot: Equatable, Sendable {
    public var cursor: HostCursor
    public var projects: [ProjectConfig]
    public var worktrees: [WorktreeSnapshot]
    /// Checkouts that are not archived, as of their load from the store.
    public var workspaceCheckouts: [WorkspaceCheckout]
    public var runs: [RunRecord]
}

/// A worktree with what the host knows about it beyond Git.
public struct WorktreeSnapshot: Equatable, Sendable {
    public var worktree: Worktree
    /// The operation holding the worktree (being created, deleted, archived,
    /// or failed), if any.
    public var operation: WorktreeOperationState?
    public var isArchived: Bool
}

// MARK: - Projects

@MainActor
public struct ProjectsAPI {
    let core: AlasCoreContext

    public func list() -> [ProjectConfig] {
        core.projects.projects
    }

    /// Registers the project at `path` (on `host` for a remote one) and
    /// lists its worktrees.
    public func add(
        path: URL,
        displayName: String,
        icon: ProjectIcon,
        host: String? = nil,
        kind: ProjectKind = .git
    ) async throws -> ProjectConfig {
        try await core.addProject(path: path, displayName: displayName, icon: icon, host: host, kind: kind)
    }
}

// MARK: - Worktrees

@MainActor
public struct WorktreesAPI {
    let core: AlasCoreContext

    /// Worktrees in one project, or every project. Archived ones only when asked.
    public func list(projectID: String? = nil, includingArchived: Bool = false) -> [WorktreeSnapshot] {
        let projects = core.projects
        let projectIDs = projectID.map { [$0] } ?? projects.projects.map(\.id)
        return projectIDs.flatMap { id in
            projects.worktrees(projectId: id).compactMap { worktree in
                let archived = projects.isWorktreeHidden(projectId: id, path: worktree.path)
                guard includingArchived || !archived else { return nil }
                return WorktreeSnapshot(worktree: worktree, operation: projects.operationState(for: worktree), isArchived: archived)
            }
        }
    }

    /// Creates a worktree and waits for it, scripts and refresh included.
    public func create(_ request: WorktreeCreateRequest) async throws -> Worktree {
        try await core.createWorktree(request)
    }

    /// Lists the new worktree at once, claimed while it is created, for
    /// callers that show it before `finishCreate` is done.
    public func beginCreate(_ request: WorktreeCreateRequest) async throws -> PendingWorktreeCreation {
        try await core.beginCreate(request)
    }

    public func finishCreate(_ pending: PendingWorktreeCreation) async -> WorktreeCreationOutcome {
        await core.finishCreate(pending)
    }

    /// Deletes a worktree nobody needs to confirm, refusing (with a
    /// `WorktreeDeletionRefusal`) one whose checkout no longer matches it:
    /// another lineage or branch at the path, a remote or unidentified
    /// checkout, the main checkout, or one another operation holds.
    public func delete(_ worktree: Worktree, force: Bool = false, deleteBranchIfMerged: Bool = false) async throws {
        try await core.deleteWorktree(worktree, force: force, deleteBranchIfMerged: deleteBranchIfMerged)
    }

    /// Claims a worktree for a deletion its caller confirms first; pass the
    /// claim to `delete(_:claim:options:)`, or release it.
    public func beginDelete(_ worktree: Worktree) throws -> UUID {
        try core.beginDelete(worktree)
    }

    /// Marks a claimed deletion as confirmed: the row reads as being deleted.
    public func confirmDelete(_ claim: UUID, for worktree: Worktree) {
        core.confirmDelete(claim, for: worktree)
    }

    /// Ends a claim, leaving `message` on the row as a failure to retry.
    public func failClaim(_ claim: UUID, for worktree: Worktree, message: String) {
        core.failWorktreeClaim(claim, for: worktree, message: message)
    }

    public func delete(_ worktree: Worktree, claim: UUID, options: WorktreeDeleteOptions) async -> WorktreeDeletionOutcome {
        core.confirmDelete(claim, for: worktree)
        return await core.deleteWorktree(worktree, claim: claim, options: options)
    }

    /// Refreshes the projects of deletions made with `refreshesProject`
    /// false, once, and ends their claims. Throws if the project list
    /// cannot be saved.
    public func finishDeletions(_ deletions: [(worktree: Worktree, claim: UUID)]) async throws {
        try await core.finishDeletions(deletions)
    }

    public func releaseClaim(_ claim: UUID, for worktree: Worktree) {
        core.releaseWorktreeClaim(claim, for: worktree)
    }

    public func archive(_ worktree: Worktree) async throws {
        try await core.archiveWorktree(worktree)
    }

    public func unarchive(path: URL, projectID: String) throws {
        try core.unarchiveWorktree(path: path, projectID: projectID)
    }
}

// MARK: - Workspaces

@MainActor
public struct WorkspacesAPI {
    let core: AlasCoreContext

    /// Checkouts that are not archived. Throws `WorkspaceAutomationError`.
    public func list() async throws -> [WorkspaceCheckout] {
        try await WorkspaceAutomationService(store: core.workspaceStore).checkouts()
    }

    /// One checkout that is not archived. Throws `WorkspaceAutomationError`.
    public func checkout(id: UUID) async throws -> WorkspaceCheckout {
        try await WorkspaceAutomationService(store: core.workspaceStore).checkout(id: id)
    }
}

// MARK: - Runs

@MainActor
public struct RunsAPI {
    let core: AlasCoreContext

    /// The latest run of each script, in one worktree or every worktree.
    /// Runs are kept by worktree id, which projects on different hosts can
    /// share for the same path; each record is listed once.
    public func list(worktreeID: String? = nil) -> [RunRecord] {
        worktreeID.map { core.runRecords.records(worktreeID: $0) } ?? core.runRecords.allRecords
    }

    @discardableResult
    public func start(_ script: RunScript, in worktree: Worktree, isHidden: Bool = false) -> RunStart {
        core.startRun(script, in: worktree, isHidden: isHidden)
    }

    @discardableResult
    public func restart(_ script: RunScript, in worktree: Worktree, isHidden: Bool = false) -> RunStart {
        core.restartRun(script, in: worktree, isHidden: isHidden)
    }

    public func stop(scriptKey: String, in worktree: Worktree) {
        core.stopRun(scriptKey: scriptKey, in: worktree)
    }

    /// Runs the script and waits for how it ended.
    public func run(_ script: RunScript, in worktree: Worktree) async throws -> RunOutcome {
        try await core.runScript(script, in: worktree)
    }
}
