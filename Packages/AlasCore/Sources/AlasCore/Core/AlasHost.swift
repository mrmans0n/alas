import Foundation

/// The public entry point to the core: value snapshots and verbs for each
/// domain. It is a thin facade over `AlasCoreContext`, which does the work;
/// the app holds both while its callers move over.
@MainActor
public final class AlasHost {
    let core: AlasCoreContext

    public init(core: AlasCoreContext) {
        self.core = core
    }

    public var projects: ProjectsAPI { ProjectsAPI(core: core) }
    public var worktrees: WorktreesAPI { WorktreesAPI(core: core) }
    public var workspaces: WorkspacesAPI { WorkspacesAPI(core: core) }
    public var runs: RunsAPI { RunsAPI(core: core) }

    /// Everything the host holds, as values. Workspace checkouts are read
    /// from their store, so an unreadable store throws.
    public func snapshot() async throws -> HostSnapshot {
        HostSnapshot(
            projects: projects.list(),
            worktrees: worktrees.list(includingArchived: true),
            workspaceCheckouts: try await workspaces.list(),
            runs: runs.list()
        )
    }
}

/// The host's state at one moment.
public struct HostSnapshot: Equatable, Sendable {
    public var projects: [ProjectConfig]
    public var worktrees: [WorktreeSnapshot]
    /// Checkouts that are not archived.
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

    /// Registers the repository at `path` and lists its worktrees.
    public func add(path: URL, displayName: String, icon: ProjectIcon) async throws -> ProjectConfig {
        try await core.addProject(path: path, displayName: displayName, icon: icon)
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

    /// Deletes a worktree nobody needs to confirm. Throws when another
    /// operation holds it or it is the main checkout.
    public func delete(_ worktree: Worktree, options: WorktreeDeleteOptions) async throws -> WorktreeDeletionOutcome {
        let claim = try core.beginDelete(worktree)
        core.confirmDelete(claim, for: worktree)
        return await core.deleteWorktree(worktree, claim: claim, options: options)
    }

    /// Claims a worktree for a deletion its caller confirms first; pass the
    /// claim to `delete(_:claim:options:)`, or release it.
    public func beginDelete(_ worktree: Worktree) throws -> UUID {
        try core.beginDelete(worktree)
    }

    public func delete(_ worktree: Worktree, claim: UUID, options: WorktreeDeleteOptions) async -> WorktreeDeletionOutcome {
        core.confirmDelete(claim, for: worktree)
        return await core.deleteWorktree(worktree, claim: claim, options: options)
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
    public func list(worktreeID: String? = nil) -> [RunRecord] {
        guard let worktreeID else {
            return core.projects.projects.flatMap { core.projects.worktrees(projectId: $0.id) }
                .flatMap { core.runRecords.records(worktreeID: $0.id) }
        }
        return core.runRecords.records(worktreeID: worktreeID)
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
