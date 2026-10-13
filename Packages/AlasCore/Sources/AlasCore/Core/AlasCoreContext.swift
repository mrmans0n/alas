import Foundation
import Observation

/// The headless composition root: the projects Alas manages, their worktrees,
/// and the session managers that run agents in them. Nothing here needs the
/// app; `AppState` builds one at launch and keeps only UI state on top.
@MainActor
@Observable
public final class AlasCoreContext {
    /// The worktree is being created or deleted, so nothing new starts in it.
    public struct WorktreeOperationInProgress: Error, Equatable {}

    public var projects: ProjectsManager
    /// One session manager per owner (worktree or workspace checkout).
    public var sessionManagers: [SessionOwnerID: ACPSessionManager] = [:]
    /// Observed command lifecycles, keyed by worktree then script. A run's
    /// outcome outlives whatever shell ran it.
    public var runRecords = RunRecordStore()
    /// Completed-run history.
    public let runHistory: RunHistory
    /// Runs project scripts without a terminal.
    @ObservationIgnored public let runs: RunService
    /// Decides when scheduled runs start; its runner decides how.
    public let runScheduler: RunScheduler
    /// Waits for a run's completion file. Injectable so tests can settle runs.
    @ObservationIgnored public let runCompletionWaiter: RunCompletionWaiter
    /// Runs whose completion is being waited for, keyed by run ID.
    @ObservationIgnored public var runObservations: [String: RunObservation] = [:]
    /// Told exactly once when a run settles, keyed by run ID. The worktree is
    /// carried so a worktree teardown can settle every run it owns, including
    /// ones that never produced an archivable record.
    @ObservationIgnored public var runSettlementHandlers: [String: (worktreeID: String, notify: (RunScriptSettlement) -> Void)] = [:]

    /// The on-device text model's files and state.
    @ObservationIgnored public let localTextModelStore: LocalTextModelStore
    /// The on-device text engine every local-text feature shares.
    @ObservationIgnored public private(set) lazy var localText: any LocalTextGenerating =
        localTextOverride ?? LocalTextEngine.make(localTextModelStore)
    @ObservationIgnored public private(set) lazy var sessionSummaries = SessionSummaryCoordinator(engine: localText)
    @ObservationIgnored private let localTextOverride: (any LocalTextGenerating)?
    /// Durable Workspace definitions and checkouts.
    @ObservationIgnored public let workspaceStore: WorkspaceStore
    /// Stops everything running in a checkout before a lifecycle operation
    /// touches it. The app installs one that closes its terminals and agent
    /// sessions; without one, nothing is stopped.
    @ObservationIgnored public var stopWorkspaceCheckoutSessions: @MainActor (WorkspaceCheckout) async throws -> Void
    /// Approves and prepares a member's repository hook. Without one, hooks
    /// are skipped.
    @ObservationIgnored public var resolveWorkspaceRepoHook: WorkspaceRepoHookResolving = { _ in nil }
    @ObservationIgnored private var workspaceCheckoutCoordinator: WorkspaceCheckoutCoordinator?

    /// Attention items and the gate observations pass through to reach them.
    public let attention: AttentionIntake

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let projectsFile: URL
    @ObservationIgnored private let makeSessionManager: @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager

    /// Wraps projects already loaded, as `AppState` does after its startup migrations.
    public init(
        projects: ProjectsManager,
        store: any PersistenceStoreProtocol = PersistenceStore(),
        projectsFile: URL = Paths.projectsFile,
        runs: RunService = RunService(),
        runHistoryStore: RunHistoryStore? = try? RunHistoryStore(),
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        runScheduler: RunScheduler? = nil,
        localTextModelStore: LocalTextModelStore = LocalTextModelStore(),
        localText: (any LocalTextGenerating)? = nil,
        attentionStore: AttentionStore? = nil,
        runCompletionWaiter: @escaping RunCompletionWaiter = { try await RunScriptCompletionMonitor.wait(for: $0) },
        makeSessionManager: @escaping @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager = AlasCoreContext.defaultSessionManager
    ) {
        self.projects = projects
        self.runs = runs
        self.runScheduler = runScheduler ?? RunScheduler(store: store)
        self.runCompletionWaiter = runCompletionWaiter
        self.runHistory = RunHistory(store: runHistoryStore)
        self.attention = AttentionIntake(store: attentionStore ?? AttentionStore())
        self.localTextModelStore = localTextModelStore
        self.localTextOverride = localText
        self.workspaceStore = workspaceStore
        self.stopWorkspaceCheckoutSessions = { _ in }
        self.store = store
        self.projectsFile = projectsFile
        self.makeSessionManager = makeSessionManager
    }

    /// Loads the projects persisted at `projectsFile`.
    public convenience init(
        loadingFrom store: any PersistenceStoreProtocol = PersistenceStore(),
        projectsFile: URL = Paths.projectsFile,
        runHistoryStore: RunHistoryStore? = try? RunHistoryStore(),
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        makeSessionManager: @escaping @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager = AlasCoreContext.defaultSessionManager
    ) throws {
        let file = try store.readIfExists(ProjectsFile.self, from: projectsFile) ?? ProjectsFile(projects: [])
        self.init(
            projects: ProjectsManager(persistedProjects: file.projects),
            store: store,
            projectsFile: projectsFile,
            runHistoryStore: runHistoryStore,
            workspaceStore: workspaceStore,
            makeSessionManager: makeSessionManager
        )
    }

    public func saveProjects() throws {
        try store.write(ProjectsFile(projects: projects.projects), to: projectsFile)
    }

    /// Registers the repository or folder at `path` and persists it. Nothing
    /// is kept if the save fails.
    @discardableResult
    public func addProject(
        path: URL,
        displayName: String,
        icon: ProjectIcon,
        host: String? = nil,
        kind: ProjectKind = .git,
        id: String = UUID().uuidString
    ) async throws -> ProjectConfig {
        guard !projects.projects.contains(where: { $0.id == id }) else {
            throw ProjectCreationError.projectAlreadyExists
        }
        let project = try await projects.addProject(
            path: path,
            displayName: displayName,
            icon: icon,
            host: host,
            kind: kind,
            id: id
        )
        do {
            try saveProjects()
        } catch {
            projects.removeProject(id: project.id)
            throw ProjectCreationError.projectPersistenceFailed
        }
        // The project is committed. A refresh or save that fails from here on
        // leaves the topology to the next refresh rather than failing the add.
        if (try? await projects.refreshWorktrees(projectId: project.id)) == true {
            try? saveProjects()
        }
        return project
    }

    /// Creates a worktree for `branch` from `base` at `destination`, then
    /// refreshes and persists the project's worktree list on a best-effort basis.
    public func createWorktree(
        projectID: String,
        branch: String,
        base: String,
        destination: URL
    ) async throws -> Worktree {
        guard let project = projects.projects.first(where: { $0.id == projectID }) else {
            throw ProjectCreationError.projectNotFound
        }
        let repoPath = URL(fileURLWithPath: project.path)
        let prepared = try await WorktreeLifecycle.preparedCreateWorktreeDestination(
            repoPath: repoPath,
            destination: destination
        )
        let worktree = try await WorktreeLifecycle.performCreateWorktree(
            repoPath: repoPath,
            base: base,
            branch: branch,
            destination: prepared,
            projectId: projectID
        )
        // The worktree now exists on disk, and git is the source of truth for
        // it: a refresh or save that fails here is left to the next refresh
        // rather than reported as a failed creation.
        if (try? await projects.refreshWorktrees(projectId: projectID)) == true {
            try? saveProjects()
        }
        return worktree
    }

    /// Runs `script` in `worktree` without a terminal, recording it and
    /// archiving its output like a terminal run. A run that never started
    /// leaves the previous record in place; one whose exit status was never
    /// observed finishes as `unknown`.
    @discardableResult
    public func runScript(_ script: RunScript, in worktree: Worktree) async throws -> RunOutcome {
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard project.host == nil else { throw RunService.RunError.remoteProjectUnsupported }
        guard projects.admitsNewWork(in: worktree) else { throw WorktreeOperationInProgress() }
        guard runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive != true else {
            throw RunService.RunError.alreadyRunning
        }
        let runID = UUID().uuidString
        let displaced = runRecords.begin(RunRecord(
            id: runID,
            scriptKey: script.key,
            scriptName: script.displayName,
            worktreeID: worktree.id,
            branch: worktree.branch,
            target: RunExecutionTarget(
                host: nil,
                workingDirectory: script.cwd.map { worktree.path.appendingPathComponent($0).path } ?? worktree.path.path
            ),
            endpoint: script.endpoint,
            status: .running,
            startedAt: Date()
        ))
        let completion: RunScriptCompletion
        do {
            completion = try await runs.run(script, in: worktree, project: project, runID: runID)
        } catch is CancellationError {
            finalizeRun(runRecords.finish(runID: runID, outcome: .stopped, at: Date()), capture: .unavailable)
            throw CancellationError()
        } catch where error is RunService.RunError || error is RunScriptCompletionMonitor.MonitorError {
            // The command ran but its exit status was never observed.
            finalizeRun(runRecords.markLostObservation(runID: runID, at: Date()), capture: .unavailable)
            throw error
        } catch {
            runRecords.rollback(runID: runID, to: displaced)
            throw error
        }
        let outcome: RunOutcome = completion.exitCode == 0 ? .succeeded : .failed(exitCode: completion.exitCode)
        finalizeRun(
            runRecords.finish(runID: runID, outcome: outcome, at: completion.completedAt),
            capture: .completion(completion)
        )
        return outcome
    }

    /// The one coordinator for Workspace checkout lifecycles. It reads the
    /// authoritative store, never a display cache, when deciding which
    /// sessions to stop.
    public func workspaceCoordinator() -> WorkspaceCheckoutCoordinator {
        if let workspaceCheckoutCoordinator { return workspaceCheckoutCoordinator }
        let coordinator = WorkspaceCheckoutCoordinator(
            store: workspaceStore,
            sessions: WorkspaceCheckoutSessionStopper(
                store: workspaceStore,
                stop: { [weak self] checkout in try await self?.stopWorkspaceCheckoutSessions(checkout) }
            ),
            resolveRepoHook: { [weak self] request in
                guard let resolve = await self?.resolveWorkspaceRepoHook else { return nil }
                return try await resolve(request)
            }
        )
        workspaceCheckoutCoordinator = coordinator
        return coordinator
    }

    /// The asynchronous half of disposing a session manager whose runners are
    /// stopped: persist what it holds, end its sessions, release its leases.
    public static func finishDisposing(_ manager: ACPSessionManager) async {
        await manager.flushAllPersistence()
        await manager.disposeAllLiveSessions()
        // Leases go last: a freed lease must not be claimable while an old
        // agent process is still alive.
        await manager.releaseAllOwnedLeases()
    }

    /// A manager with its own session database, as the app keeps per owner.
    public static func defaultSessionManager(owner: SessionOwnerID, worktree: Worktree) -> ACPSessionManager {
        ACPSessionManager(
            worktreeId: worktree.id,
            worktreePath: worktree.path.path,
            owner: owner,
            persistence: ACPSessionPersistence(path: Paths.acpSessionsDB(for: owner).path)
        )
    }

    /// The session manager for `worktree`, created on first use. None is
    /// handed out, cached or new, while the worktree is being created or
    /// deleted.
    public func sessionManager(for worktree: Worktree) throws -> ACPSessionManager {
        guard projects.admitsNewWork(in: worktree) else { throw WorktreeOperationInProgress() }
        let owner = SessionOwnerID.worktree(worktree.id)
        if let manager = sessionManagers[owner] { return manager }
        let manager = makeSessionManager(owner, worktree)
        manager.admitsNewWork = { [weak self] in self?.projects.admitsNewWork(in: worktree) ?? false }
        sessionManagers[owner] = manager
        return manager
    }
}
