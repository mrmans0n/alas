import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP
import AlasSessions

private let hostLogger = Logger(subsystem: "io.nlopez.alas", category: "AlasHost")

/// The public entry point to the core: value snapshots and verbs for each
/// domain. It is a thin facade over `AlasCoreContext`, which does the work;
/// the app holds both while its callers move over.
@MainActor
public final class AlasHost {
    let core: AlasCoreContext
    /// For what a headless host builds over the core, such as its session presenter.
    @_spi(AppHost) public var coreContext: AlasCoreContext { core }
    /// Started by the first snapshot: nobody holds a cursor before it.
    private var eventSource: HostEventSource?
    /// Test hook that replaces the session step of a Remote client's
    /// worktree-and-session creation.
    @_spi(Testing) public var remoteSessionCreator: (@MainActor (RemoteSessionCreation) async -> RemoteCreateSessionResult)?

    public init(core: AlasCoreContext) {
        self.core = core
    }

    public var projects: ProjectsAPI { ProjectsAPI(core: core) }

    /// Lists the projects' worktrees, from the cache and then from git. A
    /// serving host starts with this; see `AlasCoreContext.loadProjectWorktrees()`.
    public func loadProjectWorktrees() async {
        await core.loadProjectWorktrees()
    }

    public var worktrees: WorktreesAPI { WorktreesAPI(core: core) }
    public var workspaces: WorkspacesAPI { WorkspacesAPI(core: core) }
    public var runs: RunsAPI { RunsAPI(core: core) }
    public var sessions: SessionsAPI { SessionsAPI(core: core) }

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
            runs: runs.list(),
            sessions: sessions.list()
        )
    }

    /// The changes after `cursor`, from a snapshot. A subscriber that falls
    /// behind, or whose cursor is too old, gets `.resync`.
    public func subscribe(after cursor: HostCursor) -> HostSubscription {
        events.log.subscribe(after: cursor)
    }

    /// The changes from now on, for a subscriber that reads its state
    /// fresh whenever they arrive rather than from a snapshot.
    public func subscribe() -> HostSubscription {
        let source = events
        source.refreshInMemoryState()
        return source.log.subscribe(after: source.log.cursor)
    }

    private var events: HostEventSource {
        if let eventSource { return eventSource }
        let source = HostEventSource(core: core)
        eventSource = source
        return source
    }
}

/// Who asked the host to do something. Each transport builds it from what it
/// authenticated, so it is never part of a wire message: a client can name
/// a target, but never who it is. Used for authorization and attribution,
/// never for presentation.
public enum HostCaller: Equatable, Sendable {
    /// The app's own interface, in process.
    case app
    /// A CLI or MCP command the app received on its command socket.
    case cli
    /// A CLI or MCP command the app received from session `id`, an agent's
    /// or a terminal's.
    case session(id: String)
    /// A client of the host socket, as the socket reported its peer.
    case localUser(uid: UInt32)
    /// A paired Remote peer, by the device id it authenticated as.
    case remotePeer(deviceID: String)

    func log(_ verb: StaticString, _ target: String) {
        hostLogger.info("\(verb, privacy: .public) \(target, privacy: .private) by \(String(describing: self), privacy: .public)")
    }
}

/// The host's state, as `AlasHost.snapshot()` describes it.
public struct HostSnapshot: Codable, Equatable, Sendable {
    public var cursor: HostCursor
    public var projects: [ProjectSnapshot]
    public var worktrees: [WorktreeSnapshot]
    /// Checkouts that are not archived, as of their load from the store.
    public var workspaceCheckouts: [WorkspaceCheckoutSnapshot]
    public var runs: [RunRecord]
    public var sessions: [HostSessionSummary]

    public init(
        cursor: HostCursor, projects: [ProjectSnapshot], worktrees: [WorktreeSnapshot],
        workspaceCheckouts: [WorkspaceCheckoutSnapshot], runs: [RunRecord], sessions: [HostSessionSummary]
    ) {
        self.cursor = cursor
        self.projects = projects
        self.worktrees = worktrees
        self.workspaceCheckouts = workspaceCheckouts
        self.runs = runs
        self.sessions = sessions
    }
}

/// A project as clients see it. Its configuration stays with the host: it
/// holds scripts and MCP server settings, whose values can be credentials.
public struct ProjectSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    /// The SSH host of a remote project; nil for a local one.
    public var host: String?
    public var kind: ProjectKind
    public var addedAt: Date

    public init(_ project: ProjectConfig) {
        id = project.id
        name = project.name
        path = project.path
        host = project.host
        kind = project.kind
        addedAt = project.addedAt
    }
}

/// A Workspace checkout as clients see it: its members, operation and health,
/// without the configuration it captured, which can hold credentials.
public typealias WorkspaceCheckoutSnapshot = WorkspaceAutomationCheckoutSummary

/// A worktree with what the host knows about it beyond Git.
public struct WorktreeSnapshot: Codable, Equatable, Sendable {
    public var worktree: Worktree
    /// The operation holding the worktree, if any.
    public var operation: WorktreeOperation?
    public var isArchived: Bool

    public init(worktree: Worktree, operation: WorktreeOperation?, isArchived: Bool) {
        self.worktree = worktree
        self.operation = operation
        self.isArchived = isArchived
    }
}

/// What holds a worktree, as clients see it: the kind of operation, and the
/// message of one that failed. Retry details stay with the host.
public enum WorktreeOperation: Codable, Equatable, Sendable {
    case creating
    /// A deletion waiting for its caller to confirm it.
    case preparingDelete
    case deleting
    case archiving
    case createFailed(message: String)
    case launchFailed(message: String)
    case deleteFailed(message: String)

    init(_ state: WorktreeOperationState) {
        switch state {
        case .creating: self = .creating
        case .preparingDelete: self = .preparingDelete
        case .deleting: self = .deleting
        case .archiving: self = .archiving
        case .createFailed(_, let message, _, _, _, _, _): self = .createFailed(message: message)
        case .launchFailed(_, let message, _): self = .launchFailed(message: message)
        case .deleteFailed(let message): self = .deleteFailed(message: message)
        }
    }
}

// MARK: - Projects

@MainActor
public struct ProjectsAPI {
    let core: AlasCoreContext

    public func list() -> [ProjectSnapshot] {
        core.projects.projects.map(ProjectSnapshot.init)
    }

    /// Registers the project at `path` (on `host` for a remote one) and
    /// lists its worktrees.
    public func add(
        path: URL,
        displayName: String,
        icon: ProjectIcon,
        host: String? = nil,
        kind: ProjectKind = .git,
        caller: HostCaller
    ) async throws -> ProjectSnapshot {
        caller.log("projects.add", path.path)
        return ProjectSnapshot(try await core.addProject(path: path, displayName: displayName, icon: icon, host: host, kind: kind))
    }

    /// Forgets the project, refusing (`HostError.projectBusy`) while a
    /// session or run is live in one of its worktrees.
    public func remove(projectID: String, caller: HostCaller) async throws {
        caller.log("projects.remove", projectID)
        try await core.removeProject(id: projectID)
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
                return WorktreeSnapshot(
                    worktree: worktree,
                    operation: projects.operationState(for: worktree).map(WorktreeOperation.init),
                    isArchived: archived
                )
            }
        }
    }

    /// Creates a worktree and waits for it, scripts and refresh included.
    public func create(_ request: WorktreeCreateRequest, caller: HostCaller) async throws -> Worktree {
        caller.log("worktrees.create", request.destination.path)
        return try await core.createWorktree(try await checkedCreation(request))
    }

    /// Lists the new worktree at once, claimed while it is created, for
    /// callers that show it before `finishCreate` is done.
    public func beginCreate(_ request: WorktreeCreateRequest, caller: HostCaller) async throws -> PendingWorktreeCreation {
        caller.log("worktrees.create", request.destination.path)
        return try await core.beginCreate(request)
    }

    public func finishCreate(_ pending: PendingWorktreeCreation) async -> WorktreeCreationOutcome {
        await core.finishCreate(pending)
    }

    /// Deletes a worktree nobody needs to confirm, refusing (with a
    /// `WorktreeDeletionRefusal`) one whose checkout no longer matches it:
    /// another lineage or branch at the path, a remote or unidentified
    /// checkout, the main checkout, or one another operation holds. Unsaved
    /// editor changes refuse it, whatever `force`, unless `discardUnsavedEdits`.
    public func delete(
        _ worktree: Worktree, force: Bool = false, deleteBranchIfMerged: Bool = false,
        discardUnsavedEdits: Bool = false, caller: HostCaller
    ) async throws {
        caller.log("worktrees.delete", worktree.path.path)
        try deletionCheck(worktree, discardUnsavedEdits: discardUnsavedEdits)
        try await core.deleteWorktree(
            worktree, force: force, deleteBranchIfMerged: deleteBranchIfMerged, discardUnsavedEdits: discardUnsavedEdits
        )
    }

    /// Claims a worktree for a deletion its caller confirms first; pass the
    /// claim to `delete(_:claim:options:)`, or release it.
    public func beginDelete(_ worktree: Worktree, caller: HostCaller) throws -> UUID {
        caller.log("worktrees.delete", worktree.path.path)
        return try core.beginDelete(worktree)
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

    /// With `verifiesCheckout`, refuses (`changed`) a checkout whose lineage
    /// or branch on disk no longer matches `worktree`, as late as possible.
    /// Unsaved editor changes, including any made while it runs, refuse it
    /// unless `discardUnsavedEdits`.
    public func archive(
        _ worktree: Worktree, verifiesCheckout: Bool = false, discardUnsavedEdits: Bool = false, caller: HostCaller
    ) async throws {
        caller.log("worktrees.archive", worktree.path.path)
        if !discardUnsavedEdits, core.environment.hasUnsavedEditorChanges(in: worktree) {
            throw WorktreeArchiveRefusal.unsavedEdits
        }
        try await core.archiveWorktree(worktree, verifiesCheckout: verifiesCheckout, refusesUnsavedEdits: !discardUnsavedEdits)
    }

    /// Reads project `projectID`'s worktrees from disk again, saving the
    /// project list if they changed.
    public func refresh(projectID: String, caller: HostCaller) async throws {
        caller.log("worktrees.refresh", projectID)
        if try await core.environment.refreshProjectWorktrees(projectID, in: core) {
            try core.saveProjects()
        }
    }

    public func unarchive(path: URL, projectID: String, caller: HostCaller) throws {
        caller.log("worktrees.unarchive", path.path)
        try core.unarchiveWorktree(path: path, projectID: projectID)
    }
}

// MARK: - Workspaces

@MainActor
public struct WorkspacesAPI {
    let core: AlasCoreContext

    /// Checkouts that are not archived. Throws `WorkspaceAutomationError`.
    public func list() async throws -> [WorkspaceCheckoutSnapshot] {
        try await WorkspaceAutomationService(store: core.workspaceStore).checkouts().map(WorkspaceAutomationService.summary)
    }

    /// One checkout that is not archived. Throws `WorkspaceAutomationError`.
    public func checkout(id: UUID) async throws -> WorkspaceCheckoutSnapshot {
        WorkspaceAutomationService.summary(try await WorkspaceAutomationService(store: core.workspaceStore).checkout(id: id))
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
    public func start(
        _ script: RunScript, in worktree: Worktree, isHidden: Bool = false, activatesConsole: Bool = true,
        promptsForRepoHooks: Bool = true, caller: HostCaller
    ) -> RunStart {
        caller.log("runs.start", script.key)
        return core.startRun(
            script, in: worktree, isHidden: isHidden, activatesConsole: activatesConsole, promptsForRepoHooks: promptsForRepoHooks
        )
    }

    @discardableResult
    public func restart(
        _ script: RunScript, in worktree: Worktree, isHidden: Bool = false, activatesConsole: Bool = true,
        promptsForRepoHooks: Bool = true, caller: HostCaller
    ) -> RunStart {
        caller.log("runs.restart", script.key)
        return core.restartRun(
            script, in: worktree, isHidden: isHidden, activatesConsole: activatesConsole, promptsForRepoHooks: promptsForRepoHooks
        )
    }

    public func stop(scriptKey: String, in worktree: Worktree, caller: HostCaller) {
        caller.log("runs.stop", scriptKey)
        core.stopRun(scriptKey: scriptKey, in: worktree)
    }

    /// Runs the script and waits for how it ended.
    public func run(_ script: RunScript, in worktree: Worktree, caller: HostCaller) async throws -> RunOutcome {
        caller.log("runs.run", script.key)
        return try await core.runScript(script, in: worktree)
    }
}

// MARK: - Sessions

/// A session as lists show it: read-only, without its transcript.
public struct HostSessionSummary: Codable, Equatable, Sendable {
    /// The worktree or Workspace checkout the session belongs to.
    public var owner: SessionOwnerID
    public var id: String
    public var agentId: String
    public var title: String
    /// The agent's own id for the session, once it has one.
    public var remoteSessionId: String?
    /// Seconds since 1970, as the session store keeps them.
    public var createdAt: Int64
    public var updatedAt: Int64
    public var lastOpenedAt: Int64
    /// Nil while no agent process runs the session.
    public var streamingState: ACPSession.StreamingState?
    /// Whether this instance holds the session's writer lease.
    public var isWriter: Bool
    /// The session that delegated this one, for a delegated session.
    public var parentID: String?
}

@MainActor
public struct SessionsAPI {
    let core: AlasCoreContext

    /// The sessions that are not archived, in each owner's recent order.
    public func list() -> [HostSessionSummary] {
        core.sessionManagers.values.flatMap { manager in
            manager.sessionRows.compactMap { row in
                row.archived ? nil : Self.summary(of: row, in: manager, parent: core.delegatedSessionParents[row.id])
            }
        }
    }

    static func summary(of row: ACPSessionRow, in manager: ACPSessionManager, parent: String?) -> HostSessionSummary {
        let liveRemoteID = manager.liveSession(for: row.id)?.remoteSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HostSessionSummary(
            owner: manager.owner,
            id: row.id,
            agentId: row.agentId,
            title: row.title,
            remoteSessionId: liveRemoteID?.isEmpty == false ? liveRemoteID : row.remoteSessionId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            lastOpenedAt: row.lastOpenedAt,
            streamingState: manager.runners[row.id]?.session.transcript.streamingState,
            isWriter: manager.isWriter(for: row.id),
            parentID: parent
        )
    }
}
