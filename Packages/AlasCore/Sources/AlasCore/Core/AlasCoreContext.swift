import Foundation
import Observation

/// The headless composition root: the projects Alas manages, their worktrees,
/// and the session managers that run agents in them. Nothing here needs the
/// app; `AppState` builds one at launch and keeps only UI state on top.
@MainActor
@Observable
public final class AlasCoreContext {
    /// The worktree is archived (or being archived), so nothing new starts in it.
    public struct WorktreeArchived: Error, Equatable {}

    /// An active Workspace checkout manages this worktree; archive or delete
    /// it through the checkout instead.
    public struct WorktreeOwnedByWorkspaceCheckout: Error, Equatable {
        public let checkoutName: String
    }

    /// Workspace state could not be read, so ownership cannot be ruled out.
    public struct WorkspaceOwnershipUnverifiable: Error, Equatable {}

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

    /// Headless runs in flight, so archiving their worktree can stop them.
    @ObservationIgnored private var headlessRuns: [String: (worktreeID: String, task: Task<RunOutcome, Error>)] = [:]
    /// Worktrees whose archive is still tearing down; unarchiving waits.
    @ObservationIgnored private var archivingWorktreeIDs: Set<String> = []
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
        guard !isArchivedOrArchiving(worktree) else { throw WorktreeArchived() }
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
        // The task covers the whole run, finalization included, so archiving
        // can wait for the record to settle before discarding run state.
        let lifecycle = Task { () throws -> RunOutcome in
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
        headlessRuns[runID] = (worktree.id, lifecycle)
        defer { headlessRuns.removeValue(forKey: runID) }
        return try await withTaskCancellationHandler { try await lifecycle.value } onCancel: { lifecycle.cancel() }
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

    /// Hides `worktree` from its project and persists that. Its headless
    /// runs are stopped and its agent sessions shut down; its other active
    /// runs settle as lost. All of them keep their history. Nothing is removed
    /// from disk. The whole archive holds the project's mutation gate, so a
    /// Workspace checkout cannot change ownership of the worktree meanwhile, and
    /// no unarchive, second archive, run or session manager is admitted until
    /// it is done. A failed save throws and leaves the worktree visible and
    /// untouched.
    public func archiveWorktree(_ worktree: Worktree) async throws {
        guard archivingWorktreeIDs.insert(worktree.id).inserted else { throw WorktreeArchived() }
        defer { archivingWorktreeIDs.remove(worktree.id) }
        try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) {
            try await self.archiveHoldingGate(worktree)
        }
    }

    private func isArchivedOrArchiving(_ worktree: Worktree) -> Bool {
        archivingWorktreeIDs.contains(worktree.id)
            || projects.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path)
    }

    private func archiveHoldingGate(_ worktree: Worktree) async throws {
        if let owner = try await activeWorkspaceOwner(of: worktree) {
            throw WorktreeOwnedByWorkspaceCheckout(checkoutName: owner.fallbackWorkspaceName)
        }
        try setWorktreeHidden(worktree.path, projectID: worktree.projectId, hidden: true)
        let running = headlessRuns.values.filter { $0.worktreeID == worktree.id }.map(\.task)
        for run in running {
            run.cancel()
        }
        for run in running {
            _ = try? await run.value
        }
        await disposeSessionManager(owner: .worktree(worktree.id))
        discardRuns(worktreeID: worktree.id, deletingHistory: false)
    }

    /// Shows an archived worktree again. Sessions and runs are not restored.
    /// Refused while its archive is still tearing down.
    public func unarchiveWorktree(path: URL, projectID: String) throws {
        guard !archivingWorktreeIDs.contains(Worktree.makeId(path: path)) else { throw WorktreeArchived() }
        try setWorktreeHidden(path, projectID: projectID, hidden: false)
    }

    /// The active Workspace checkout managing `worktree`, matched like the
    /// app's worktree-cleanup ownership. Archived and former checkouts no
    /// longer manage their members. Unreadable Workspace state throws.
    private func activeWorkspaceOwner(of worktree: Worktree) async throws -> WorkspaceCheckout? {
        let state: WorkspaceStateFile
        switch await workspaceStore.load() {
        case .missing: return nil
        case .unreadable: throw WorkspaceOwnershipUnverifiable()
        case .loaded(let loaded): state = loaded
        }
        let path = worktree.path.standardizedFileURL.path
        return state.checkouts.first { checkout in
            checkout.workspaceID != nil && checkout.archivedAt == nil && checkout.members.contains { member in
                guard member.projectID == worktree.projectId,
                      URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath)).standardizedFileURL.path == path
                else { return false }
                if let memberLineage = member.gitLineageID, let lineage = worktree.lineageID, memberLineage != lineage {
                    return false
                }
                return !(member.availability == .explicitlyDeleted && member.cleanup?.worktreeRemoved == true)
            }
        }
    }

    private func setWorktreeHidden(_ path: URL, projectID: String, hidden: Bool) throws {
        guard projects.projects.contains(where: { $0.id == projectID }) else {
            throw ProjectCreationError.projectNotFound
        }
        let wasHidden = projects.isWorktreeHidden(projectId: projectID, path: path)
        projects.setWorktreeHidden(projectId: projectID, path: path, hidden: hidden)
        do {
            try saveProjects()
        } catch {
            projects.setWorktreeHidden(projectId: projectID, path: path, hidden: wasHidden)
            throw error
        }
    }

    /// Shuts down the owner's agent sessions, persisting what they hold and
    /// releasing their leases, and forgets the manager.
    public func disposeSessionManager(owner: SessionOwnerID) async {
        guard let manager = sessionManagers.removeValue(forKey: owner) else { return }
        manager.flushPendingDraftWrites()
        for runner in manager.runners.values {
            runner.stop()
        }
        manager.prepareForDisposal()
        await Self.finishDisposing(manager)
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
    /// handed out for an archived worktree, including while it is being
    /// archived.
    public func sessionManager(for worktree: Worktree) throws -> ACPSessionManager {
        guard !isArchivedOrArchiving(worktree) else { throw WorktreeArchived() }
        let owner = SessionOwnerID.worktree(worktree.id)
        if let manager = sessionManagers[owner] { return manager }
        let manager = makeSessionManager(owner, worktree)
        sessionManagers[owner] = manager
        return manager
    }
}
