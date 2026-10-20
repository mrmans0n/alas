import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP
import AlasAgentKit
import AlasSessions

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
    /// Watches bound pull and merge requests; AppState installs its effects.
    public let reviewShepherd: ReviewShepherd
    /// Waits for a run's completion file. Injectable so tests can settle runs.
    @ObservationIgnored public let runCompletionWaiter: RunCompletionWaiter
    /// Runs whose completion is being waited for, keyed by run ID.
    @ObservationIgnored @_spi(AppHost) @_spi(Testing) public var runObservations: [String: RunObservation] = [:]
    /// Told exactly once when a run settles, keyed by run ID. The worktree is
    /// carried so a worktree teardown can settle every run it owns, including
    /// ones that never produced an archivable record.
    @ObservationIgnored @_spi(Testing) public internal(set) var runSettlementHandlers: [String: (worktreeID: String, notify: (RunScriptSettlement) -> Void)] = [:]

    /// The on-device text model's files and state.
    @ObservationIgnored public let localTextModelStore: LocalTextModelStore
    /// The on-device text engine every local-text feature shares.
    @ObservationIgnored public private(set) lazy var localText: any LocalTextGenerating =
        localTextOverride ?? LocalTextEngine.make(localTextModelStore)
    @ObservationIgnored public private(set) lazy var sessionSummaries = SessionSummaryCoordinator(
        engine: localText,
        modelID: "\(LocalTextModelManifest.pinnedModel)@\(LocalTextModelManifest.pinnedRevision)"
    )
    @ObservationIgnored private let localTextOverride: (any LocalTextGenerating)?
    /// Durable Workspace definitions and checkouts.
    @ObservationIgnored public let workspaceStore: WorkspaceStore
    /// What the host adds to lifecycles: the app's terminals, prompts and
    /// refresh, or nothing when headless.
    @ObservationIgnored public let environment: any AlasHostEnvironment
    @ObservationIgnored private var workspaceCheckoutCoordinator: WorkspaceCheckoutCoordinator?
    /// Checkouts `unarchiveWorkspaceCheckout` is reactivating. Archive treats
    /// their members as owned already: the coordinator checks them before
    /// the store flips, and display snapshots catch up only afterwards.
    /// Counted, since two unarchives of one checkout can overlap.
    @ObservationIgnored var unarchivingWorkspaceCheckouts: [UUID: Int] = [:]
    /// Test hooks for preparing a new worktree's destination: a project's
    /// branches, the prepared path, and a command on the project's host.
    @_spi(Testing) @ObservationIgnored public var worktreeBranchLoader: (@MainActor (URL) async throws -> [String])?
    @_spi(Testing) @ObservationIgnored public var worktreeDestinationPreparer: (@MainActor (URL, URL) async throws -> URL)?
    @_spi(Testing) @ObservationIgnored public var remoteCommandRunner: (@MainActor (String, String?, String) async throws -> ProcessResult)?
    /// Test hook that replaces connecting a new session to its agent.
    @_spi(Testing) @ObservationIgnored public var sessionAttachScheduler: (@MainActor (ACPSessionManager, ACPSession.ID) -> Void)?

    /// Attention items and the gate observations pass through to reach them.
    public let attention: AttentionIntake
    /// Agents' activity as their hooks and sessions report it, and the
    /// notifications that report it to the user.
    @ObservationIgnored public let harness: HarnessService
    /// Delegated sessions: who created whom, and the messages between them.
    @ObservationIgnored public let orchestrationPersistence: ACPOrchestrationPersistence
    /// The one coordinator of delegated sessions. It keeps which deliveries
    /// are in flight, so a host has exactly one.
    @ObservationIgnored public private(set) lazy var orchestration = makeOrchestrationCoordinator()
    /// Review comments drafted on a worktree's changes, and the review
    /// sessions they belong to.
    @ObservationIgnored public let reviewDrafts: ReviewDraftCommentStore
    @ObservationIgnored public let reviewSessions: ReviewSessionStore
    /// Sent when review comments change outside a review's own view.
    @ObservationIgnored public let reviewCommentChanges = ChangeSignal<Void>()
    /// Whether a new worktree's destination is taken, on the project's own
    /// host. Replaceable so tests can stand in for that host.
    @ObservationIgnored public var worktreeDestinationExistence: @Sendable (URL, String?) async -> ScheduledWorktreeDestination.PathState = {
        await ScheduledWorktreeDestination.existence(of: $0, onHost: $1)
    }
    /// One per project: a free-name creation holds it from picking a free
    /// name until the worktree exists, so the next pick sees it.
    @ObservationIgnored var freeNameGates: [String: SerialGate] = [:]
    /// The PR creation running for each worktree; one waits for another.
    @ObservationIgnored var prCreateTasks: [String: Task<AlasCLIResponse, Never>] = [:]
    /// Each repository's `.alas/config.json`, read once per change.
    @ObservationIgnored public let repoConfigStore = RepoConfigStore()
    /// Agents' turns and usage limits, as usage views and plugins read them.
    @ObservationIgnored public let usageHistory: UsageHistoryStore?
    /// Each worktree's pull request and checks, by worktree id, kept while
    /// the host runs so every reader sees the one state.
    @ObservationIgnored public internal(set) var reviewLoops: [String: ReviewLoopState] = [:]
    /// How many followers each worktree's review status has, and the task
    /// refreshing the status of those with any.
    @ObservationIgnored var reviewFollowers: [String: Int] = [:]
    @ObservationIgnored var reviewRefreshes: [String: Task<Void, Never>] = [:]
    /// The configured base branch each review loop last took.
    @ObservationIgnored var reviewLoopConfiguredBases: [String: String] = [:]
    /// Reads a followed worktree's review status; `refreshReviewStatus` unless a test replaces it.
    @_spi(Testing) @ObservationIgnored public var reviewStatusRefresh: (@MainActor (String) async -> Void)?
    /// Waits between two reads of a followed worktree's review status.
    @_spi(Testing) @ObservationIgnored public var reviewStatusPause: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Test hook that replaces reading a worktree's Git status for reviews.
    @_spi(Testing) @ObservationIgnored public var reviewGitStatus: (@MainActor (URL) async throws -> [ChangedFile])?
    /// Each delegated session's parent, by child id. Observed: the app draws
    /// children under their parents from it.
    public internal(set) var delegatedSessionParents: [String: String] = [:] {
        didSet { if delegatedSessionParents != oldValue { environment.delegatedSessionParentsChanged() } }
    }

    /// Launches claimed and still starting, by run slot.
    @ObservationIgnored var pendingRunLaunches: [RunSlotKey: PendingRunLaunch] = [:]
    /// Set once `AlasHost.shutdown()` begins: nothing new starts after it,
    /// requests already underway included.
    @ObservationIgnored var isStopping = false
    /// Host-protocol requests being served. Shutdown waits for them to
    /// finish, so none is cut off with a subprocess it started (Git, SSH,
    /// a repository check) still running.
    @ObservationIgnored var requestsUnderway = 0

    /// Refuses work once the host is stopping, checked where the work would
    /// start, after a request's last suspension.
    func refuseIfStopping() throws {
        if isStopping { throw HostStopping() }
    }
    /// Runs in a plain process the launcher started, by run ID.
    @ObservationIgnored var processRuns: [String: (worktreeID: String, projectID: String, scriptKey: String, task: Task<RunScriptCompletion, Error>)] = [:]
    /// Runs and launches stopped but not yet ended: cancelling them returns
    /// before their process exits, so shutdown waits on these.
    @ObservationIgnored var stoppingRuns: [UUID: Task<Void, Never>] = [:]
    /// Why a run in a plain process ended without reporting, for `runScript`.
    @ObservationIgnored var processRunErrors: [String: any Error] = [:]
    /// How long a run outlives its host session before it is given up on.
    @ObservationIgnored public let runHostGrace: RunHostGrace

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
        reviewShepherd: ReviewShepherd? = nil,
        localTextModelStore: LocalTextModelStore = LocalTextModelStore(),
        localText: (any LocalTextGenerating)? = nil,
        attentionStore: AttentionStore? = nil,
        runCompletionWaiter: @escaping RunCompletionWaiter = { try await RunScriptCompletionMonitor.wait(for: $0) },
        makeSessionManager: @escaping @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager = AlasCoreContext.defaultSessionManager,
        environment: any AlasHostEnvironment = HeadlessHostEnvironment(),
        runHostGrace: RunHostGrace = RunHostGrace(),
        harness: HarnessService = HarnessService(),
        orchestrationPersistence: ACPOrchestrationPersistence = ACPOrchestrationPersistence(),
        reviewDrafts: ReviewDraftCommentStore = ReviewDraftCommentStore(),
        reviewSessions: ReviewSessionStore = ReviewSessionStore(),
        usageHistory: UsageHistoryStore? = nil
    ) {
        self.projects = projects
        self.runs = runs
        self.runScheduler = runScheduler ?? RunScheduler(store: store)
        self.reviewShepherd = reviewShepherd ?? ReviewShepherd(store: store)
        self.runCompletionWaiter = runCompletionWaiter
        self.runHistory = RunHistory(store: runHistoryStore)
        self.attention = AttentionIntake(store: attentionStore ?? AttentionStore())
        self.harness = harness
        self.orchestrationPersistence = orchestrationPersistence
        self.reviewDrafts = reviewDrafts
        self.reviewSessions = reviewSessions
        self.usageHistory = usageHistory
        self.localTextModelStore = localTextModelStore
        self.localTextOverride = localText
        self.workspaceStore = workspaceStore
        self.environment = environment
        self.runHostGrace = runHostGrace
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
        try refuseIfStopping()
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
        // Adding awaits the repository's checks; the host can start stopping meanwhile.
        guard !isStopping else {
            projects.removeProject(id: project.id)
            throw HostStopping()
        }
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

    /// The one coordinator for Workspace checkout lifecycles. It reads the
    /// authoritative store, never a display cache, when deciding which
    /// sessions to stop.
    public func workspaceCoordinator() -> WorkspaceCheckoutCoordinator {
        if let workspaceCheckoutCoordinator { return workspaceCheckoutCoordinator }
        let coordinator = WorkspaceCheckoutCoordinator(
            store: workspaceStore,
            sessions: WorkspaceCheckoutSessionStopper(
                store: workspaceStore,
                stop: { [weak self] checkout in
                    guard let self else { return }
                    try await environment.stopWorkspaceCheckoutSessions(checkout, in: self)
                }
            ),
            resolveRepoHook: { [weak self] request in
                try await self?.resolveWorkspaceRepoHook(request)
            },
            memberAdmitsWork: { [weak self] projectID, path in
                let worktreeID = Worktree.makeId(path: URL(fileURLWithPath: path))
                return await self?.projects.operationState(forWorktreeId: worktreeID, projectId: projectID)?.blocksAdmission != true
            }
        )
        workspaceCheckoutCoordinator = coordinator
        return coordinator
    }

    private func resolveWorkspaceRepoHook(_ request: WorkspaceRepoHookRequest) async throws -> String? {
        try await environment.resolveWorkspaceRepoHook(request)
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
    /// handed out, cached or new, while the worktree is being created or
    /// deleted.
    public func sessionManager(for worktree: Worktree) throws -> ACPSessionManager {
        guard projects.admitsNewWork(in: worktree) else { throw WorktreeOperationInProgress() }
        let owner = SessionOwnerID.worktree(worktree.id)
        if let manager = sessionManagers[owner] { return manager }
        let manager = makeSessionManager(owner, worktree)
        let worktreeId = worktree.id
        manager.admitsNewWork = { [weak self] in self?.projects.admitsNewWork(worktreeId: worktreeId) ?? false }
        sessionManagers[owner] = manager
        return manager
    }

    /// The session manager for a local Workspace checkout, created on first
    /// use through the same factory as a worktree's, at the checkout's root.
    /// None is handed out for one that is archived, busy, remote, or whose
    /// root is gone.
    public func sessionManager(forCheckout checkout: WorkspaceCheckout) throws -> ACPSessionManager {
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        if let manager = sessionManagers[owner] { return manager }
        guard checkout.archivedAt == nil, checkout.operation == .idle else {
            throw SessionRefusal.ownerUnavailable(reason: "The Workspace checkout is archived or busy.")
        }
        guard checkout.executionLocation.normalized == .local else {
            throw SessionRefusal.ownerUnavailable(reason: "Sessions in remote Workspace checkouts start from the app.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: checkout.rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionRefusal.ownerUnavailable(reason: "The Workspace checkout's folder is missing.")
        }
        let root = URL(fileURLWithPath: checkout.rootPath)
        let manager = makeSessionManager(owner, Worktree(
            id: owner.storageKey, projectId: "", name: checkout.fallbackWorkspaceName, branch: checkout.branch,
            path: root, status: .clean, lastActivity: Date()
        ))
        sessionManagers[owner] = manager
        return manager
    }
}
