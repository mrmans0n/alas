@_spi(AppHost) import AlasCore
import AppKit
import Foundation
import Observation
import os

enum ReviewSessionConsolidation {
    static func merge(existing: ReviewSessionRecord, source: ReviewSessionRecord) -> ReviewSessionRecord {
        var merged = existing
        if merged.selectedFileID == nil {
            merged.selectedFileID = source.selectedFileID
        }
        if merged.focusedCommentID == nil {
            merged.focusedCommentID = source.focusedCommentID
        }
        if merged.handoffs.isEmpty {
            merged.handoffs = source.handoffs
        } else {
            let existingHandoffIDs = Set(merged.handoffs.map(\.id))
            merged.handoffs.append(contentsOf: source.handoffs.filter { !existingHandoffIDs.contains($0.id) })
        }
        if merged.lastSendError == nil {
            merged.lastSendError = source.lastSendError
        }
        if merged.verdict == nil {
            merged.verdict = source.verdict
        }
        if merged.verdict != nil {
            merged.status = .reviewed
        } else if merged.status == .active, source.status != .active {
            merged.status = source.status
        }
        merged.updatedAt = max(merged.updatedAt, source.updatedAt)
        return merged
    }
}

enum WorkspaceDefinitionSaveError: LocalizedError {
    case spacePlacementFailed
    case workspacePersistenceFailed
    case spacePlacementRollbackFailed
    case checkoutsNotFullyRemoved

    var errorDescription: String? {
        switch self {
        case .spacePlacementFailed:
            "Could not place the Workspace in the active Space."
        case .workspacePersistenceFailed:
            "Could not save the Workspace definition."
        case .spacePlacementRollbackFailed:
            "Could not restore the active Space after the Workspace definition failed to save."
        case .checkoutsNotFullyRemoved:
            "Some checkouts still need attention. Delete them individually, then delete the workspace."
        }
    }
}

struct RemoteWorktreeStatusProjectScanToken: Equatable {
    let projectID: String
    let generation: Int
    private let worktreeGenerationsByID: [String: Int]

    init(projectID: String, generation: Int, worktreeGenerationsByID: [String: Int]) {
        self.projectID = projectID
        self.generation = generation
        self.worktreeGenerationsByID = worktreeGenerationsByID
    }

    func worktreeGeneration(worktreeID: String) -> Int? {
        worktreeGenerationsByID[worktreeID]
    }
}

struct RemoteWorktreeStatusWorktreeScanToken: Equatable {
    let projectID: String
    let worktreeID: String
    let generation: Int
}

struct RemoteWorktreeStatusRescanGenerations {
    private var generations: [String: Int] = [:]

    mutating func beginProjectScan(
        projectID: String,
        worktreeIDs: [String]
    ) -> RemoteWorktreeStatusProjectScanToken {
        let projectGeneration = bump(projectID)
        let worktreeGenerations = Dictionary(
            uniqueKeysWithValues: Set(worktreeIDs).map { worktreeID in
                (worktreeID, bump(worktreeKey(projectID: projectID, worktreeID: worktreeID)))
            }
        )
        return RemoteWorktreeStatusProjectScanToken(
            projectID: projectID,
            generation: projectGeneration,
            worktreeGenerationsByID: worktreeGenerations
        )
    }

    mutating func beginWorktreeScan(
        projectID: String,
        worktreeID: String
    ) -> RemoteWorktreeStatusWorktreeScanToken {
        let generation = bump(worktreeKey(projectID: projectID, worktreeID: worktreeID))
        return RemoteWorktreeStatusWorktreeScanToken(
            projectID: projectID,
            worktreeID: worktreeID,
            generation: generation
        )
    }

    func isCurrent(_ token: RemoteWorktreeStatusProjectScanToken) -> Bool {
        generations[token.projectID] == token.generation
    }

    func isCurrent(_ token: RemoteWorktreeStatusWorktreeScanToken) -> Bool {
        generations[worktreeKey(projectID: token.projectID, worktreeID: token.worktreeID)] == token.generation
    }

    func isCurrentWorktree(projectID: String, worktreeID: String, generation: Int) -> Bool {
        generations[worktreeKey(projectID: projectID, worktreeID: worktreeID)] == generation
    }

    private mutating func bump(_ key: String) -> Int {
        let next = (generations[key] ?? 0) + 1
        generations[key] = next
        return next
    }

    private func worktreeKey(projectID: String, worktreeID: String) -> String {
        "\(projectID)\u{0}\(worktreeID)"
    }
}

@Observable
@MainActor
final class AppState {
    typealias CloseTabConfirmer = @MainActor (CloseTabConfirmationPolicy.Prompt) -> Bool
    typealias ACPDetachRunner = @MainActor (ACPSessionManager, ACPSession.ID) async -> Void
    typealias RemoteAccelerationPreparer = @MainActor (ProjectConfig) async -> Void
    typealias WorktreeCleanupLauncher = @MainActor (WorktreeTrashCleanupTicket) throws -> Void
    static let piMCPGeneratedConfigExcludePath = ".pi/mcp.json"

    /// Stable for this process; identifies this app instance to the ACP
    /// session-lease layer so two running Alas builds don't fight over a
    /// shared per-worktree database.
    let instanceId: String = UUID().uuidString
    var localTextModelStore: LocalTextModelStore { core.localTextModelStore }
    @ObservationIgnored let localTextReadModelState: @Sendable () async -> LocalTextModelState
    @ObservationIgnored let nextPromptInferenceOverride: (any NextPromptRuntime)?
    var localTextInference: any LocalTextGenerating { core.localText }
    @ObservationIgnored lazy var nextPromptInference: any NextPromptRuntime = makeNextPromptInference()
    private func makeNextPromptInference() -> any NextPromptRuntime {
        if let nextPromptInferenceOverride { return nextPromptInferenceOverride }
        let store = localTextModelStore
        return NextPromptInference(
            engine: localTextInference,
            supported: { [localTextSupported] in localTextSupported },
            verifyAvailability: {
                let lease = try await store.acquireVerifiedLease()
                lease.close()
            },
            clock: .init(),
            scheduleCancellation: { action in _ = Task { await action() } }
        )
    }
    @ObservationIgnored lazy var nextPromptCoordinator = NextPromptCoordinator(engine: nextPromptInference) { [weak self] turn in
        self?.nextPromptSnapshot(for: turn)
    }
    var sessionSummaryCoordinator: SessionSummaryCoordinator { core.sessionSummaries }
    @ObservationIgnored let localTextObservers = LocalTextObservers()
    @ObservationIgnored let sessionRecapRuntime = SessionRecapRuntime()
    @ObservationIgnored lazy var sessionRecapPrecomputeScheduler = SessionRecapPrecomputeScheduler(
        now: { Date() },
        sleep: { try await Task.sleep(for: $0) },
        run: { [weak self] sessionId in await self?.runRecapPrecompute(sessionId: sessionId) ?? .skipped }
    )
    @ObservationIgnored let qwenTitleRequests = ACPQwenTitleRequests()
    @ObservationIgnored private var worktreeExplainerStoreInstance: WorktreeExplainerStore?
    var worktreeExplainerStore: WorktreeExplainerStore {
        get {
            if let worktreeExplainerStoreInstance { return worktreeExplainerStoreInstance }
            let store = WorktreeExplainerStore { [weak self] evidence in
                guard let self else { return nil }
                return await self.makeWorktreeExplainerSuggester().suggest(for: evidence)
            }
            worktreeExplainerStoreInstance = store
            return store
        }
        set { worktreeExplainerStoreInstance = newValue }
    }

    @ObservationIgnored let issueWorktreeNameRequests = IssueWorktreeNameRequests()
    @ObservationIgnored var localTextInstallation: Task<Void, Never>?
    let localTextSupported: Bool
    var localTextModelState: LocalTextModelState = .notInstalled
    var nextPromptInferenceState: NextPromptInferenceState = .ready
    var nextPromptRuntimeEnabled = false
    var nextPromptDisableSavePending = false
    var nextPromptSettingsError: String?
    var sessionSummariesRuntimeEnabled = false {
        didSet {
            guard sessionSummariesRuntimeEnabled != oldValue else { return }
            sessionSummariesRuntimeEnabledChanged()
        }
    }
    var sessionSummaryDisableSavePending = false
    var sessionSummarySettingsError: String?
    var localTextRemovalFailure: LocalTextModelFailure?
    var localTextModelDisableSavePending = false
    var localTextModelPermissionChangeInProgress = false
    var localTextModelSettingsError: String?
    var onDeviceAIHelperSettingsError: String?
    @ObservationIgnored var localTextPermissionGeneration: UInt64 = 0
    var nextPromptOffer: String?
    @ObservationIgnored var nextPromptSettingsGeneration: UInt64 = 0
    @ObservationIgnored var sessionSummarySettingsGeneration: UInt64 = 0
    @ObservationIgnored var sessionSummaryCleanupTask: Task<Void, Never>?
    @ObservationIgnored var localTextModelGeneration: UInt64 = 0
    @ObservationIgnored var localTextSettingsInspected = false
    @ObservationIgnored var localTextRuntimeStarted = false
    var localTextRemovalInProgress = false
    @ObservationIgnored var nextPromptComposerEpochs: [UUID: UInt64] = [:]
    @ObservationIgnored var nextPromptShuttingDown = false
    @ObservationIgnored var nextPromptOwner: SessionOwnerID?
    @ObservationIgnored var nextPromptSessionID: String?
    @ObservationIgnored var nextPromptActiveIncarnation: UUID?
    @ObservationIgnored var nextPromptComposerEnvironment = NextPromptEligibilitySnapshot.Environment()
    var config: AppConfig
    var themeStore: ThemeStore
    /// The headless core: projects, worktrees and session managers.
    let core: AlasCoreContext
    /// The app's side of the core's lifecycles.
    let hostEnvironment: AppHostEnvironment
    /// The core's public API. Paths move onto it from `core` as they are
    /// migrated.
    let host: AlasHost
    /// Serves `host` to local clients over the host protocol, from launch.
    @ObservationIgnored private(set) var hostSocket: HostSocketServer?
    /// Sent when what the Remote session list shows changes without a host
    /// event: a session tab opening, closing or moving, or the Git status of
    /// a worktree with sessions. Followed from its first read.
    @ObservationIgnored private var remoteSessionListChanges: ChangeSignal<Void>?
    @ObservationIgnored private var remoteSessionListInputs: [SessionOwnerID: RemoteSessionListInputs] = [:]
    var projectsManager: ProjectsManager {
        get { core.projects }
        set { core.projects = newValue }
    }
    let worktreeUpstreamStatusStore = WorktreeUpstreamStatusStore()
    /// Repo-local `.alas/` config, read per worktree with its own change cache.
    var repoConfigStore: RepoConfigStore { core.repoConfigStore }
    let repoHookApprovalQueue = RepoHookApprovalQueue()
    var repoHookLoader: RepoHookLoader {
        get { hostEnvironment.repoHookLoader }
        set { hostEnvironment.repoHookLoader = newValue }
    }
    /// Project icons already resolved from repo files, keyed by the identity of
    /// the file that supplied them.
    let repoIconDisplayCache = RepoIconDisplayCache()
    /// Where resolved repo icons are staged before rendering. Injectable so
    /// tests never write into the real project-icon store.
    @ObservationIgnored var repoIconStagingRoot: URL = Paths.projectIconsRoot
    private(set) var closedTabHistory = ClosedTabHistory()
    var runScriptFailureQueue = RunScriptFailureQueue()
    let runFailureBriefs = RunFailureBriefCoordinator()
    let inAppNotifications = InAppNotificationStore()
    /// Observed command lifecycles, keyed by worktree then script. Deliberately
    /// separate from `tabs`: a run's outcome outlives its terminal shell, and a
    /// live shell never implies a live command.
    var runRecords: RunRecordStore {
        get { core.runRecords }
        set { core.runRecords = newValue }
    }
    var runHistory: RunHistory { core.runHistory }
    /// Immutable completed-run history. A missing store keeps the live Run
    /// tab functional when Application Support cannot be opened.
    var runHistoryStore: RunHistoryStore? { core.runHistory.store }
    /// Token, cost and usage-limit history of every agent turn; nil when Application Support cannot be opened.
    var usageHistory: UsageHistoryStore? { core.usageHistory }
    /// Records each session's turns in completion order.
    @ObservationIgnored let usageRecording = KeyedSerialQueue()
    /// Worktrees whose branch is being named from their first chat prompt.
    var autoNamingWorktreeIds: Set<String> = []
    /// Sessions whose Ship is resolving its prompt, so a repeat click is absorbed.
    @ObservationIgnored var preparingShipSessionIDs: Set<ACPSession.ID> = []
    /// Follow-up composers outlive the conditional Agent pane and worktree navigation.
    var agentSidebarFollowUps: [String: [ACPSession.ID: AgentSidebarFollowUpDraft]] = [:]
    var attentionStore: AttentionStore { core.attention.store }
    /// Debug: show the first-run screen even when projects exist.
    var isPreviewingFirstRunScreen = false
    /// Debug: cycle the center pane through the forest loading and empty states.
    var isPreviewingForestScenes = false
    var isAttentionInboxOpen = false {
        didSet {
            if oldValue != isAttentionInboxOpen {
                attentionNavigationGeneration += 1
                if isAttentionInboxOpen { attentionPendingReviewReveal = nil }
            }
        }
    }
    @ObservationIgnored var attentionNavigationGeneration = 0
    @ObservationIgnored var attentionNavigationDepth = 0
    var attentionNavigationErrors: [UUID: String] = [:]
    @ObservationIgnored var attentionNavigationEnvironment: AttentionNavigationEnvironment?
    var attentionSuppressedStartupSignals: [AttentionSourceKey: String] {
        get { core.attention.suppressedStartupSignals }
        set { core.attention.suppressedStartupSignals = newValue }
    }
    @ObservationIgnored var attentionInitializedSnapshotSources: Set<String> = []
    @ObservationIgnored var attentionPendingReviewReveal: AttentionPendingReviewReveal?
    @ObservationIgnored var attentionAliasRetryTask: Task<Void, Never>?
    @ObservationIgnored var attentionAliasRetryAttempts = 0
    @ObservationIgnored var attentionAliasRetryNotBefore: Date?
    /// The `pr_create` running per worktree. A concurrent call waits for it
    /// instead of pushing or opening a second request.
    /// Decides when scheduled runs start. Execution is delegated back here so
    /// a scheduled run is a manual run with a different trigger.
    var runScheduler: RunScheduler { core.runScheduler }
    /// Scheduled chat sessions whose first turn a firing is waiting on.
    var scheduledAgentTurns: ScheduledAgentTurns { core.scheduledAgentTurns }
    /// Serves computer_* calls: approvals, the driver lock, stop/resume.
    let computerUse: ComputerUseCoordinator
    @ObservationIgnored var computerUseStatusItem: ComputerUseStatusItem?
    @ObservationIgnored var computerUseStopHotKey: ComputerUseStopHotKey?
    /// The models each ACP agent last advertised, for surfaces that configure
    /// a session before it exists (the schedule editor's model picker).
    let acpModelCatalog: ACPAgentModelCatalog
    /// Host-aware script discovery used by scheduled runs. Injectable so tests
    /// can stand in for SSH discovery on a remote project.
    @ObservationIgnored var runScheduleScriptDiscovery: @Sendable (URL, String?) async -> RunScriptStore.DiscoveryResult = {
        await RunScriptStore.discoverScripts(worktreeRoot: $0, remoteHost: $1)
    }
    /// Whether the destination a scheduled composition is about to claim is
    /// already taken. A remote project's worktree lives on its host's
    /// filesystem, which `FileManager` cannot see, so the question has to go
    /// to the host that will actually run `git worktree add`. Injectable so
    /// tests can stand in for that host.
    var scheduledDestinationExistence: @Sendable (URL, String?) async -> ScheduledWorktreeDestination.PathState {
        get { core.worktreeDestinationExistence }
        set { core.worktreeDestinationExistence = newValue }
    }
    /// Waits until the agent launched in a terminal session is the one
    /// reading its input, so a scheduled prompt lands in the agent and not in
    /// the shell that is still starting it. Returns false on timeout. Nil
    /// uses the harness detector; tests inject one because their sessions
    /// have no process behind them.
    @ObservationIgnored var scheduledAgentReadiness: ((String) async -> Bool)?
    /// Types text into a terminal session, as if from the keyboard. Returns
    /// false when the session is gone. Nil types into the session's Ghostty
    /// surface; tests inject one because theirs have no surface.
    @ObservationIgnored var terminalTextSender: ((String, String) -> Bool)?
    private(set) var isReopeningClosedTab = false
    var canReopenClosedTab: Bool { !isReopeningClosedTab && !closedTabHistory.isEmpty }
    private var unpersistedGGWorktreeModes: [String: [String: GGWorktreeMode]] = [:]
    private var centerGitMutationCounts: [String: Int] = [:]
    var spacesManager: SpacesManager
    var workspacesManager: WorkspacesManager
    private var workspaceStore: WorkspaceStore { core.workspaceStore }
    @ObservationIgnored let workspaceRemoteTransport: WorkspaceRemoteTransport
    @ObservationIgnored private let checkpointWriterLeases = CheckpointWriterLeaseStore()
    /// Session candidates for each peer-viewed session's `@` picker, loaded
    /// when the picker opens and reused while its query changes.
    /// Recovery information for a Workspace state file that could not be read.
    /// Observable so Settings and future Workspace navigation can keep the
    /// affected data visible instead of silently treating it as empty.
    private(set) var workspaceRecoveryError: WorkspaceRecoveryState?
    /// Exists only while `config.pluginsEnabled` is on.
    var pluginManager: PluginManager?
    /// For each project a plugin listens for `review.changed` in, the host
    /// subscription that follows its worktrees' review status.
    @ObservationIgnored var pluginReviewFollows: [String: HostSubscription] = [:]
    var workspaceNavigationState = WorkspaceNavigationState()
    @ObservationIgnored private var workspaceSpaceCheckpointTask: Task<Void, Never>?
    @ObservationIgnored private var worktreeStatusRescanTask: Task<Void, Never>?
    @ObservationIgnored private var archivedWorktreePruneTask: Task<Void, Never>?
    @ObservationIgnored var worktreeCleanupReminderTask: Task<Void, Never>?
    @ObservationIgnored var worktreeCleanupReminderScannedAt: [String: Date] = [:]
    /// Project id → worktrees the cleanup sheet would preselect, from the
    /// latest background scan.
    var worktreeCleanupReadyIds: [String: Set<String>] = [:]
    /// Project id → the ready set the user dismissed the reminder for.
    var worktreeCleanupDismissedIds = WorktreeCleanupReminderPolicy.loadDismissals()
    var worktreeCleanupPresentation: WorktreeCleanupPresentation? {
        didSet {
            // Whatever the sheet removed changes the reminder, so rescan on close.
            if let closed = oldValue, worktreeCleanupPresentation?.id != closed.id {
                Task { await refreshWorktreeCleanupReminder(projectId: closed.projectId) }
            }
        }
    }
    @ObservationIgnored private lazy var ggSidebarRefresh = GGSidebarRefreshController()
    @ObservationIgnored private var ggSidebarPreparationTask: Task<Void, Never>?
    private var ggSidebarSnapshots: [String: GGConfigReader.SidebarSnapshot] = [:]
    @ObservationIgnored private var worktreeSelectionFollowUp: Task<Void, Never>?
    @ObservationIgnored private var worktreeSelectionFollowUpGeneration = 0
    @ObservationIgnored private var pendingWorktreeStatusRescanPaths: [URL] = []
    @ObservationIgnored private var remoteWorktreeStatusRescanTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var remoteWorktreeStatusRescanGenerations = RemoteWorktreeStatusRescanGenerations()
    var selectedWorktreeId: String? {
        didSet {
            guard oldValue != selectedWorktreeId else { return }
            attentionNavigationGeneration += 1
            if startupRecoveryNeedsMountedRightPaneRefresh {
                startupRecoveryReadyRightPaneID = nil
            }
            worktreeSelectionFollowUpGeneration += 1
            attentionPendingReviewReveal = nil
            if let oldValue { rightPaneStore.activeState(worktreeId: oldValue)?.endAttentionReveal() }
        }
    }
    private(set) var suppressesRestoredRightPaneAfterAbandonedStartup: Bool
    private var startupRecoveryNeedsMountedRightPaneRefresh: Bool
    private var startupRecoveryReadyRightPaneID: String?
    private(set) var isRefreshingProjectTopologies = false
    var pendingSettingsSection: SettingsSection?
    @ObservationIgnored
    private var _tabs: TabsManager?
    var tabs: TabsManager {
        if let _tabs { return _tabs }
        let manager = TabsManager(lsp: lsp)
        manager.onCommitPublishCompletion = { [weak self] worktreeId, tabId in
            self?.closedTabHistory.purgeCommitPublishDraft(worktreeID: worktreeId, tabID: tabId)
        }
        manager.onCreatedReview = { [weak self] worktreeId, review in
            self?.inAppNotifications.post(
                "\(review.provider.reviewRequestLabel) \(review.provider == .gitlab ? "!" : "#")\(review.number) created",
                severity: .success,
                worktreeID: worktreeId
            )
        }
        _tabs = manager
        return manager
    }
    let terminal = TerminalService()
    @ObservationIgnored
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "AppState")
    struct OpenedTerminalSession {
        let id: String
        let foregroundPid: @Sendable () -> pid_t?
    }

    func beginCenterGitMutation(worktreeId: String) {
        centerGitMutationCounts[worktreeId, default: 0] += 1
    }

    func endCenterGitMutation(worktreeId: String) {
        let next = max((centerGitMutationCounts[worktreeId] ?? 0) - 1, 0)
        if next == 0 {
            centerGitMutationCounts[worktreeId] = nil
        } else {
            centerGitMutationCounts[worktreeId] = next
        }
    }

    func hasCenterGitMutationInFlight(worktreeId: String) -> Bool {
        (centerGitMutationCounts[worktreeId] ?? 0) > 0 || tabs.hasRunningCommitPublish(worktreeId: worktreeId)
    }

    func checkpointFileWritesDisabled(worktreeId: String) -> Bool {
        rightPaneStore.activeState(worktreeId: worktreeId)?.checkpointMutationsDisabled ?? true
    }

    func checkpointFileWritesDisabledAfterDiscovery(worktreeId: String) async -> Bool {
        await checkpointMutationsDisabledAfterDiscovery(worktreeId: worktreeId)
    }

    func checkpointTerminalAdmissionDisabled(worktreeId: String) -> Bool {
        rightPaneStore.activeState(worktreeId: worktreeId)?.checkpointRestoreBlocksWriters ?? false
    }

    func checkpointTerminalAdmissionDisabledAfterDiscovery(worktreeId: String) async -> Bool {
        await checkpointRestoreBlocksWritersAfterDiscovery(worktreeId: worktreeId)
    }

    func checkpointACPAdmissionDisabledAfterDiscovery(worktreeId: String) async -> Bool {
        await checkpointMutationsDisabledAfterDiscovery(worktreeId: worktreeId)
    }

    func checkpointACPAdmissionDisabledAfterDiscovery(owner: SessionOwnerID?, fallbackWorktree: Worktree?) async -> Bool {
        switch owner ?? fallbackWorktree.map({ .worktree($0.id) }) {
        case .worktree(let worktreeID):
            return await checkpointACPAdmissionDisabledAfterDiscovery(worktreeId: worktreeID)
        case .workspaceCheckout(let checkoutID, let location):
            guard let checkout = workspacesManager.checkout(id: checkoutID),
                  checkout.executionLocation.normalized == location.normalized
            else { return true }
            return await checkpointTerminalAdmissionDisabledAfterDiscovery(for: checkout)
        case nil:
            return true
        }
    }

    func checkpointWorktreeRemovalDisabledAfterDiscovery(_ worktree: Worktree) async -> Bool {
        await checkpointMutationsDisabledAfterDiscovery(for: worktree)
    }

    private func checkpointMutationsDisabledAfterDiscovery(worktreeId: String) async -> Bool {
        guard let (_, worktree) = projectAndWorktree(withWorktreeId: worktreeId) else {
            return true
        }
        return await checkpointMutationsDisabledAfterDiscovery(for: worktree)
    }

    private func checkpointRestoreBlocksWritersAfterDiscovery(worktreeId: String) async -> Bool {
        guard let (_, worktree) = projectAndWorktree(withWorktreeId: worktreeId) else {
            return false
        }
        return await checkpointRestoreBlocksWritersAfterDiscovery(for: worktree)
    }

    private func checkpointMutationsDisabledAfterDiscovery(for worktree: Worktree) async -> Bool {
        let pane = rightPaneStore.state(
            for: worktree,
            baseBranch: config.worktrees.baseBranch,
            comparisonMode: config.changes.comparisonMode
        )
        return await pane.checkpointMutationsDisabledAfterJournalRevalidation()
    }

    private func checkpointRestoreBlocksWritersAfterDiscovery(for worktree: Worktree) async -> Bool {
        let pane = rightPaneStore.state(
            for: worktree,
            baseBranch: config.worktrees.baseBranch,
            comparisonMode: config.changes.comparisonMode
        )
        return await pane.checkpointRestoreBlocksWritersAfterJournalRevalidation()
    }

    typealias TerminalSessionOpener = (
        Worktree,
        ProjectConfig,
        AppConfig.Terminal,
        Theme,
        URL?,
        String?,
        Bool,
        [String: String],
        Set<String>
    ) throws -> OpenedTerminalSession

    @ObservationIgnored
    private let terminalSessionOpener: TerminalSessionOpener?

    /// The socket directory, and the socket names to limit the run to (nil
    /// for every socket).
    typealias ZmxMigrationRunner = @Sendable (URL, Set<String>?) -> ZmxPreFreezeMigration.Result

    /// Stops pre-freeze zmx daemons in the given socket directory. nil runs
    /// `ZmxPreFreezeMigration.run(directory:names:)` when zmx is available
    /// outside a test host; tests inject a runner instead.
    @ObservationIgnored
    var zmxMigrationRunner: ZmxMigrationRunner?
    /// Whether a zmx socket path still exists. A re-run that neither
    /// restarted a session nor finds its socket gone leaves it blocked;
    /// tests override it alongside `zmxMigrationRunner`.
    @ObservationIgnored
    var zmxSocketExists: @Sendable (URL) -> Bool = { url in
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }
    /// The wire of the bundled zmx. The migration runs only once it is v1;
    /// tests override it to exercise either side of the zmx bump.
    @ObservationIgnored
    var bundledZmxWire: ZmxIPC.Wire = ZmxIPC.bundledWire
    /// The once-per-instance pre-freeze migration. Started by the first
    /// `awaitZmxMigration()` call; every restore of a persisted session and
    /// every orphan sweep awaits it.
    @ObservationIgnored
    private var zmxMigration: Task<Void, Never>?
    /// zmx session names the migration left pre-freeze, or could not rule
    /// out: in use by another client, not stoppable, or not answering the
    /// probe. Restores never attach them, because the bundled zmx shows a
    /// stuck terminal on a pre-freeze daemon.
    @ObservationIgnored
    private var zmxSessionsLeftPreFreeze: Set<String> = []
    /// The subset a restore has already skipped, and warned about, once.
    /// Restoring one again re-runs the migration for it first.
    @ObservationIgnored
    private var zmxSessionsSkippedPreFreeze: Set<String> = []
    /// The latest single-session re-run; the next one waits for it, so two
    /// runs never stop the same daemon at once.
    @ObservationIgnored
    private var zmxMigrationRetry: Task<Void, Never>?
    @ObservationIgnored
    private let closeTabConfirmer: CloseTabConfirmer?
    @ObservationIgnored
    private let acpDetachRunner: ACPDetachRunner?
    @ObservationIgnored
    private let remoteAccelerationPreparer: RemoteAccelerationPreparer?
    typealias WorktreeStatusScan = @Sendable ([URL]) async -> Void

    @ObservationIgnored
    private let worktreeStatusScan: WorktreeStatusScan

    private struct PendingACPDetach {
        let id: UUID
        let task: Task<Void, Never>
    }

    @ObservationIgnored
    private var pendingACPDetachTasks: [String: [ACPSession.ID: PendingACPDetach]] = [:]
    @ObservationIgnored
    private var retainedACPSessionCleanupTasks: [String: [ACPSession.ID: PendingACPDetach]] = [:]
    @ObservationIgnored
    /// Keyed by project as well as worktree id: two projects can hold
    /// reconciled `.createFailed` rows at the same path, and both completions
    /// must run.
    private var reconciledCreateFailureCompletionClaims: Set<WorktreeOperationKey> = []
#if DEBUG
    var pendingACPDetachCountForTesting: Int {
        pendingACPDetachTasks.values.reduce(0) { $0 + $1.count }
    }

    var retainedACPSessionCleanupCountForTesting: Int {
        retainedACPSessionCleanupTasks.values.reduce(0) { $0 + $1.count }
    }

    func retainedACPSessionCleanupDelayForTesting(
        manager: ACPSessionManager,
        sessionId: ACPSession.ID,
        retainActivePrompt: Bool = false
    ) -> Duration? {
        retainedScheduledSessionCleanupDelay(
            manager: manager,
            sessionId: sessionId,
            retainActivePrompt: retainActivePrompt
        )
    }
#endif
    @ObservationIgnored
    private var acpAuthTerminalExitHandlers: [
        String: (acpSessionId: ACPSession.ID, onExit: () -> Void)
    ] = [:]
    @ObservationIgnored
    private var attemptedRemoteHelperHosts: Set<String> = []
    @ObservationIgnored
    private var attemptedRemoteZmxHosts: Set<String> = []
    @ObservationIgnored
    private var remoteAccelerationProbeFailures: [String: Date] = [:]
    @ObservationIgnored
    private var remoteAccelerationTasks: [String: Task<Void, Never>] = [:]
    private let remoteAccelerationProbeRetryDelay: TimeInterval = 30
    var runScriptCatalogGeneration = 0
    @ObservationIgnored
    private let automaticCheckpointService = WorktreeCheckpointService()
    let rightPaneStore = RightPaneStore()
    var harness: HarnessService { core.harness }
    /// Settle window before a harness awaiting/permission transition reaches
    /// the attention store, so flapping states never flash the sidebar badge.
    @ObservationIgnored
    let harnessAttentionSettleInterval: TimeInterval
    @ObservationIgnored
    var harnessAttentionDebouncers: [String: DebounceTimer] = [:]
    @ObservationIgnored
    var pendingHarnessAttention: [String: HarnessActivityTransition] = [:]
    /// Pre-acknowledgments recorded while a session's awaiting transition
    /// was parked in the settle window, keyed by the fingerprint the user
    /// actually saw; the matching transition must land pre-acknowledged.
    @ObservationIgnored
    var harnessAttentionPreAcknowledgedSessions: [String: String] = [:]
    let mcpRegistrationRegistry = MCPRegistrationRegistry()
    let mcpHTTPSupervisor = AlasMCPHTTPSupervisor(
        state: BuiltInMCPSessionState(directory: Paths.builtInMCPSessionStateDir)
    )
    /// Shared by the HTTP supervisor and every session manager: the
    /// supervisor's remembered endpoints are what adopted agents connect to.
    var builtInMCPSessionState: BuiltInMCPSessionState { mcpHTTPSupervisor.state }
    let acpAdapterUpdateStore = ACPAdapterUpdateStore()
    let acpAdapterInstallCoordinator = ACPAdapterInstallCoordinator()

    // MARK: Remote control
    /// Paired-device registry backed by an on-disk JSON store. Lazy so the
    /// file isn't touched unless the remote feature is actually exercised.
    @ObservationIgnored
    private(set) lazy var remotePairing = RemotePairingService(store: FileDeviceStore())
    /// This Mac's peer identity key. Lazy like the rest: the key is only
    /// generated the first time federation actually needs to prove who this
    /// Mac is, so a launch that never touches remote control never creates
    /// one.
    @ObservationIgnored
    private(set) lazy var remoteIdentityKey = RemoteIdentityKeyProvider()
    @ObservationIgnored lazy var remotePairingApprovals = makePairingApprovalCoordinator()
    var nearbyApprovalState: NearbyApprovalState = .idle
    @ObservationIgnored var nearbyApprovalClient: RemotePairingApprovalClient?
    @ObservationIgnored var nearbyApprovalTask: Task<Void, Never>?
    @ObservationIgnored var nearbyApprovalGeneration = UUID()
    @ObservationIgnored var approvalExpiryTask: Task<Void, Never>?
    @ObservationIgnored var pairingApprovalsStopped = false
    @ObservationIgnored var remoteApprovalSignerProvider: (() -> any ApprovalSigning)?
    @ObservationIgnored var remoteApprovalResolver: ((RemoteDiscoveredInstance) async -> Result<RemoteDiscoveredInstanceResolver.ResolvedPeer, RemoteDiscoveredInstanceResolver.Failure>)?
    @ObservationIgnored var remoteApprovalClientFactory: ((any ApprovalSigning) -> RemotePairingApprovalClient)?
    /// Outbound peers (other Macs running Alas). Lazy like `remotePairing`.
    @ObservationIgnored
    private(set) lazy var remotePeers: RemotePeerManager = {
        let manager = RemotePeerManager(
            store: FilePeerStore(),
            pairing: remotePairing,
            localIdentity: { [weak self] in
                RemotePeerManager.LocalIdentity(
                    serverId: self?.config.remote.serverId ?? "",
                    name: self?.remoteDisplayName ?? "Alas",
                    // Loopback is meaningless to another Mac; everything else is
                    // in rank order, best first. Capped to the same bound the
                    // receiving Mac enforces on any advertisement — sending
                    // more than that would have it reject a genuine peer with
                    // `originRejected`, since it can never tell "too many
                    // legitimate addresses" apart from a hostile advertisement.
                    origins: Array(self?.remoteAdvertisedAddresses.filter { $0.kind != .localhost }.map(\.url).prefix(RemotePairingLink.maxOrigins) ?? []),
                    // Advertised so a peer can pin this Mac, and proved on
                    // every later socket by the same key.
                    publicKey: self?.remoteIdentityKey.publicKey ?? "")
            })
        manager.onRevokeDevice = { [weak self] deviceId in
            self?.remoteServer?.disconnectDevice(deviceId)
        }
        return manager
    }()
    /// Nearby Alas instances. Lazy like `remotePeers`; started and stopped by
    /// the Peers section while it is on screen, never app-wide.
    @ObservationIgnored
    private(set) lazy var remotePeerBrowser = RemotePeerBrowser(localServerId: { [weak self] in
        self?.config.remote.serverId ?? ""
    })
    /// Peer-session routing for this Mac's own remote clients. Lazy like
    /// `remotePeers`, which it forces: only built once a server exists.
    @ObservationIgnored
    private(set) lazy var remoteFederation: FederatedSessionsProvider = {
        let federation = FederatedSessionsProvider(links: remotePeers)
        // Connected clients learn about a peer coming or going through a
        // refreshed `hello` (its `peers` list, Task 8).
        federation.onPeerAvailabilityChanged = { [weak self] in
            self?.remoteServer?.broadcastHello()
            self?.nativePeerSessions?.refresh()
        }
        return federation
    }()
    /// Native sidebar consumer, present only while Remote runs.
    private(set) var nativePeerSessions: NativePeerSessions?

    #if DEBUG
    func installNativePeerSessionsForTesting(_ client: NativePeerSessions) {
        nativePeerSessions = client
    }
    #endif
    /// The live server, or nil when remote control is disabled. Mutated only
    /// by `syncRemoteServer()`.
    @ObservationIgnored
    private(set) var remoteServer: RemoteServer?
    /// Built on first peer console request; see `AppState+PeerConsoles`.
    /// Observable so a pane drawn before it existed still shows peer control.
    var _peerConsoleHost: PeerConsoleHost?
    /// Last queued remote tab action per session id; see `serializedSessionTabAction`.
    /// Stands in for the terminal registry in tests that route CLI commands
    /// from a terminal session without building one.
    @ObservationIgnored var terminalSessionOwnerOverride: ((String) -> SessionOwnerID?)?
    @ObservationIgnored var remoteSessionTabActionTails: [String: (token: UUID, done: Task<Void, Never>)] = [:]
    @ObservationIgnored private let remoteKeepAwake = RemoteKeepAwakeController()
    /// Last bind/start failure, surfaced by the Settings pane. Nil when the
    /// server is running or intentionally stopped. Observable so the pane
    /// reacts when a bind fails.
    private(set) var lastRemoteError: String?
    /// The server's bound port once the listener is ready, else nil. Observable
    /// so the pane reveals the address/QR as soon as the server comes up (the
    /// listener binds asynchronously, so the value arrives after `start`).
    private(set) var remotePort: UInt16?
    private(set) var remoteAdvertisedAddresses: [RemoteAdvertisedAddress] = []
    /// This Mac's tailnet identity; nil when Tailscale isn't installed or running.
    private(set) var remoteTailscale: RemoteTailscaleStatus?
    private(set) var remoteTailscaleServe: RemoteTailscaleServeState = .off
    /// Last failed `tailscale serve` command, surfaced by the Settings pane.
    private(set) var remoteTailscaleError: String?
    @ObservationIgnored private var remoteTailscaleSync: Task<Void, Never>?
    @ObservationIgnored private var remoteTailscaleServeProcess: RemoteTailscaleServeProcess?
    private(set) var remoteConnectedDeviceCountsSnapshot: [String: Int] = [:]

    private func makeRemoteInterfaces() -> [RemoteNetworkInterface] {
        RemoteNetwork.interfaces()
    }

    private func makeRemoteAdvertisedAddresses(
        port: UInt16?,
        interfaces: [RemoteNetworkInterface]
    ) -> [RemoteAdvertisedAddress] {
        config.remote.advertisedAddresses(
            port: port,
            interfaces: interfaces,
            tailnetHTTPSHost: port.flatMap { remoteTailscaleServe == .serving(port: $0) ? remoteTailscale?.dnsName : nil }
        )
    }

    private func makeRemoteAdvertisedAddresses(port: UInt16?) -> [RemoteAdvertisedAddress] {
        makeRemoteAdvertisedAddresses(port: port, interfaces: makeRemoteInterfaces())
    }

    private func makeRemoteAccessPolicy(interfaces: [RemoteNetworkInterface]) -> RemoteAccessPolicy {
        config.remote.accessPolicy(interfaces: interfaces, tailnetDNSName: remoteTailscale?.dnsName)
    }

    private func makeRemoteAccessPolicy() -> RemoteAccessPolicy {
        makeRemoteAccessPolicy(interfaces: makeRemoteInterfaces())
    }

    private func makeRemoteOriginPolicy(interfaces: [RemoteNetworkInterface]) -> RemoteOriginPolicy {
        config.remote.originPolicy(interfaces: interfaces, tailnetDNSName: remoteTailscale?.dnsName)
    }

    private func makeRemoteOriginPolicy() -> RemoteOriginPolicy {
        makeRemoteOriginPolicy(interfaces: makeRemoteInterfaces())
    }

    /// Name advertised to remote clients: the configured display name, else
    /// the computer name.
    var remoteDisplayName: String { config.remote.resolvedDisplayName }

    func remoteServerIdentity() -> RemoteServerIdentity {
        RemoteServerIdentity(
            serverId: config.remote.serverId,
            name: remoteDisplayName,
            // Only reach for the lazy manager when a server is up, for the
            // same reason `syncRemotePeers` does.
            peers: remoteServer != nil ? remotePeers.helloPeers : []
        )
    }

    /// What this Mac registers with Bonjour, or nil when it must not be
    /// discoverable.
    private func remoteBonjourAdvertisement() -> RemoteBonjourAdvertisement? {
        RemoteBonjourAdvertisement.forSettings(
            config.remote,
            displayName: remoteDisplayName,
            model: RemoteBonjourService.hardwareModel())
    }

    /// Re-registers the Bonjour advertisement after the discoverable toggle
    /// or the display name changes, and drops the browsed list when
    /// discovery turns off so no stale rows outlive the toggle.
    func syncRemoteDiscovery() {
        syncRemotePeers()
        if !config.remote.discoverable, remoteServer != nil {
            remotePeerBrowser.stop()
        }
    }

    func refreshRemoteAccessState() {
        let interfaces = makeRemoteInterfaces()
        remoteAdvertisedAddresses = makeRemoteAdvertisedAddresses(port: remotePort, interfaces: interfaces)
        remoteServer?.updateAccessPolicy(makeRemoteAccessPolicy(interfaces: interfaces))
        remoteServer?.updateOriginPolicy(makeRemoteOriginPolicy(interfaces: interfaces))
        syncPairingApprovalState()
    }

    func remoteConnectedDeviceCounts() -> [String: Int] {
        remoteConnectedDeviceCountsSnapshot
    }

    func revokeAllRemoteDevices() {
        let ids = remotePairing.devices.map(\.id)
        remotePairing.revokeAll()
        for id in ids {
            remoteServer?.disconnectDevice(id)
        }
    }

    /// Starts or stops the remote server to match `config.remote`. Idempotent;
    /// call at launch and after toggling the config. A bind failure is captured
    /// in `lastRemoteError` rather than thrown — the app must not crash because
    /// a port is busy.
    func syncRemoteServer() {
        defer {
            syncPairingApprovalState()
            syncRemoteKeepAwake()
        }
        if config.remote.enabled {
            if config.remote.ensureServerId() { saveConfig() }
            if let server = remoteServer, server.loopbackOnly != config.remote.listensOnLoopbackOnly {
                // Rebinding needs a fresh listener; existing sockets drop and reconnect.
                try? server.start(port: config.remote.preferredPort, loopbackOnly: config.remote.listensOnLoopbackOnly)
            }
            guard remoteServer == nil else {
                syncRemoteTailscale()
                refreshRemoteAccessState()
                syncRemotePeers()
                return
            }
            let root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("RemoteWeb")
            let assets = RemoteWebAssets(root: root)
            let server = RemoteServer(
                pairing: remotePairing,
                assets: assets,
                host: host,
                accessPolicy: makeRemoteAccessPolicy(),
                originPolicy: makeRemoteOriginPolicy(),
                diagnostics: { [weak self] port in
                    RemoteDiagnosticsSnapshot(
                        appName: "Alas",
                        port: port,
                        addresses: self?.remoteAdvertisedAddresses ?? [],
                        usesPlainHTTP: true,
                        pairedDeviceCount: self?.remotePairing.devices.count ?? 0,
                        serverId: self?.config.remote.serverId,
                        name: self?.remoteDisplayName
                    )
                },
                identity: { [weak self] in
                    self?.remoteServerIdentity() ?? RemoteServerIdentity(serverId: "", name: "Alas")
                },
                signer: remoteIdentityKey
            )
            server.onPortChange = { [weak self] p in
                self?.remotePort = p
                self?.refreshRemoteAccessState()
                self?.syncRemoteKeepAwake()
                self?.syncRemoteTailscale()
            }
            server.onConnectionDeviceCountsChange = { [weak self] counts in
                self?.remoteConnectedDeviceCountsSnapshot = counts
            }
            server.onPeerPaired = { [weak self] request in
                // Recorded synchronously, on the same call stack as the
                // redeem that produced this request — before Task-spawning
                // below introduces a delay a concurrent Forget could land
                // in unnoticed by handleInboundPeer's own, later snapshot.
                self?.remotePeers.notePeerPairingArrived(serverId: request.peerServerId, localDeviceId: request.localDeviceId)
                Task { @MainActor in await self?.remotePeers.handleInboundPeer(request) }
            }
            configurePairingApprovals(server: server)
            server.federation = remoteFederation
            server.presenter = self
            do {
                try server.start(port: config.remote.preferredPort, loopbackOnly: config.remote.listensOnLoopbackOnly)
                remoteServer = server
                lastRemoteError = nil
                syncRemotePeers()
            } catch {
                remoteServer = nil
                remotePort = nil
                remoteAdvertisedAddresses = []
                remoteConnectedDeviceCountsSnapshot = [:]
                lastRemoteError = error.localizedDescription
            }
        } else {
            syncPairingApprovalState()
            // Only touch `remotePeers` when a server actually ran: the lazy
            // property builds the manager, which builds `remotePairing` too,
            // so an unconditional call would read `remote-peers.json` and
            // `remote-devices.json` on every launch with both flags off.
            // Links only exist while the server is up, so there is nothing to
            // tear down otherwise. Safe here because the nil-out is below.
            nativePeerSessions?.stop()
            nativePeerSessions = nil
            if remoteServer != nil { remotePeers.disconnectAll() }
            remoteServer?.stop()
            remoteServer = nil
            _peerConsoleHost?.shutdown()
            remotePort = nil
            remoteAdvertisedAddresses = []
            remoteConnectedDeviceCountsSnapshot = [:]
            lastRemoteError = nil
            syncRemoteTailscale()
        }
    }

    /// Refreshes Tailscale status, then starts or stops our foreground
    /// `tailscale serve` to match `config.remote`.
    func syncRemoteTailscale() {
        // Nothing to trust or serve: skip spawning the CLI entirely.
        guard config.remote.enabled || config.remote.tailscaleServe else {
            remoteTailscaleSync?.cancel()
            remoteTailscale = nil
            applyRemoteTailscaleServe()
            return
        }
        remoteTailscaleSync?.cancel()
        remoteTailscaleSync = Task { @MainActor [weak self] in
            var failure: String?
            var status = self?.remoteTailscale
            do {
                status = try await RemoteTailscale.status()
            } catch ProcessError.nonZeroExit(_, let stderr) {
                // A failed read keeps the last known status (and MagicDNS trust).
                failure = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                failure = "\(error)"
            }
            guard let self, !Task.isCancelled else { return }
            remoteTailscale = status
            remoteTailscaleError = failure
            applyRemoteTailscaleServe()
        }
    }

    /// Synchronous on the main actor, so starts and stops can't interleave.
    private func applyRemoteTailscaleServe() {
        let remote = config.remote
        let want = remote.enabled && remote.tailscaleServe && remoteTailscale?.httpsEnabled == true
        let current = remoteTailscaleServeProcess
        if want, let port = remotePort {
            guard current?.port != port || current?.isRunning != true else { return }
            // A failure stays shown until settings change, instead of retrying
            // a doomed `serve` on every refresh.
            if case .failed = remoteTailscaleServe, current?.port == port { return }
            current?.stop()
            remoteTailscaleServeProcess = nil
            guard let executable = RemoteTailscale.executable() else { return }
            do {
                weak var started: RemoteTailscaleServeProcess?
                started = try RemoteTailscaleServeProcess(executable: executable, port: port) { [weak self] reason in
                    guard let self, let started, remoteTailscaleServeProcess === started else { return }
                    remoteTailscaleServe = .failed(reason)
                    refreshRemoteAccessState()
                }
                remoteTailscaleServeProcess = started
                remoteTailscaleServe = .serving(port: port)
            } catch {
                remoteTailscaleServe = .failed("\(error)")
            }
        } else {
            current?.stop()
            remoteTailscaleServeProcess = nil
            remoteTailscaleServe = .off
        }
        refreshRemoteAccessState()
    }

    /// Stops serving on quit. The wrapper would notice Alas exiting within a
    /// second anyway; this just makes it immediate.
    func stopRemoteTailscaleServe() {
        remoteTailscaleServeProcess?.stop()
        remoteTailscaleServeProcess = nil
    }

    func syncRemoteKeepAwake() {
        remoteKeepAwake.update(
            enabled: config.remote.keepAwake,
            serverRunning: config.remote.enabled && remoteServer != nil && remotePort != nil
        )
    }

    /// Keeps peer links alive only while the server is up; peers stay stored
    /// either way. The Bonjour advertisement follows the same lifecycle,
    /// gated further by `discoverable`.
    func syncRemotePeers() {
        syncPairingApprovalState()
        if config.remote.enabled, remoteServer != nil {
            remotePeers.connectAll()
            if nativePeerSessions == nil {
                let client = NativePeerSessions(
                    federation: remoteFederation,
                    peers: { [weak self] in self?.remotePeers.helloPeers ?? [] },
                    comparisonMode: { [weak self] in self?.config.changes.comparisonMode },
                    consoles: makeNativePeerConsoles(),
                    hosts: makeNativePeerHosts(),
                    supportsRepoHookApproval: { [weak self] serverId in
                        self?.remotePeers.capabilities[serverId]?
                            .contains(HostProtocolCapability.repoHooksApprovalV1) == true
                    },
                    decideRepoHook: { [weak self] serverId, hook, context in
                        await self?.decidePeerRepoHook(serverId: serverId, hook: hook, context: context) ?? .cancel
                    }
                )
                nativePeerSessions = client
                client.start()
            } else {
                nativePeerSessions?.refresh()
            }
        }
        remoteServer?.advertise(remoteBonjourAdvertisement())
    }

    /// Revokes a paired device and immediately drops any live connection(s) it
    /// holds, so an already-connected phone stops streaming at once rather than
    /// when its socket happens to close.
    func revokeRemoteDevice(_ deviceId: String) {
        remotePairing.revoke(deviceId: deviceId)
        remoteServer?.disconnectDevice(deviceId)
    }
    @ObservationIgnored
    private var lspManager: WorkspaceLSPManager?
    @ObservationIgnored
    private var languageServerConfigChangeTracker: LanguageServerConfigChangeTracker
    @ObservationIgnored lazy var updates = UpdateController(
        isEnabled: { [weak self] in self?.config.general.autoUpdate ?? true }
    )
    @ObservationIgnored lazy var whatsNew = WhatsNewController()

    var isSearchOpen: Bool = false
    var isRepoSelectorOpen: Bool = false
    var isAgentLauncherOpen: Bool = false
    var isReviewPaletteOpen: Bool = false
    var isRunScriptPaletteOpen: Bool = false
    var pendingRunScriptCreation: RunScriptCreationPresentation?
    var pendingFollowStackEntry: GGFollowEntryPresentation?
    var isKeyboardOverlayOpen: Bool {
        isSearchOpen || isRepoSelectorOpen || isAgentLauncherOpen || isReviewPaletteOpen || isRunScriptPaletteOpen
    }
    let repoSelector = RepoSelectorModel()
    let agentLauncher = AgentLauncherModel()
    let reviewPalette = ReviewTargetPaletteModel()
    let runScriptPalette = RunScriptPaletteModel()

    func openSearchOverlay() {
        reviewPalette.close()
        isReviewPaletteOpen = false
        repoSelector.close()
        isRepoSelectorOpen = false
        agentLauncher.reset()
        isAgentLauncherOpen = false
        runScriptPalette.reset()
        isRunScriptPaletteOpen = false
        search.open()
        isSearchOpen = true
    }

    func toggleRepoSelectorOverlay() {
        reviewPalette.close()
        isReviewPaletteOpen = false
        agentLauncher.reset()
        isAgentLauncherOpen = false
        runScriptPalette.reset()
        isRunScriptPaletteOpen = false

        if isRepoSelectorOpen {
            repoSelector.close()
            isRepoSelectorOpen = false
        } else {
            search.close()
            isSearchOpen = false
            isRepoSelectorOpen = true
        }
    }

    func openAgentLauncherOverlay(_ request: AgentLauncherRequest) {
        openAgentLauncherOverlay(mode: request.mode, locked: request.isLocked)
    }

    func openAgentLauncherOverlay(mode: AppConfig.LauncherMode? = nil, locked: Bool = false) {
        reviewPalette.close()
        isReviewPaletteOpen = false
        search.close()
        isSearchOpen = false
        repoSelector.close()
        isRepoSelectorOpen = false
        runScriptPalette.reset()
        isRunScriptPaletteOpen = false
        agentLauncher.prepareForOpen(
            defaultMode: mode ?? config.agents.defaultLauncherMode,
            locked: locked
        )
        isAgentLauncherOpen = true
    }

    func openRunScriptPaletteOverlay(mode: RunScriptPaletteModel.Mode = .run) {
        guard !isRunScriptPaletteOpen else { return }
        reviewPalette.close()
        isReviewPaletteOpen = false
        search.close()
        isSearchOpen = false
        repoSelector.close()
        isRepoSelectorOpen = false
        agentLauncher.reset()
        isAgentLauncherOpen = false
        runScriptPalette.prepareForOpen(mode: mode)
        isRunScriptPaletteOpen = true
    }

    /// Computed each time `config.agents` changes or detection re-runs.
    /// `RootView.task` calls `rescanAgents()` once at launch; the Settings
    /// window calls it again on appear.
    var agentRegistry: AgentRegistry = AgentRegistry(
        builtinState: [:],
        customs: [],
        installedIds: []
    )
    let agentAvailabilityStore = AgentAvailabilityStore()

    /// Resolve a single agent by id (built-in id or custom UUID). Nil for
    /// unknown ids or "none".
    func agent(id: String?) -> AgentDefinition? {
        guard let id, id != "none" else { return nil }
        return agentRegistry.agents.first(where: { $0.id == id })
    }

    /// The agent a handoff opens for `id` (an agent id or Automatic) on this
    /// worktree's host; nil when AI is disabled or the agent is unavailable.
    /// Handoffs open ACP chats, so only agents with an ACP launch spec qualify.
    func availableAgentForHandoff(id: String?, worktree: Worktree) -> AgentDefinition? {
        RepositoryAgentSelectionPolicy.selection(
            selectedID: id,
            availability: agentAvailability(for: worktree),
            where: Self.canOpenACPChat
        ).agent
    }

    func availableAgentForHandoff(id: String?, checkout: WorkspaceCheckout) -> AgentDefinition? {
        RepositoryAgentSelectionPolicy.selection(
            selectedID: id,
            availability: agentAvailability(
                worktreePath: URL(fileURLWithPath: checkout.rootPath),
                executionTarget: checkout.executionLocation.agentExecutionTarget
            ),
            where: Self.canOpenACPChat
        ).agent
    }

    private nonisolated static func canOpenACPChat(_ agent: AgentDefinition) -> Bool {
        ACPLaunchCatalog.spec(for: agent.id) != nil
    }

    func loadAgentAvailabilityForDelegation(_ worktree: Worktree) async -> AgentAvailabilityState {
        await loadAgentAvailability(for: worktree, retryFailed: true)
        return agentAvailability(for: worktree)
    }

    func acpForkTargets(sourceAgentID: String, worktreePath: URL) -> [ACPSessionForkTarget] {
        ACPForkTargetPolicy.targets(
            sourceAgentID: sourceAgentID,
            enabledAgents: agentAvailability(worktreePath: worktreePath).agents.map {
                ACPForkAgentOption(
                    id: $0.id,
                    displayName: $0.displayName,
                    logoAssetName: $0.builtinLogoAssetName
                )
            },
            catalogAgentIDs: ACPLaunchCatalog.specs.map(\.agentID)
        )
    }

    func acpForkTargets(
        sourceAgentID: String,
        worktreePath: URL,
        remoteHost: String?
    ) -> [ACPSessionForkTarget] {
        acpForkTargets(
            sourceAgentID: sourceAgentID,
            worktreePath: worktreePath,
            executionTarget: AgentExecutionTarget.resolve(worktreePath: worktreePath, remoteHost: remoteHost)
        )
    }

    func acpForkTargets(
        sourceAgentID: String,
        worktreePath: URL,
        executionTarget: AgentExecutionTarget
    ) -> [ACPSessionForkTarget] {
        ACPForkTargetPolicy.targets(
            sourceAgentID: sourceAgentID,
            enabledAgents: agentAvailability(worktreePath: worktreePath, executionTarget: executionTarget).agents.map {
                ACPForkAgentOption(
                    id: $0.id,
                    displayName: $0.displayName,
                    logoAssetName: $0.builtinLogoAssetName
                )
            },
            catalogAgentIDs: ACPLaunchCatalog.specs.map(\.agentID)
        )
    }

    func remoteHost(for worktree: Worktree) -> String? {
        projectAndWorktree(withWorktreeId: worktree.id)?.project.host
    }

    func workspaceCheckout(for owner: SessionOwnerID?) -> WorkspaceCheckout? {
        guard case .workspaceCheckout(let checkoutID, let location) = owner,
              let checkout = workspacesManager.checkout(id: checkoutID),
              checkout.executionLocation.normalized == location.normalized
        else { return nil }
        return checkout
    }

    /// Recompute `agentRegistry` from `config.agents` + a fresh detection
    /// scan. Safe to call repeatedly.
    func rescanAgents() {
        ACPLaunchCatalog.publishRegistryAgents(config.agents.registry)
        let registry = composeRegistryWithoutDetection()
        Task { @MainActor in
            let installedIds = await AgentDetector.scanCurrentEnvironment(
                agents: registry.agents
            )
            self.agentAvailabilityStore.invalidateAll()
            self.agentRegistry = AgentRegistry(
                builtinState: self.config.agents.builtinState,
                customs: self.config.agents.userAgents,
                installedIds: installedIds
            )
            self.snapInvalidatedAgentSelections()
        }
    }

    func agentAvailability(
        worktreePath: URL,
        remoteHost: String? = nil
    ) -> AgentAvailabilityState {
        let target = AgentExecutionTarget.resolve(worktreePath: worktreePath, remoteHost: remoteHost)
        return agentAvailability(worktreePath: worktreePath, executionTarget: target)
    }

    func agentAvailability(
        worktreePath: URL,
        executionTarget target: AgentExecutionTarget
    ) -> AgentAvailabilityState {
        return agentAvailabilityStore.state(
            target: target,
            worktreePath: worktreePath.path,
            localAgents: agentRegistry.enabled()
        )
    }

    func agentAvailability(for worktree: Worktree) -> AgentAvailabilityState {
        agentAvailability(
            worktreePath: worktree.path,
            remoteHost: projectAndWorktree(withWorktreeId: worktree.id)?.project.host
        )
    }

    func agentExecutionTarget(for worktree: Worktree) -> AgentExecutionTarget {
        AgentExecutionTarget.resolve(
            worktreePath: worktree.path,
            remoteHost: projectAndWorktree(withWorktreeId: worktree.id)?.project.host
        )
    }

    func loadAgentAvailability(for worktree: Worktree, force: Bool = false, retryFailed: Bool = false) async {
        await loadAgentAvailability(
            worktreePath: worktree.path,
            remoteHost: projectAndWorktree(withWorktreeId: worktree.id)?.project.host,
            force: force,
            retryFailed: retryFailed
        )
    }

    func agentAvailabilityGeneration(
        worktreePath: URL,
        remoteHost: String? = nil
    ) -> Int {
        let target = AgentExecutionTarget.resolve(worktreePath: worktreePath, remoteHost: remoteHost)
        return agentAvailabilityGeneration(worktreePath: worktreePath, executionTarget: target)
    }

    func agentAvailabilityGeneration(
        worktreePath _: URL,
        executionTarget target: AgentExecutionTarget
    ) -> Int {
        guard case .ssh = target else { return 0 }
        return agentAvailabilityStore.generation
    }

    func agentAvailabilityGeneration(for worktree: Worktree) -> Int {
        agentAvailabilityGeneration(
            worktreePath: worktree.path,
            remoteHost: projectAndWorktree(withWorktreeId: worktree.id)?.project.host
        )
    }

    func loadAgentAvailability(
        worktreePath: URL,
        remoteHost: String? = nil,
        force: Bool = false,
        retryFailed: Bool = false
    ) async {
        let target = AgentExecutionTarget.resolve(worktreePath: worktreePath, remoteHost: remoteHost)
        await loadAgentAvailability(
            worktreePath: worktreePath,
            executionTarget: target,
            force: force,
            retryFailed: retryFailed
        )
    }

    func loadAgentAvailability(
        worktreePath: URL,
        executionTarget target: AgentExecutionTarget,
        force: Bool = false,
        retryFailed: Bool = false
    ) async {
        guard case .ssh = target else { return }
        let candidates = AgentConfiguredCatalog.enabled(
            builtinState: config.agents.builtinState,
            customs: config.agents.userAgents
        ).filter(\.canRunOnRemoteHost)
        if force {
            agentAvailabilityStore.invalidate(target: target, worktreePath: worktreePath.path)
        }
        if retryFailed {
            await agentAvailabilityStore.loadRetryingFailure(
                target: target,
                worktreePath: worktreePath.path,
                candidates: candidates
            )
        } else {
            await agentAvailabilityStore.load(
                target: target,
                worktreePath: worktreePath.path,
                candidates: candidates
            )
        }
    }

    /// Build a registry view without running detection — used as the input
    /// to detection (since the detector needs the merged agent list).
    private func composeRegistryWithoutDetection() -> AgentRegistry {
        AgentRegistry(
            builtinState: config.agents.builtinState,
            customs: config.agents.userAgents,
            installedIds: []
        )
    }

    /// When an enabled agent becomes disabled / uninstalled / deleted, snap
    /// any selector pointing at it to a safe default:
    ///   - `changes.aiToolId` → Automatic
    ///   - `agents.worktreeAutoLaunch.agentId` → nil
    ///   - per-project `worktreeAgentMode` → `.useGlobal` if it referenced
    ///     a vanished agent
    private func snapInvalidatedAgentSelections() {
        let enabledIds = Set(AgentConfiguredCatalog.enabled(
            builtinState: config.agents.builtinState,
            customs: config.agents.userAgents
        ).map(\.id))
        var changed = false
        let currentTool = config.changes.aiToolId
        if currentTool != AppConfig.Changes.automaticAIToolID,
           currentTool != AppConfig.Changes.disabledAIToolID,
           !enabledIds.contains(currentTool) {
            config.changes.aiToolId = AppConfig.Changes.automaticAIToolID
            changed = true
        }
        if let autoLaunchId = config.agents.worktreeAutoLaunch.agentId,
           !enabledIds.contains(autoLaunchId) {
            config.agents.worktreeAutoLaunch.agentId = nil
            changed = true
        }
        if changed { saveConfig() }

        var projectsChanged = false
        for project in projectsManager.projects {
            // Match the same modes AgentAutoLaunch.resolve treats as
            // "use the project's agent" — both .overrideGlobal and
            // .appendToGlobal qualify.
            guard project.startupScripts.worktreeAgentMode == .overrideGlobal
                    || project.startupScripts.worktreeAgentMode == .appendToGlobal,
                  let id = project.startupScripts.worktreeAgentId,
                  !enabledIds.contains(id) else { continue }
            var updated = project.startupScripts
            updated.worktreeAgentMode = .useGlobal
            updated.worktreeAgentId = nil
            projectsManager.updateProject(
                id: project.id,
                update: ProjectUpdate(
                    name: project.name,
                    icon: project.icon,
                    startupScripts: updated
                )
            )
            projectsChanged = true
        }
        if projectsChanged { saveProjects() }
    }

    // MARK: - LSP installer

    let lspInstaller = LSPInstaller()

    // MARK: - Self updater

    let selfUpdater = SelfUpdater()
    var presentUpdateProgress = false
    /// Set when the user taps Update in the update sheet; the progress sheet
    /// is presented from the update sheet's `onDismiss` so the two sheets don't
    /// conflict while the first one is still animating out.
    var pendingSelfUpdate = false

    func runSelfUpdate() async {
        try? await selfUpdater.start(command: .homebrew)
        guard selfUpdater.state == .finished(exitCode: 0) else { return }
        // Read the plist directly: Bundle caches the running copy's info.
        let plist = Bundle.main.bundleURL.appending(path: "Contents/Info.plist")
        let onDisk = NSDictionary(contentsOf: plist) as? [String: Any]
        updates.recordInstall(onDisk: BuildIdentity(infoDictionary: onDisk))
    }

    private(set) var installerHost: InstallerHost = .detect()

    /// Re-detect installers after an install completes so that, e.g., installing
    /// `cargo` and then a cargo-based LSP works without app restart.
    func refreshInstallerHost() {
        installerHost = .detect()
    }

    static let forceDeleteAlertTitleSuffix = "requires force delete."
    static let forceDeleteAlertMessage = "Git refused to remove this worktree — it may have uncommitted changes or be locked. Force delete will remove it and discard any uncommitted work."

    private static let checkpointRecoveryBlocksWorktreeRemovalMessage = WorktreeRemovalResult.checkpointRecoveryMessage
    static let checkpointRecoveryBlocksACPMessage = SessionsAPI.checkpointRecoveryBlocksStartMessage

    /// Set when a worktree deletion stops because the tree is dirty and Git
    /// needs `--force`. The UI presents a confirmation dialog; confirming
    /// retries with force.
    struct PendingForceDeleteWorktree: Identifiable, Equatable {
        let id: String           // worktree id
        let branch: String
        let projectId: String
        let repoPath: URL        // git root (project.path)
        let worktreePath: URL    // actual worktree path
        let deleteBranchIfMerged: Bool
        let removedIndex: Int
        /// The deletion's claim, held as `.preparingDelete` while the prompt is up.
        let claim: UUID
        var acknowledgedDirtyTabs: [TabID: Int] = [:]
    }
    var pendingForceDeleteWorktree: PendingForceDeleteWorktree?

    struct WorktreeDeleteConfirmation: Equatable {
        let title: String
        let message: String
    }

    @ObservationIgnored
    lazy var search: SearchModel = SearchModel(environment: makeSearchEnvironment())
    @ObservationIgnored
    let fileIndex = FileIndex()
    @ObservationIgnored
    let symbolIndex = WorktreeSymbolIndex()
    @ObservationIgnored
    private let statusCache = GitStatusCache()
    @ObservationIgnored
    private var workspaceLoadTask: Task<Void, Never>?

    var lsp: WorkspaceLSPManager {
        if let lspManager { return lspManager }
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: config.code.languageServers))
        lspManager = manager
        return manager
    }

    @ObservationIgnored
    private let store: any PersistenceStoreProtocol
    @ObservationIgnored
    private var restoreActiveTabsOnNextReload: Bool
    @ObservationIgnored
    private let persistenceErrorHandler: (String, String) -> Void
    @ObservationIgnored
    private let fileActionErrorHandler: (String, String) -> Void
    @ObservationIgnored
    @ObservationIgnored
    private var scheduledSpacesSave: Task<Void, Never>?

    /// One FSEvents watcher per project, watching `<repo>/.git` to auto-refresh
    /// the sidebar when branches flip or worktrees appear/disappear externally.
    @ObservationIgnored
    private var projectGitWatchers: [String: ProjectGitWatcher] = [:]
    @ObservationIgnored
    private var remoteProjectWatchers: [String: RemoteProjectGitWatcher] = [:]
    @ObservationIgnored
    private var worktreeUpstreamStatusRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private let projectGitWatcherFactory: @MainActor (URL) -> ProjectGitWatcher
    @ObservationIgnored
    private let ggStackCache: GGStackCache
    private(set) var revisionChangeGenerations: [String: Int] = [:]
    private(set) var reviewSessionRetargetGenerations: [String: Int] = [:]
    var followRevisionEditorRequest: FollowRevisionEditorRequest?
    private var followRevisionRequestGenerations: [String: Int] = [:]
    private var followRevisionEditorGeneration = 0

    init(
        store: any PersistenceStoreProtocol = PersistenceStore(),
        persistenceErrorHandler: ((String, String) -> Void)? = nil,
        fileActionErrorHandler: ((String, String) -> Void)? = nil,
        closeTabConfirmer: CloseTabConfirmer? = nil,
        terminalSessionOpener: TerminalSessionOpener? = nil,
        acpDetachRunner: ACPDetachRunner? = nil,
        remoteAccelerationPreparer: RemoteAccelerationPreparer? = nil,
        projectGitWatcherFactory: @escaping @MainActor (URL) -> ProjectGitWatcher = { ProjectGitWatcher(repoPath: $0) },
        ggStackCache: GGStackCache = .shared,
        runScriptCompletionWaiter: @escaping RunCompletionWaiter = { try await RunScriptCompletionMonitor.wait(for: $0) },
        runScriptLocalMonitorGrace: Duration = .seconds(2),
        runScriptMonitorGrace: Duration = .seconds(30),
        runHistoryStore: RunHistoryStore? = try? RunHistoryStore(),
        usageHistory: UsageHistoryStore? = try? UsageHistoryStore(),
        runScheduler: RunScheduler? = nil,
        acpModelCatalog: ACPAgentModelCatalog? = nil,
        tabsManager: TabsManager? = nil,
        lspManager: WorkspaceLSPManager? = nil,
        restoreActiveTabsOnStartup: Bool = true,
        workspaceSpacePersistenceBridge: WorkspaceSpacePersistenceBridge? = nil,
        workspacesManager: WorkspacesManager? = nil,
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        workspaceRemoteTransport: WorkspaceRemoteTransport = .init(),
        worktreeCleanupLauncher: @escaping WorktreeCleanupLauncher = {
            try WorktreeTrashCleaner.launch($0)
        },
        worktreeStatusScan: @escaping WorktreeStatusScan = { paths in
            await WorktreeStatusScanner.shared.scan(paths: paths)
        },
        attentionStore: AttentionStore? = nil,
        reviewDrafts: ReviewDraftCommentStore = ReviewDraftCommentStore(),
        attentionNavigationEnvironment: AttentionNavigationEnvironment? = nil,
        harnessAttentionSettleInterval: TimeInterval = 1.5,
        localTextModelStore: LocalTextModelStore? = nil,
        localTextReadModelState: (@Sendable () async -> LocalTextModelState)? = nil,
        localTextInference: (any LocalTextGenerating)? = nil,
        nextPromptInference: (any NextPromptRuntime)? = nil,
        localTextSupported: Bool = NextPromptInference.isSupported(),
        hostEnvironment: AppHostEnvironment = AppHostEnvironment()
    ) {
        // Legacy remote worktrees were renamed to virtual ids on decode. Move
        // their id-keyed state first: the attention store and run scheduler
        // below load their files, and tabs must be in place before
        // `reloadTabs` and the zmx orphan sweep, or live remote sessions look
        // orphaned. The test host shares the user's app support dir, so it
        // skips the files.
        var projectsFile = (try? store.readIfExists(ProjectsFile.self, from: Paths.projectsFile)) ?? ProjectsFile(projects: [])
        var config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? AppConfig.defaults
        var spacesFile = try? store.readIfExists(SpacesFile.self, from: Paths.spacesFile)
        // On any failure the pending maps stay and are saved with
        // projects.json whenever it is next written, so the next launch retries.
        let unitTestHost = Self.isRunningUnitTests
        RemotePathMigration.complete(
            projectsFile: &projectsFile,
            config: &config,
            spaces: &spacesFile,
            saving: unitTestHost ? nil : store,
            migrateStores: { unitTestHost ? false : RemotePathMigration.migrate(idMap: $0, defaults: AlasProfile.userDefaults) }
        )
        self.store = store
        let suggestionStore = localTextModelStore ?? LocalTextModelStore()
        self.localTextReadModelState = localTextReadModelState ?? { await suggestionStore.state }
        self.nextPromptInferenceOverride = nextPromptInference
        self.localTextSupported = localTextSupported
        self.workspaceRemoteTransport = workspaceRemoteTransport
        self.attentionNavigationEnvironment = attentionNavigationEnvironment
        self.harnessAttentionSettleInterval = harnessAttentionSettleInterval
        restoreActiveTabsOnNextReload = restoreActiveTabsOnStartup
        suppressesRestoredRightPaneAfterAbandonedStartup = !restoreActiveTabsOnStartup
        startupRecoveryNeedsMountedRightPaneRefresh = !restoreActiveTabsOnStartup
        _tabs = tabsManager
        self.lspManager = lspManager
        self.persistenceErrorHandler = persistenceErrorHandler ?? { title, message in
            AppState.showWarningAlert(title: title, message: message)
        }
        self.fileActionErrorHandler = fileActionErrorHandler ?? { title, message in
            AppState.showWarningAlert(title: title, message: message)
        }
        self.terminalSessionOpener = terminalSessionOpener
        self.closeTabConfirmer = closeTabConfirmer
        self.acpDetachRunner = acpDetachRunner
        self.remoteAccelerationPreparer = remoteAccelerationPreparer
        self.worktreeStatusScan = worktreeStatusScan
        self.projectGitWatcherFactory = projectGitWatcherFactory
        self.ggStackCache = ggStackCache
        self.acpModelCatalog = acpModelCatalog ?? ACPAgentModelCatalog(store: store)
        let workspaceBridge = workspaceSpacePersistenceBridge ?? WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore)
        self.workspacesManager = workspacesManager ?? WorkspacesManager(bridge: workspaceBridge)
        self.config = config
        self.languageServerConfigChangeTracker = LanguageServerConfigChangeTracker(
            initial: config.code.languageServers
        )
        // Publish the effective shortcut reservations so the terminal pane
        // can honor user overrides from the very first keystroke.
        ShortcutReservations.update(from: config)
        // Restored ACP sessions of registry agents attach before the first
        // agent rescan, so their launch specs must be known from the start.
        ACPLaunchCatalog.publishRegistryAgents(config.agents.registry)
        self.core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: projectsFile.projects),
            store: store,
            runHistoryStore: runHistoryStore,
            workspaceStore: workspaceStore,
            runScheduler: runScheduler,
            localTextModelStore: suggestionStore,
            localText: localTextInference,
            attentionStore: attentionStore,
            runCompletionWaiter: runScriptCompletionWaiter,
            environment: hostEnvironment,
            runHostGrace: RunHostGrace(local: runScriptLocalMonitorGrace, any: runScriptMonitorGrace),
            reviewDrafts: reviewDrafts,
            usageHistory: usageHistory
        )
        self.hostEnvironment = hostEnvironment
        self.host = AlasHost(core: core)
        let computerUseLink = AppStateLink()
        self.computerUse = Self.makeComputerUse(link: computerUseLink)
        let spacesManager = spacesFile.map(SpacesManager.init(file:))
            ?? SpacesManager.migrating(projects: projectsFile.projects)
        var spacesChanged = spacesManager.pruneMissingProjects(validProjectIds: Set(projectsFile.projects.map(\.id)))
        for project in projectsFile.projects where spacesManager.membershipCount(forProject: project.id) == 0 {
            spacesManager.addProject(project.id, toSpace: spacesManager.activeSpaceId)
            spacesChanged = true
        }
        if spacesChanged {
            _ = try? store.write(spacesManager.file, to: Paths.spacesFile)
        }
        self.spacesManager = spacesManager
        // Non-throwing on purpose: theme resources can be missing (partial
        // build, test host, corrupted install) and startup must never trap
        // in a `try!`. Falls back persisted id → bundled ids → fallback.
        let themeStore = ThemeStore.creating(initialId: config.themeId)
        // Apply the persisted accent override so the picker's selection
        // survives relaunches; otherwise launches always show the theme's
        // built-in accent until the user re-clicks the picker.
        themeStore.setAccent(config.accent)
        themeStore.setCodeTheme(family: config.code.codeThemeFamily)
        // Same for "Match system" — the toggle's state needs to drive the
        // current theme on launch, not just on subsequent toggle events.
        if config.matchSystemTheme {
            themeStore.setMatchSystem(true)
        }
        self.themeStore = themeStore
        Task { @MainActor [weak self] in
            await self?.loadWorkspaces()
        }
        // All stored properties are initialized; we can safely capture `self`.
        computerUseLink.state = self
        startComputerUseStatusItem()
        startComputerUseStopHotKey()
        // Wire the live default-ordering source so the manager reads the
        // current `config.worktrees.defaultOrdering` on every sort.
        self.projectsManager.setDefaultOrdering { [weak self] in
            self?.config.worktrees.defaultOrdering ?? .lastUpdateDesc
        }
        WindowAppearance.apply(darkMode: themeStore.current.darkMode)
        // Tabs can't be loaded here: worktrees haven't been refreshed yet (that
        // happens async in RootView.task), so worktreesByProject is empty and
        // we'd resolve to a 0-element id list. RootView calls reloadTabs() after
        // refreshAll() returns.
        rightPaneStore.appState = self
        rightPaneStore.reviewSnapshotDidChange = { [weak self] worktreeID, _, snapshot in
            guard let self else { return }
            let lookups = self.tabs.resolveCreatedReviewsOnRefresh(worktreeId: worktreeID, snapshot: snapshot)
            guard !lookups.isEmpty else { return }
            guard let reviewLoop = self.rightPaneStore.activeState(worktreeId: worktreeID)?.reviewLoop else { return }
            let generation = reviewLoop.refreshGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                for lookup in lookups {
                    guard let request = try? await reviewLoop.currentReviewRequest(
                        remote: lookup.remote, branch: lookup.branch,
                        headOwner: lookup.headOwner, baseBranch: lookup.baseBranch
                    ), request.url == lookup.createdURL
                    else { continue }
                    let checkedRequest = try? await reviewLoop.withChecks(request, remote: lookup.remote)
                    guard
                        let currentSnapshot = reviewLoop.settledSnapshot(forRefreshGeneration: generation)
                    else { continue }
                    let found = ReviewLoopSnapshot(
                        local: currentSnapshot.local, remote: lookup.remote,
                        reviewRequest: checkedRequest ?? request,
                        providerAvailable: currentSnapshot.providerAvailable,
                        providerAuthenticated: currentSnapshot.providerAuthenticated,
                        providerCapabilities: currentSnapshot.providerCapabilities, errorMessage: nil
                    )
                    if let checkedRequest {
                        _ = reviewLoop.adoptDiscoveredReviewRequest(
                            checkedRequest, remote: lookup.remote, branch: lookup.branch,
                            headOwner: lookup.headOwner, baseBranch: lookup.baseBranch,
                            refreshGeneration: generation
                        )
                    }
                    _ = self.tabs.transitionPendingCreatedReview(worktreeId: worktreeID, snapshot: found)
                }
            }
        }
        rightPaneStore.attentionSnapshotDidChange = { [weak self] worktreeID, snapshot in
            self?.observeRightPaneAttention(worktreeID: worktreeID, snapshot: snapshot)
        }
        rightPaneStore.worktreeDidChange = { [weak self] worktreeID in
            self?.rescanWorktreeStatus(worktreeId: worktreeID)
            self?.refreshSymbolIndexIfLoaded(worktreeId: worktreeID)
        }
        RemoteHostStatusStore.shared.onStatusTransition = { [weak self] host, isDisconnected, date in
            guard let self else { return }
            self.observeHostAttention(host: host, isDisconnected: isDisconnected, at: date)
            if !isDisconnected {
                self.rescanRemoteWorktreeStatuses(host: host)
            }
        }
        harness.onActivityTransition = { [weak self] transition in
            self?.observeHarnessAttention(transition)
        }
        harness.onWorktreeActivityEvent = { [weak self] worktreeID in
            self?.rescanWorktreeStatus(worktreeId: worktreeID)
        }
        // Rescan local worktree status whenever the app regains focus, so a
        // git operation performed in another app (or a terminal outside
        // Alas) while backgrounded is reflected as soon as the user looks.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rescanWorktreeStatuses()
            }
        }
        self.runScheduler.persistenceErrorHandler = { [weak self] message in
            self?.persistenceErrorHandler("Schedules Save Failed", message)
        }
        hostEnvironment.app = self
        hostEnvironment.repoHookPrompter = .queue(repoHookApprovalQueue)
        hostEnvironment.worktreeCleanupLauncher = worktreeCleanupLauncher
        core.attention.onAdmit = { [weak self] signal in
            self?.registerAttentionAlias(for: signal)
        }
        core.runHistory.onFailure = { [weak self] message in
            self?.showFileActionError(title: "Run History Failed", message: message)
        }
        installRunScheduleRunner()
        installReviewShepherdEffects()
        installStackShepherdEffects()
        installSessionRecap()
        startLocalTextObservers()
        AlasTerminationCoordinator.shared.flush = { [weak self] in
            await self?.shutdownLocalTextFeatures()
            self?.runScheduler.stop()
            self?.reviewShepherd.stop()
            self?.stackShepherd.stop()
            await GGLandingStore.shared.cancelAllAndWait()
            self?.cancelPendingRunScriptLaunches()
            self?.cancelAllRunScriptCompletionTasks()
            await self?.flushRunHistoryPersistence()
            await self?.flushAllACPComposerDrafts()
            await PluginStorage.flushAll()
            await self?.awaitSessionSummaryCleanup()
        }
        Task.detached {
            RunScriptCompletionMonitor.cleanupStaleLocalFiles()
        }
        let cleanupProjects = projectsFile.projects
        Task.detached(priority: .utility) {
            WorktreeTrashCleaner.sweep(projects: cleanupProjects)
        }

        // Kick off a background resolution of the user's login-shell PATH so
        // every `Process.git()` invocation uses the same environment a terminal
        // session would (Homebrew, nvm, rbenv, etc.). Fire-and-forget: if it
        // hasn't finished by the first git command, gitEnv() falls back to the
        // process PATH (same behaviour as before).
        ShellEnvResolver.shared.resolve()

        // Probe gg CLI availability once at startup so the stacked-diffs
        // context provider (RightPaneStore.ggContextProvider) has an answer by the time
        // the first right pane activates. Wait for the login-shell PATH
        // resolution kicked off above first — otherwise a gg installed only
        // via Homebrew (not on the process's own PATH, e.g. launched from
        // Finder/Dock) can probe as "not installed" and stay stuck there,
        // since a non-force probe short-circuits once `hasProbed` is set.
        // A right pane can activate and evaluate the gate before this probe
        // resolves — it sees `isInstalled == false` and clears/skips its
        // stack. Re-evaluate every cached pane once the probe lands so a
        // real stack doesn't stay rendered as plain commits.
        Task { @MainActor [weak self] in
            await ShellEnvResolver.shared.waitUntilResolved()
            await GGAvailability.shared.probe()
            self?.rightPaneStore.reevaluateGGGates()
        }
    }

    func makeIssueResolver(selectedProjectID: String?) -> IssueResolver {
        let issueProviders = CodeHostIssueProviderRegistry.live()
        return IssueResolver(environment: .init(
            projects: { [weak self] in self?.projects ?? [] },
            selectedProjectID: { selectedProjectID },
            remotes: { project in
                try await GitService().remotes(worktreePath: URL(fileURLWithPath: project.path))
            },
            providers: IssueProviderRegistry([
                CodeHostIssueSourceProvider(kind: .github, providers: issueProviders),
                CodeHostIssueSourceProvider(kind: .gitlab, providers: issueProviders),
                ManualIssueProvider(metadataFetcher: .live),
            ])
        ))
    }

    func makeIssueSuggestionLoader() -> IssueSuggestionLoader {
        let projects = projects
        return IssueSuggestionLoader(environment: .init(
            projects: { projects },
            remotes: { project in
                try await GitService().remotes(worktreePath: URL(fileURLWithPath: project.path))
            },
            providers: .live()
        ))
    }

    var issueWorktreeNameAppleSuggestionsAvailable: Bool {
        config.issueWorktreeNameSuggestionsEnabled && LocalTextAppleIntelligence.isAvailable
    }

    var issueWorktreeNameSuggestionsAvailable: Bool {
        config.issueWorktreeNameSuggestionsEnabled && localTextModelAvailable
    }

    var qwenFallbackTitlesAvailable: Bool {
        config.harness.acpLocalTitlesEnabled && localTextModelAvailable
    }

    var issueWorktreeNameSuggestionAvailable: Bool {
        issueWorktreeNameAppleSuggestionsAvailable || issueWorktreeNameSuggestionsAvailable
    }

    /// A pending Qwen title would be discarded anyway once titles are off;
    /// cancelling frees the shared engine instead of running to its timeout.
    func setACPLocalTitlesEnabled(_ enabled: Bool) {
        let wasEnabled = config.harness.acpLocalTitlesEnabled
        config.harness.acpLocalTitlesEnabled = enabled
        if saveConfig() {
            onDeviceAIHelperSettingsError = nil
        } else {
            if enabled { config.harness.acpLocalTitlesEnabled = wasEnabled }
            onDeviceAIHelperSettingsError =
                "Could not save helper settings. Changes apply only to this session. Retry before quitting."
        }
        guard wasEnabled, !enabled else { return }
        qwenTitleRequests.cancelAll()
    }

    func setIssueWorktreeNameSuggestionsEnabled(_ enabled: Bool) {
        let previous = config.issueWorktreeNameSuggestionsEnabled
        config.issueWorktreeNameSuggestionsEnabled = enabled
        if saveConfig() {
            onDeviceAIHelperSettingsError = nil
        } else {
            if enabled { config.issueWorktreeNameSuggestionsEnabled = previous }
            onDeviceAIHelperSettingsError =
                "Could not save helper settings. Changes apply only to this session. Retry before quitting."
        }
        if previous, !enabled {
            issueWorktreeNameRequests.cancelAll()
            worktreeExplainerStoreInstance?.cancelPending()
        }
    }

    func makeQwenTitleFallback() -> ACPQwenTitleFallback {
        ACPQwenTitleFallback(
            engine: localTextInference,
            isAvailable: { [weak self] in self?.qwenFallbackTitlesAvailable ?? false },
            waitForLocalTextReadiness: { [weak self] in await self?.waitForLocalTextReadiness() },
            requests: qwenTitleRequests
        )
    }

    func makeIssueWorktreeNameSuggester() -> IssueWorktreeNameSuggester {
        IssueWorktreeNameSuggester(
            engine: localTextInference,
            isAppleIntelligenceAvailable: { [weak self] in
                self?.issueWorktreeNameAppleSuggestionsAvailable ?? false
            },
            generateWithAppleIntelligence: { request in
                await LocalTextAppleIntelligence.generate(request)
            },
            isMLXAvailable: { [weak self] in
                self?.issueWorktreeNameSuggestionsAvailable ?? false
            },
            requests: issueWorktreeNameRequests
        )
    }

    /// Commit message drafts borrow existing consent: Apple Intelligence under
    /// local chat titles, the downloaded model under next-prompt suggestions
    /// or session summaries.
    var commitMessageAppleSuggestionsAvailable: Bool {
        config.harness.acpLocalTitlesEnabled && LocalTextAppleIntelligence.isAvailable
    }

    var commitMessageMLXSuggestionsAvailable: Bool {
        (config.nextPromptSuggestionsEnabled || config.sessionSummariesEnabled) && localTextModelAvailable
    }

    var commitMessageSuggestionAvailable: Bool {
        commitMessageAppleSuggestionsAvailable || commitMessageMLXSuggestionsAvailable
    }

    func makeCommitMessageSuggester() -> CommitMessageSuggester {
        CommitMessageSuggester(
            engine: localTextInference,
            isAppleIntelligenceAvailable: { [weak self] in
                self?.commitMessageAppleSuggestionsAvailable ?? false
            },
            generateWithAppleIntelligence: { request in
                await LocalTextAppleIntelligence.generate(request)
            },
            isMLXAvailable: { [weak self] in
                self?.commitMessageMLXSuggestionsAvailable ?? false
            }
        )
    }

    func worktreeExplainerEvidence(
        for worktree: Worktree,
        in project: ProjectConfig
    ) -> WorktreeExplainerEvidence? {
        guard issueWorktreeNameSuggestionAvailable,
              !projectsManager.isMain(worktree, in: project),
              !worktree.path.isRemoteAlasPath
        else { return nil }
        let title = projectsManager.issueAttachment(
            projectId: project.id,
            worktreeId: worktree.id
        )?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorktreeExplainerEvidence(
            branch: worktree.branch,
            issueTitle: title.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func makeWorktreeExplainerSuggester() -> WorktreeExplainerSuggester {
        WorktreeExplainerSuggester(
            engine: localTextInference,
            isAppleIntelligenceAvailable: { [weak self] in
                self?.issueWorktreeNameAppleSuggestionsAvailable ?? false
            },
            generateWithAppleIntelligence: { request in
                await LocalTextAppleIntelligence.generate(request)
            },
            isMLXAvailable: { [weak self] in
                self?.issueWorktreeNameSuggestionsAvailable ?? false
            }
        )
    }

    /// Explanations are user-initiated. Available Apple Intelligence needs no
    /// extra opt-in; local fallback requires independent model permission.
    func makeMergeConflictExplainer() -> MergeConflictExplainer {
        MergeConflictExplainer(
            engine: localTextInference,
            isAppleIntelligenceAvailable: { LocalTextAppleIntelligence.isAvailable },
            generateWithAppleIntelligence: { request in
                await LocalTextAppleIntelligence.generate(request)
            },
            isMLXAvailable: { [weak self] in
                self?.localTextModelAvailable ?? false
            }
        )
    }

    /// Change summaries are user-initiated, like conflict explanations.
    func makeChangeSummarizer() -> ChangeSummarizer {
        ChangeSummarizer(
            engine: localTextInference,
            isAppleIntelligenceAvailable: { LocalTextAppleIntelligence.isAvailable },
            generateWithAppleIntelligence: { request in
                await LocalTextAppleIntelligence.generate(request)
            },
            isMLXAvailable: { [weak self] in
                self?.localTextModelAvailable ?? false
            }
        )
    }

    /// Inbox roll-ups are user-initiated, like change summaries.
    func makeAttentionRollUpSummarizer() -> AttentionRollUpSummarizer {
        AttentionRollUpSummarizer(
            engine: localTextInference,
            isAppleIntelligenceAvailable: { LocalTextAppleIntelligence.isAvailable },
            generateWithAppleIntelligence: { request in
                await LocalTextAppleIntelligence.generate(request)
            },
            isMLXAvailable: { [weak self] in
                self?.localTextModelAvailable ?? false
            }
        )
    }

    /// Nil when no on-device model can run, so the caller shows only the observed excerpt.
    func makeRunFailureBriefGenerator() -> RunFailureBriefCoordinator.Generate? {
        let router = LocalTextAppleFirstRouter(
            engine: localTextInference,
            isAppleIntelligenceAvailable: { LocalTextAppleIntelligence.isAvailable },
            generateWithAppleIntelligence: { request in
                await LocalTextAppleIntelligence.generate(request)
            },
            isMLXAvailable: { [weak self] in
                self?.localTextModelAvailable ?? false
            }
        )
        guard router.isAppleIntelligenceAvailable() || router.isMLXAvailable() else { return nil }
        return { input in
            await router.generate(
                RunFailureBriefPolicy.request(for: input),
                caller: .runFailureBrief,
                priority: .automatic
            ) { RunFailureBriefPolicy.parse($0) }
        }
    }

    /// All worktree IDs currently known to the projects manager (including
    /// hidden/archived ones).
    func allWorktreeIds() -> Set<String> {
        Set(projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        })
    }

    func toggleRightPaneVisibility() {
        config.rightPaneVisible.toggle()
        _ = saveConfig()
    }

    func acceptsRightPaneTabShortcut(_ tab: RightPaneTab) -> Bool {
        RightPaneTab.available().contains(tab)
    }

    func toggleSidebarVisibility() {
        config.sidebarVisible.toggle()
        _ = saveConfig()
    }

    /// Tear down tabs, terminals, harness state, and editor buffers for any
    /// worktree IDs that existed in `beforeIds` but are absent after a refresh.
    /// Also re-points selection if the selected worktree was removed.
    func cleanupMissingWorktrees(beforeIds: Set<String>) async {
        cleanupMissingWorktreeState(beforeIds: beforeIds, afterIds: allWorktreeIds())
    }

    private func cleanupMissingWorktreeState(beforeIds: Set<String>, afterIds: Set<String>) {
        let disappeared = beforeIds.subtracting(afterIds)
        let landingProjectsToMigrate = Set(disappeared.flatMap { id in
            tabs.tabs(forWorktree: id).compactMap { tab -> String? in
                guard case .ggLanding(let state) = tab,
                      GGLandingStore.shared.sessions[state.projectId] != nil
                else { return nil }
                return state.projectId
            }
        })
        for id in disappeared {
            cleanupWorktreeState(worktreeId: id)
        }
        // Stack badges are keyed by worktree path; drop entries for
        // worktrees that no longer exist so deleted stacks don't keep a
        // stale ▲ badge forever.
        let livePaths = Set(projectsManager.projects.flatMap { project in
            projectsManager.worktrees(projectId: project.id).map(\.path.path)
        })
        GGStackSummaryStore.shared.prune(keepingPaths: livePaths)
        WorktreeStatusStore.shared.prune(keepingPaths: livePaths)
        GGInboxStore.shared.prune(keepingProjectIds: Set(projects.map(\.id)))
        refreshGGSidebar()
        GGLandingStore.shared.prune(keepingProjectIds: Set(projects.map(\.id)))
        if reconcileMissingSpaceProjects() {
            saveSpaces()
        }
        let selectedWasRemoved = selectedWorktreeId.map(disappeared.contains) ?? false
        let selectionMovedOutOfActiveSpace = applyOwnershipChanges()
        if let current = selectedWorktreeId, !afterIds.contains(current) || selectionMovedOutOfActiveSpace {
            selectWorktree(id: resolvedSelectionForActiveSpace())
        }
        for projectId in landingProjectsToMigrate {
            migrateGGLanding(projectId: projectId, selectHost: selectedWasRemoved)
        }
    }

    /// Returns whether the selected row moved to a project outside the active
    /// space while its id stayed live, so the selection must be re-resolved.
    private func applyOwnershipChanges() -> Bool {
        let changed = projectsManager.takeOwnershipChangedIds()
        guard let selected = selectedWorktreeId, changed.contains(selected) else { return false }
        return !activeSpaceProjects.contains { projectsManager.worktrees(projectId: $0.id).contains { $0.id == selected } }
    }

    /// Reselects when directory ownership moved the selected row out of the
    /// active space, which startup arbitration can do.
    func reconcileSelectionAfterOwnershipChange() {
        if applyOwnershipChanges() {
            selectWorktree(id: resolvedSelectionForActiveSpace())
        }
    }

    /// Re-scan persisted tab JSONs for every currently-known worktree id. Call
    /// after `projectsManager.refreshAll()` so worktrees actually exist.
    func reloadTabs() {
        let restoringActiveTabs = restoreActiveTabsOnNextReload
        // Start stopping pre-freeze zmx daemons before anything attaches to
        // or sweeps persisted sessions; those paths await this same task.
        startZmxMigrationIfNeeded()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadWorkspaces()
            await self.restoreWorkspaceCheckoutSessionTabsAfterReload(restoringActiveTabs: restoringActiveTabs)
        }
        let allWorktreeIds = projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        }
        if restoringActiveTabs {
            tabs.loadAll(worktreeIds: allWorktreeIds)
        } else {
            tabs.loadAllPersisted(restoringActiveTabs: false)
        }
        restoreActiveTabsOnNextReload = true
        // When cross-quit persistence is disabled, drop every persisted
        // terminal tab right after load — across all worktrees, before
        // any lazy-display path could observe them — so orphan zmx
        // daemon sessions get killed via `closeTab` and inactive /
        // other-worktree tabs don't linger waiting for someone to open
        // them (which is the only thing that drives the per-tab guard
        // in `restoreTerminalTabIfNeeded`). The tabs go now; their `zmx kill`
        // waits for the migration through `TerminalService.killGate`.
        if !config.terminal.keepSessionsAlive {
            for worktreeId in allWorktreeIds {
                for tab in tabs.tabs(forWorktree: worktreeId) {
                    guard case .terminal = tab else { continue }
                    closeTab(worktreeId: worktreeId, tabId: tab.id)
                }
            }
        }
        // Persisted terminal-tab leaves are now in memory — refresh their
        // hook symlinks so zmx-persisted shells in undisplayed tabs deliver
        // hooks/CLI requests to the live harness immediately, rather than
        // waiting for `restoreTerminalTabIfNeeded` (driven by
        // TerminalTabView.task) to fire when the user opens the tab.
        refreshPersistedHookSymlinks()
        sweepOrphanZmxSessions(worktreeIds: allWorktreeIds)
        reconcileAttention(observations: currentAttentionObservations)
        Task { [weak self] in
            await self?.core.loadDelegatedSessionParents()
            await self?.core.recoverDelegations()
        }
        Task { @MainActor [weak self] in
            await self?.bootstrapScheduledACPSessions(worktreeIds: allWorktreeIds)
        }
    }

    /// Waits for the pre-freeze zmx migration, starting it on first use.
    /// Anything that attaches to or sweeps a session persisted by an earlier
    /// launch awaits this first: a pre-freeze daemon shows a stuck terminal
    /// on attach and hangs `zmx kill`.
    func awaitZmxMigration() async {
        await startZmxMigrationIfNeeded().value
    }

    /// Starts the migration once per instance without suspending, so
    /// concurrent callers share one run. It runs even when
    /// `keepSessionsAlive` is off, because that path kills persisted
    /// sessions with `zmx kill`.
    @discardableResult
    private func startZmxMigrationIfNeeded() -> Task<Void, Never> {
        if let zmxMigration { return zmxMigration }
        let task: Task<Void, Never>
        if let work = zmxMigrationWork() {
            let migration = Task.detached(priority: .userInitiated) {
                await BlockingWork.run(work)
            }
            // Kills dispatched meanwhile, such as the keep-alive-off prune,
            // run after it. Detached: `waitForPendingKills` blocks main.
            terminal.killGate = Task.detached { _ = await migration.value }
            task = Task { @MainActor [weak self] in
                let result = await migration.value
                self?.recordZmxMigration(result)
            }
        } else {
            task = Task {}
        }
        zmxMigration = task
        return task
    }

    /// The blocking migration for this instance, or nil when there is no zmx
    /// to migrate. Nothing migrates while the bundled zmx is itself
    /// pre-freeze: every daemon is one it can drive, and builds share the
    /// socket directory, so stopping them would kill another Alas' shells.
    /// An injected runner needs only the socket directory; the default also
    /// needs the bundled binary and never runs in a test host, which shares
    /// its socket directory with the Alas the developer runs.
    private func zmxMigrationWork(
        sockets: Set<String>? = nil
    ) -> (@Sendable () -> ZmxPreFreezeMigration.Result)? {
        guard bundledZmxWire == .v1 else { return nil }
        let env = terminal.zmxClient.env
        guard let directory = env.zmxDir else { return nil }
        if let runner = zmxMigrationRunner {
            return { runner(directory, sockets) }
        }
        guard env.isAvailable, !Self.isRunningUnitTests else { return nil }
        return { ZmxPreFreezeMigration.run(directory: directory, names: sockets) }
    }

    /// Logs a migration run and updates the sessions left pre-freeze: one a
    /// run found in use, could not stop, or got no answer from is blocked. A
    /// session stops being blocked only once a run restarted it, found its
    /// daemon current (v1), or its socket is gone (`recovered`) so
    /// `zmx attach` starts a fresh one. A
    /// re-run that could not classify it, such as a probe timeout, keeps it
    /// blocked: it was confirmed pre-freeze and still may be.
    private func recordZmxMigration(_ result: ZmxPreFreezeMigration.Result, recovered: Set<String> = []) {
        for name in result.restarted {
            Self.logger.info("Restarted pre-freeze zmx session \(name, privacy: .public)")
        }
        for name in result.failed {
            Self.logger.warning("Could not stop pre-freeze zmx session \(name, privacy: .public)")
        }
        for name in result.inUse {
            Self.logger.info("Left pre-freeze zmx session \(name, privacy: .public) running: another client is attached")
        }
        for name in result.unresponsive {
            Self.logger.warning("Left zmx session \(name, privacy: .public) running: its daemon did not answer the probe")
        }
        // Block first, then clear: a socket that vanished after the run
        // classified it means `zmx attach` is safe, whatever that run saw.
        zmxSessionsLeftPreFreeze.formUnion(
            (result.inUse + result.failed + result.unresponsive).compactMap(Self.zmxSessionName(forSocket:)))
        zmxSessionsLeftPreFreeze.subtract((result.restarted + result.current).compactMap(Self.zmxSessionName(forSocket:)))
        zmxSessionsLeftPreFreeze.subtract(recovered)
    }

    /// Whether a restore must leave the pane `name` would attach without a
    /// session: the migration left that daemon pre-freeze. Warns the first
    /// time a session is skipped.
    private func zmxSessionIsLeftPreFreeze(_ name: String) -> Bool {
        guard zmxSessionsLeftPreFreeze.contains(name) else { return false }
        if zmxSessionsSkippedPreFreeze.insert(name).inserted {
            Self.logger.warning(
                "Not attaching pre-freeze zmx session \(name, privacy: .public): it is in use, could not be stopped, or did not answer"
            )
        }
        return true
    }

    /// Re-runs the migration for the `candidates` a restore has already
    /// skipped once, so asking for such a pane again recovers it once the
    /// other client has detached. Runs one at a time.
    private func retryZmxMigration(forSessions candidates: Set<String>) async {
        guard !candidates.isDisjoint(with: zmxSessionsSkippedPreFreeze) else { return }
        let previous = zmxMigrationRetry
        let retry = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let sessions = candidates
                .intersection(zmxSessionsSkippedPreFreeze)
                .intersection(zmxSessionsLeftPreFreeze)
            guard !sessions.isEmpty,
                  let directory = terminal.zmxClient.env.zmxDir,
                  let work = zmxMigrationWork(sockets: Set(sessions.map { Self.zmxSessionPrefix + $0 }))
            else { return }
            let socketExists = zmxSocketExists
            let (result, gone) = await Task.detached(priority: .userInitiated) {
                await BlockingWork.run { () -> (ZmxPreFreezeMigration.Result, Set<String>) in
                    let result = work()
                    let gone = sessions.filter {
                        !socketExists(directory.appendingPathComponent(Self.zmxSessionPrefix + $0))
                    }
                    return (result, gone)
                }
            }.value
            recordZmxMigration(result, recovered: gone)
        }
        zmxMigrationRetry = retry
        await retry.value
    }

    /// The zmx session names the restore of `tabId` could attach: the
    /// owner-scoped name of each leaf without a live session, and for a
    /// worktree its legacy name too.
    private func zmxSessionNamesAwaitingRestore(owner: SessionOwnerID, tabId: TabID) -> Set<String> {
        guard let tab = tabs.tabs(for: owner).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab else { return [] }
        var names: Set<String> = []
        for leaf in state.root.leaves() where terminal.registry.session(for: leaf.id) == nil {
            names.insert(ZmxSessionName.derive(owner: owner, leafId: leaf.id))
            if case .worktree = owner { names.insert(ZmxSessionName.legacy(leafId: leaf.id)) }
        }
        return names
    }

    /// zmx names a session's socket `ZMX_SESSION_PREFIX` + its name.
    private nonisolated static var zmxSessionPrefix: String {
        ProcessInfo.processInfo.environment["ZMX_SESSION_PREFIX"] ?? ""
    }

    /// The session behind a socket name, or nil when the socket lacks the
    /// prefix and so is no session this process could attach.
    private nonisolated static func zmxSessionName(forSocket socket: String) -> String? {
        let prefix = zmxSessionPrefix
        guard socket.hasPrefix(prefix) else { return nil }
        return String(socket.dropFirst(prefix.count))
    }

    /// Debounce window for status rescans. Activation, selection and topology
    /// changes often arrive together; this collapses a burst into one pass.
    private static let worktreeStatusDebounce: Duration = .milliseconds(250)

    /// Recompute working-tree status for every local worktree.
    ///
    /// Remote projects are excluded from the local scanner deliberately. Their
    /// status arrives through `RemoteWorktreeSummary`, which already carries
    /// `changedFileCount` and `conflictCount`; when requested, remote projects
    /// refresh through that summary path instead of the local git-status
    /// scanner.
    func rescanWorktreeStatuses(includeRemote: Bool = true) {
        refreshGGSidebar()
        let paths = localWorktreeStatusPaths()
        if includeRemote {
            rescanRemoteWorktreeStatuses()
        }
        enqueueLocalWorktreeStatusRescan(paths: paths)
    }

    /// Only local, enabled and unambiguous stacks participate. The controller
    /// shares inbox work with the tab and throttles attention-triggered scans.
    func refreshGGSidebar() {
        ggSidebarPreparationTask?.cancel()
        guard config.changes.stackedDiffsEnabled, GGAvailability.shared.isInstalled else {
            if !ggSidebarSnapshots.isEmpty { ggSidebarSnapshots = [:] }
            ggSidebarRefresh.refresh(projects: [])
            return
        }
        let paths = projects.filter { $0.host == nil && !$0.isFolder }.map(\.path)
        ggSidebarPreparationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let snapshots = await GGConfigReader.sidebarSnapshots(repoPaths: paths)
            guard !Task.isCancelled, let self else { return }
            if self.ggSidebarSnapshots != snapshots {
                self.ggSidebarSnapshots = snapshots
            }
            self.refreshGGSidebarFromSnapshot()
        }
    }

    private func refreshGGSidebarFromSnapshot() {
        let availability = GGAvailability.shared
        guard availability.capabilities.localStackSnapshot,
              GGInboxSupport.isSupported(version: availability.version),
              config.changes.stackedDiffsEnabled else {
            ggSidebarRefresh.refresh(projects: [])
            return
        }
        let targets: [GGSidebarRefreshController.Project] = projects.compactMap { project in
            guard ggSidebarInboxAvailable(projectId: project.id) else { return nil }
            let snapshot = ggSidebarSnapshots[project.path] ?? .init()
            let repoHasGGConfig = snapshot.hasConfig
            let username = snapshot.branchUsername
            let allWorktrees = projectsManager.worktrees(projectId: project.id)
            let branches = allWorktrees.map { (id: $0.id, branch: $0.branch) }
            let names = branches.compactMap { branch -> String? in
                guard let slash = branch.branch.firstIndex(of: "/") else { return nil }
                return String(branch.branch[branch.branch.index(after: slash)...])
            }
            let ambiguous = Set(names.filter {
                GGInboxWorktreeResolver.hasAmbiguousLocalOwners(stackName: $0, worktrees: branches)
            })
            let worktrees = projectsManager.visibleWorktrees(projectId: project.id).compactMap { worktree -> GGSidebarRefreshController.Worktree? in
                let context = Self.resolveGGWorktreeContext(
                    masterEnabled: true, ggInstalled: availability.isInstalled, project: project,
                    worktreeOverride: effectiveGGWorktreeMode(projectId: project.id, worktreeId: worktree.id),
                    isMainWorktree: projectsManager.isMain(worktree, in: project),
                    repoHasGGConfig: repoHasGGConfig, branchUsername: username, branch: worktree.branch
                )
                guard context.permitsCurrentStackQuery else { return nil }
                if case .active(let name) = context {
                    guard !ambiguous.contains(name) else { return nil }
                    return .init(path: worktree.path.path, stackName: name)
                }
                // A detached entry needs the CLI to resolve its owning stack.
                return .init(path: worktree.path.path, stackName: nil)
            }.sorted { $0.path < $1.path }
            guard !worktrees.isEmpty else { return nil }
            return .init(id: project.id, path: project.path, worktrees: worktrees, ambiguousStackNames: ambiguous)
        }
        ggSidebarRefresh.refresh(projects: targets)
    }

    private func rescanWorktreeStatus(worktreeId: String) {
        refreshGGSidebar()
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeId),
              !resolved.project.isFolder
        else { return }
        if resolved.project.host != nil {
            enqueueRemoteWorktreeStatusRescan(project: resolved.project, worktree: resolved.worktree)
        } else {
            scanLocalWorktreeStatus(paths: [resolved.worktree.path])
        }
    }

    private func rescanLocalWorktreeStatuses(projectId: String) {
        guard projectsManager.projects.contains(where: { $0.id == projectId && $0.host == nil }) else { return }
        let paths = localWorktreeStatusPaths(projectId: projectId)
        enqueueLocalWorktreeStatusRescan(paths: paths)
    }

    func localWorktreeStatusPaths(projectId: String? = nil) -> [URL] {
        projectsManager.projects
            .filter { project in
                project.host == nil && !project.isFolder && (projectId == nil || project.id == projectId)
            }
            .flatMap { projectsManager.visibleWorktrees(projectId: $0.id) }
            .map(\.path)
    }

    private func enqueueLocalWorktreeStatusRescan(paths: [URL]) {
        guard !paths.isEmpty else { return }
        mergePendingWorktreeStatusRescanPaths(paths)
        worktreeStatusRescanTask?.cancel()
        worktreeStatusRescanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.worktreeStatusDebounce)
            guard !Task.isCancelled else { return }
            let paths = self.pendingWorktreeStatusRescanPaths
            self.pendingWorktreeStatusRescanPaths = []
            self.scanLocalWorktreeStatus(paths: paths)
        }
    }

    private func mergePendingWorktreeStatusRescanPaths(_ paths: [URL]) {
        var seen = Set(pendingWorktreeStatusRescanPaths.map(\.path))
        for path in paths where seen.insert(path.path).inserted {
            pendingWorktreeStatusRescanPaths.append(path)
        }
    }

    private func scanLocalWorktreeStatus(paths: [URL]) {
        guard !paths.isEmpty else { return }
        // Cancellation bounds only the debounce window above. The scan itself
        // runs in a fresh unstructured task so a later rescan request cannot
        // SIGTERM it mid-pass: `Process.run` is cancellation-aware, and killing
        // an in-flight scan here would still let its drain loop spawn a process
        // per remaining path that gets immediately terminated.
        // `WorktreeStatusScanner` already coalesces overlapping requests (a
        // request arriving mid-scan sets a rescan flag instead of starting a
        // second pass), so letting this run to completion is correct.
        Task { await worktreeStatusScan(paths) }
    }

    private func rescanLocalWorktreeStatus(worktreeId: String) {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeId),
              resolved.project.host == nil,
              !resolved.project.isFolder
        else { return }
        scanLocalWorktreeStatus(paths: [resolved.worktree.path])
    }

    private func rescanRemoteWorktreeStatuses(projectId: String? = nil) {
        let remoteProjects = projectsManager.projects.filter { project in
            project.host != nil && !project.isFolder && (projectId == nil || project.id == projectId)
        }
        guard !remoteProjects.isEmpty else { return }
        for project in remoteProjects {
            enqueueRemoteWorktreeStatusRescan(project: project)
        }
    }

    private func rescanRemoteWorktreeStatuses(host: String) {
        let remoteProjects = projectsManager.projects.filter { $0.host == host && !$0.isFolder }
        guard !remoteProjects.isEmpty else { return }
        for project in remoteProjects {
            enqueueRemoteWorktreeStatusRescan(project: project)
        }
    }

    private func enqueueRemoteWorktreeStatusRescan(project: ProjectConfig) {
        let projectScanToken = remoteWorktreeStatusRescanGenerations.beginProjectScan(
            projectID: project.id,
            worktreeIDs: projectsManager.visibleWorktrees(projectId: project.id).map(\.id)
        )
        remoteWorktreeStatusRescanTasks[project.id]?.cancel()
        remoteWorktreeStatusRescanTasks[project.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.worktreeStatusDebounce)
            guard !Task.isCancelled else { return }
            defer {
                if self.remoteWorktreeStatusRescanGenerations.isCurrent(projectScanToken) {
                    self.remoteWorktreeStatusRescanTasks[project.id] = nil
                }
            }
            var results: [String: WorktreeDirtyState] = [:]
            var diffs: [String: WorktreeDiffStats] = [:]
            var targetedGenerationsByPath: [String: Int] = [:]
            var targetedWorktreeIDsByPath: [String: String] = [:]
            let isOfflineHost = project.host.map { RemoteHostStatusStore.shared.offlineHosts.contains($0) } ?? false
            guard !isOfflineHost else { return }
            for worktree in projectsManager.visibleWorktrees(projectId: project.id) {
                switch projectsManager.operationState(forWorktreeId: worktree.id, projectId: project.id) {
                case .creating, .preparingDelete, .deleting, .archiving, .createFailed:
                    continue
                case nil, .launchFailed, .deleteFailed:
                    guard let worktreeGeneration = projectScanToken.worktreeGeneration(worktreeID: worktree.id)
                    else { continue }
                    targetedWorktreeIDsByPath[worktree.path.path] = worktree.id
                    targetedGenerationsByPath[worktree.path.path] = worktreeGeneration
                    guard let snapshot = await remoteWorktreeStatus(worktree: worktree) else { continue }
                    results[worktree.path.path] = snapshot.state
                    diffs[worktree.path.path] = snapshot.diff
                }
            }
            guard !Task.isCancelled,
                  self.remoteWorktreeStatusRescanGenerations.isCurrent(projectScanToken)
            else { return }
            let currentResults = results.filter { path, _ in
                guard let worktreeID = targetedWorktreeIDsByPath[path],
                      let currentGeneration = targetedGenerationsByPath[path]
                else { return true }
                return self.remoteWorktreeStatusRescanGenerations.isCurrentWorktree(
                    projectID: project.id,
                    worktreeID: worktreeID,
                    generation: currentGeneration
                )
            }
            WorktreeStatusStore.shared.apply(currentResults)
            WorktreeStatusStore.shared.applyDiffStats(diffs.filter { currentResults[$0.key] != nil })
        }
    }

    private func enqueueRemoteWorktreeStatusRescan(project: ProjectConfig, worktree: Worktree) {
        let worktreeScanToken = remoteWorktreeStatusRescanGenerations.beginWorktreeScan(
            projectID: project.id,
            worktreeID: worktree.id
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.worktreeStatusDebounce)
            guard self.remoteWorktreeStatusRescanGenerations.isCurrent(worktreeScanToken)
            else { return }
            let isOfflineHost = project.host.map { RemoteHostStatusStore.shared.offlineHosts.contains($0) } ?? false
            guard !isOfflineHost else { return }
            switch self.projectsManager.operationState(forWorktreeId: worktree.id, projectId: project.id) {
            case .creating, .preparingDelete, .deleting, .archiving, .createFailed:
                return
            case nil, .launchFailed, .deleteFailed:
                break
            }
            guard let snapshot = await self.remoteWorktreeStatus(worktree: worktree),
                  self.remoteWorktreeStatusRescanGenerations.isCurrent(worktreeScanToken)
            else { return }
            WorktreeStatusStore.shared.apply([worktree.path.path: snapshot.state])
            if let diff = snapshot.diff {
                WorktreeStatusStore.shared.applyDiffStats([worktree.path.path: diff])
            }
        }
    }

    private func remoteWorktreeStatus(worktree: Worktree) async -> (state: WorktreeDirtyState, diff: WorktreeDiffStats?)? {
        do {
            let changes = try await GitService().statusIdentity(worktreePath: worktree.path)
            let fileCount = Set(changes.map(\.path)).count
            guard fileCount > 0 else { return (.clean, WorktreeDiffStats(added: 0, deleted: 0)) }
            let diff = try? await GitService().worktreeDiffStats(worktreePath: worktree.path)
            return (.dirty(fileCount: fileCount, conflictCount: changes.filter { $0.conflict != nil }.count), diff)
        } catch {
            return nil
        }
    }

    func restoreWorkspaceCheckoutSessionTabsAfterReload(restoringActiveTabs: Bool) async {
        loadWorkspaceCheckoutSessionTabs(restoringActiveTabs: restoringActiveTabs)
        await restoreLoadedWorkspaceCheckoutACPSessions()
        if !config.terminal.keepSessionsAlive {
            pruneWorkspaceCheckoutTerminalTabs()
        }
        refreshPersistedHookSymlinks()
        sweepOrphanWorkspaceCheckoutZmxSessions()
        reconcileAttention(observations: currentAttentionObservations)
    }

    private func restoreLoadedWorkspaceCheckoutACPSessions() async {
        guard workspacesManager.canMutate else { return }
        let tasks = workspacesManager.checkouts.compactMap { checkout -> Task<Void, Never>? in
            guard checkout.archivedAt == nil else { return nil }
            return Task { @MainActor in
                _ = await restoreWorkspaceCheckoutACPSessions(checkout)
            }
        }
        for task in tasks { await task.value }
    }

    private func bootstrapScheduledACPSessions(worktreeIds: [String]) async {
        let tasks = worktreeIds.compactMap { worktreeId -> Task<Void, Never>? in
            guard let worktree = worktree(withId: worktreeId),
                  let manager = acpManager(for: worktree)
            else { return nil }
            return Task { @MainActor in
                await bootstrapScheduledACPSessions(owner: .worktree(worktreeId), manager: manager)
            }
        }
        for task in tasks { await task.value }
    }

    private func bootstrapScheduledACPSessions(owner: SessionOwnerID, manager: ACPSessionManager) async {
        let releaseUntabbed: @MainActor (ACPSession.ID) -> Void = { [weak self] sessionId in
            guard let self else { return }
            guard !hasACPSessionTab(owner: owner, sessionId: sessionId) else { return }
            cleanupACPSession(owner: owner, sessionId: sessionId)
        }
        _ = await manager.bootstrapScheduledQueueSessions(onBootstrapped: releaseUntabbed)
        _ = await manager.bootstrapInterruptedQueueSessions(onBootstrapped: releaseUntabbed)
    }

    private func hasACPSessionTab(owner: SessionOwnerID, sessionId: ACPSession.ID) -> Bool {
        tabs.tabs(for: owner).contains {
            guard case .acpSession(let state) = $0 else { return false }
            return state.sessionId == sessionId
        }
    }

    func loadWorkspaceCheckoutSessionTabs(restoringActiveTabs: Bool = true) {
        guard workspacesManager.canMutate else { return }
        for checkout in workspacesManager.checkouts {
            loadSessionTabs(
                owner: SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation),
                restoringActiveTabs: restoringActiveTabs
            )
        }
    }

    private func pruneWorkspaceCheckoutTerminalTabs() {
        guard workspacesManager.canMutate else { return }
        for checkout in workspacesManager.checkouts {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            for tab in tabs.tabs(for: owner) {
                guard case .terminal = tab else { continue }
                closeSharedSessionTab(owner: owner, tabID: tab.id)
            }
        }
    }

    func completeStartupRecovery(rightPaneReady: Bool = true) {
        suppressesRestoredRightPaneAfterAbandonedStartup = false
        guard rightPaneReady else { return }
        startupRecoveryNeedsMountedRightPaneRefresh = false
        AlasTerminationCoordinator.shared.finish?()
    }

    func hasCompletedStartupRightPaneRefresh(for worktreeID: String) -> Bool {
        !startupRecoveryNeedsMountedRightPaneRefresh || startupRecoveryReadyRightPaneID == worktreeID
    }

    func beginStartupRightPaneRefresh() {
        guard startupRecoveryNeedsMountedRightPaneRefresh else { return }
        startupRecoveryReadyRightPaneID = nil
    }

    func completeStartupRightPaneRefresh(for worktreeID: String) {
        guard startupRecoveryNeedsMountedRightPaneRefresh else { return }
        startupRecoveryReadyRightPaneID = worktreeID
    }

    func completeStartupRecoveryIfCenterPaneWillNotAppear() {
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: selectedWorktreeId,
            projects: activeSpaceProjects,
            projectsManager: projectsManager,
            isRefreshingProjectTopologies: isRefreshingProjectTopologies
        )
        if case .worktree = resolver.resolve() { return }
        completeStartupRecovery()
    }

    /// Compute (knownWorktreeIds, knownLeafIds) from in-memory state and
    /// hand them to `TerminalService.sweepOrphans`. Run after `reloadTabs`
    /// so persisted leaves are visible; without this, sessions leaked by
    /// any prior bug (or quit race) would persist forever because nothing
    /// would ever try to kill them on subsequent launches.
    ///
    /// Waits for the pre-freeze migration first. Leaf ids are read after the
    /// wait so a pane opened meanwhile is not swept as an orphan.
    private func sweepOrphanZmxSessions(worktreeIds: [String]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await awaitZmxMigration()
            sweepOrphanZmxSessionsNow(worktreeIds: worktreeIds)
        }
    }

    private func sweepOrphanZmxSessionsNow(worktreeIds: [String]) {
        var leafIds: Set<String> = []
        for worktreeId in worktreeIds {
            for tab in tabs.tabs(forWorktree: worktreeId) {
                guard case .terminal(let state) = tab else { continue }
                for leaf in state.root.leaves() {
                    leafIds.insert(leaf.id)
                }
            }
        }
        terminal.sweepOrphans(
            knownWorktreeIds: Set(worktreeIds),
            knownLeafIds: leafIds
        )

        let remoteProjects = projects.filter { $0.host != nil }
        for host in Set(remoteProjects.compactMap(\.host)) {
            let hostWorktreeIds = Set(remoteProjects
                .filter { $0.host == host }
                .flatMap { projectsManager.worktrees(projectId: $0.id).map(\.id) })
            guard !hostWorktreeIds.isEmpty else { continue }
            Task {
                await TerminalService.sweepRemoteOrphans(
                    host: host,
                    knownWorktreeIds: hostWorktreeIds,
                    knownLeafIds: leafIds
                )
            }
        }
    }

    /// Like `sweepOrphanZmxSessions`, waits for the pre-freeze migration and
    /// reads the known leaves after it.
    private func sweepOrphanWorkspaceCheckoutZmxSessions() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await awaitZmxMigration()
            sweepOrphanWorkspaceCheckoutZmxSessionsNow()
        }
    }

    private func sweepOrphanWorkspaceCheckoutZmxSessionsNow() {
        let knownLeavesByOwner = workspaceCheckoutTerminalLeafIDsByOwner()
        terminal.sweepWorkspaceCheckoutOrphans(knownLeavesByOwner: knownLeavesByOwner)

        let remoteHosts = Set(knownLeavesByOwner.keys.compactMap { owner -> String? in
            guard case .workspaceCheckout(_, .ssh(let host)) = owner else { return nil }
            return host
        })
        for host in remoteHosts {
            Task {
                await TerminalService.sweepRemoteWorkspaceCheckoutOrphans(
                    host: host,
                    knownLeavesByOwner: knownLeavesByOwner
                )
            }
        }
    }

    func workspaceCheckoutTerminalLeafIDsByOwner() -> [SessionOwnerID: Set<String>] {
        Dictionary(uniqueKeysWithValues: workspacesManager.checkouts.map { checkout in
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            guard checkout.archivedAt == nil, checkout.operation != .archiving else {
                return (owner, [])
            }
            let leafIDs = tabs.tabs(for: owner).flatMap { tab -> [String] in
                guard case .terminal(let state) = tab else { return [] }
                return state.root.leaves().map(\.id)
            }
            return (owner, Set(leafIDs))
        })
    }

    var projects: [ProjectConfig] { projectsManager.projects }

    var activeSpaceProjects: [ProjectConfig] {
        spacesManager.activeProjects(from: projects)
    }

    /// The selected checkout may focus a member that is not a normal Project
    /// peer of the active Space. Existing repository panes still receive a
    /// Worktree, but only from this explicit checkout-member resolution.
    var navigationProjects: [ProjectConfig] {
        workspaceNavigationState.selectedCheckoutID == nil ? activeSpaceProjects : projects
    }

    var selectedWorkspaceCheckout: WorkspaceCheckout? {
        workspaceNavigationState.selectedCheckoutID.flatMap(workspacesManager.checkout(id:))
    }

    /// The worktree whose `CenterPaneView` is currently mounted, if any.
    /// `InAppNotificationStack` renders only inside a mounted `CenterPaneView`,
    /// so an in-app banner posted for any other id is never drawn. Mirrors the
    /// exact branch conditions of `RootView`'s center content: no banner while
    /// a native peer session/document or the forest preview is on screen, none
    /// on the workspace overview or the empty state, and the checkout fallback
    /// pane posts under its pseudo worktree id.
    var inAppBannerWorktreeID: String? {
        if isPreviewingForestScenes || nativePeerSessions?.coversCenterPane == true { return nil }
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: selectedWorktreeId,
            projects: navigationProjects,
            projectsManager: projectsManager,
            allowedWorktreeIDs: checkoutScopedWorktreeIDs,
            checkoutFocusedWorktreeScope: checkoutFocusedWorktreeScope,
            isRefreshingProjectTopologies: isRefreshingProjectTopologies
        )
        if case .worktree(let wt) = resolver.resolve() { return wt.id }
        if selectedWorkspaceCheckout != nil,
           sharedSessionFallbackWorktreeForSelectedWorkspaceCheckout() != nil {
            return sharedSessionFallbackWorktreeForSelectedWorkspaceCheckout()?.id
        }
        return nil
    }

    /// A refreshed snapshot can archive or remove the displayed checkout.
    /// Clear its focus so no repository pane keeps a stale checkout context.
    func reconcileWorkspaceNavigationSelection() {
        guard let checkoutID = workspaceNavigationState.selectedCheckoutID,
              workspacesManager.checkout(id: checkoutID) == nil
        else { return }
        workspaceNavigationState.removeCheckout(checkoutID)
        selectedWorktreeId = nil
    }

    var checkoutScopedWorktreeIDs: Set<String>? {
        guard workspaceNavigationState.selectedCheckoutID != nil else { return nil }
        return Set(workspaceNavigationState.repositoryFocusWorktreeID.map { [$0] } ?? [])
    }

    var checkoutFocusedWorktreeScope: CheckoutFocusedWorktreeScope? {
        guard let checkout = selectedWorkspaceCheckout,
              let memberID = workspaceNavigationState.focusedCheckoutMemberID,
              let worktreeID = workspaceNavigationState.repositoryFocusWorktreeID,
              let member = checkout.members.first(where: { $0.id == memberID })
        else { return nil }
        return CheckoutFocusedWorktreeScope(
            worktreeID: worktreeID,
            projectID: member.projectID,
            executionLocation: checkout.executionLocation
        )
    }

    func sharedSessionFallbackWorktreeForSelectedWorkspaceCheckout() -> Worktree? {
        guard let checkout = selectedWorkspaceCheckout,
              workspaceNavigationState.repositoryFocusWorktreeID == nil
        else { return nil }
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        guard !tabs.tabs(for: owner).isEmpty else { return nil }
        return Worktree(
            id: "workspace-checkout:\(owner.storageKey)",
            projectId: "workspace-checkout",
            name: checkout.fallbackWorkspaceName,
            branch: checkout.branch,
            path: URL(fileURLWithPath: checkout.rootPath),
            status: .clean,
            lastActivity: checkout.createdAt,
            createdAt: checkout.createdAt
        )
    }

    func selectWorkspace(id: UUID) {
        guard workspacesManager.canMutate else { return }
        nativePeerSessions?.clearSelection()
        workspaceNavigationState.selectWorkspace(id)
        selectedWorktreeId = nil
    }

    func selectWorkspaceCheckout(id: UUID) {
        guard workspacesManager.canMutate else { return }
        guard let checkout = workspacesManager.checkout(id: id) else { return }
        nativePeerSessions?.clearSelection()
        workspaceNavigationState.selectCheckout(checkout, resolvedWorktreeIDs: workspaceMemberWorktreeIDs(checkout))
        selectedWorktreeId = workspaceNavigationState.repositoryFocusWorktreeID
        if let selectedWorktreeId {
            rescanWorktreeStatus(worktreeId: selectedWorktreeId)
        }
    }

    func focusWorkspaceCheckoutMember(id: UUID) {
        guard workspacesManager.canMutate else { return }
        guard let checkout = selectedWorkspaceCheckout else { return }
        nativePeerSessions?.clearSelection()
        workspaceNavigationState.selectMember(id, in: checkout, resolvedWorktreeIDs: workspaceMemberWorktreeIDs(checkout))
        selectedWorktreeId = workspaceNavigationState.repositoryFocusWorktreeID
        if let selectedWorktreeId {
            rescanWorktreeStatus(worktreeId: selectedWorktreeId)
        }
    }

    /// Opens a Workspace checkout focused on one member, switching to a Space
    /// that shows the Workspace when the active one does not.
    func openWorkspaceCheckoutMember(checkoutID: UUID, memberID: UUID) {
        guard workspacesManager.canMutate,
              let checkout = workspacesManager.checkout(id: checkoutID)
        else { return }
        if let workspaceID = checkout.workspaceID {
            let reference = SpaceMemberReference.workspace(workspaceID)
            let activeMembers = spacesManager.space(id: spacesManager.activeSpaceId)?.members ?? []
            if !activeMembers.contains(reference),
               let space = spacesManager.spaces.first(where: { $0.members?.contains(reference) == true }) {
                _ = switchToSpace(id: space.id)
            }
        }
        selectWorkspaceCheckout(id: checkoutID)
        focusWorkspaceCheckoutMember(id: memberID)
    }

    func openWorkspaceCheckoutSearchResult(
        relativePath: String,
        worktreeId: String,
        checkoutID: UUID,
        memberID: UUID,
        revealLine: Int? = nil,
        revealEndLine: Int? = nil,
        revealCharacter: Int? = nil
    ) -> Bool {
        guard workspacesManager.canMutate else { return false }
        selectWorkspaceCheckout(id: checkoutID)
        guard let checkout = selectedWorkspaceCheckout,
              checkout.id == checkoutID,
              checkout.members.contains(where: { $0.id == memberID })
        else { return false }
        focusWorkspaceCheckoutMember(id: memberID)
        guard selectedWorktreeId == worktreeId else { return false }
        openFile(
            relativePath: relativePath,
            worktreeId: worktreeId,
            revealLine: revealLine,
            revealEndLine: revealEndLine,
            revealCharacter: revealCharacter
        )
        return true
    }

    private func workspaceMemberWorktreeIDs(_ checkout: WorkspaceCheckout) -> [UUID: String] {
        WorkspaceMemberWorktreeResolver.resolvedWorktreeIDs(
            checkout: checkout,
            worktrees: projects.flatMap { projectsManager.worktrees(projectId: $0.id) }
        )
    }

    private func isExactWorkspaceRepairCandidate(path: String, lineageID: String, member: WorkspaceCheckoutMember) -> Bool {
        guard let plan = member.plan,
              let expectedLineage = member.gitLineageID,
              !expectedLineage.isEmpty,
              !lineageID.isEmpty
        else { return false }
        return URL(fileURLWithPath: plan.destinationPath).standardizedFileURL.path == path
            && member.worktreePath == plan.destinationPath
            && lineageID == expectedLineage
    }

    /// Build a `RepoSelectorEnvironment` that captures `self`. Used by
    /// `RepoSelectorDialog` to bind the model to the live app state.
    func repoSelectorEnvironment(
        openNewProject: @escaping () -> Void,
        openNewWorktree: @escaping (String) -> Void
    ) -> RepoSelectorEnvironment {
        RepoSelectorEnvironment(
            projects: { [weak self] in self?.projects ?? [] },
            visibleWorktrees: { [weak self] projectId in
                guard let self else { return [] }
                // Match `RootView.selectedWorktree()`: hide creating /
                // deleting / createFailed rows (the main pane returns nil
                // for them) but keep preflight and deleteFailed rows selectable.
                return self.projectsManager.visibleWorktrees(projectId: projectId).filter {
                    switch self.projectsManager.operationState(forWorktreeId: $0.id, projectId: projectId) {
                    case .creating, .deleting, .archiving, .createFailed:
                        return false
                    case nil, .preparingDelete, .launchFailed, .deleteFailed:
                        return true
                    }
                }
            },
            readRecents: { [weak self] in
                guard let self else { return RepoSelectorRecents() }
                return RepoSelectorRecents(
                    projectIds: self.config.recentProjectIds,
                    worktreeIdsByProject: self.config.recentWorktreeIdsByProject,
                    recentWorktreeRefs: self.config.recentWorktreeRefs
                )
            },
            writeRecents: { [weak self] r in
                guard let self else { return }
                self.config.recentProjectIds = r.projectIds
                self.config.recentWorktreeIdsByProject = r.worktreeIdsByProject
                self.config.recentWorktreeRefs = r.recentWorktreeRefs
                _ = self.saveConfig()
            },
            focusWorktree: { [weak self] id, projectId in
                self?.focusGlobalWorktree(id: id, projectId: projectId)
            },
            openNewProject: openNewProject,
            openNewWorktree: openNewWorktree,
            currentWorktreeId: { [weak self] in self?.selectedWorktreeId },
            pluginCommands: { [weak self] in
                guard let self else { return [] }
                return self.pluginCommands(.palette, projectID: self.selectedPluginProjectID)
            },
            runPluginCommand: { [weak self] in self?.runPluginCommand($0, slot: .palette) }
        )
    }

    @discardableResult
    func saveConfig() -> Bool {
        let shouldUpdateLSPRegistry = languageServerConfigChangeTracker.consumeChange(in: config)
        let saved: Bool
        do {
            try store.write(config, to: Paths.appConfigFile)
            saved = true
        } catch {
            saved = false
            persistenceErrorHandler("Settings Save Failed", error.localizedDescription)
        }
        if shouldUpdateLSPRegistry {
            lspManager?.updateRegistry(LanguageServerRegistry(userDefined: config.code.languageServers))
        }
        return saved
    }

    func setDefaultWorktreeOrdering(_ mode: AppConfig.WorktreeSortMode) {
        guard config.worktrees.defaultOrdering != mode else { return }
        config.worktrees.defaultOrdering = mode
        saveConfig()
        if projectsManager.reapplyOrderingForAllProjects() {
            saveProjects()
        }
    }

    /// Loads run one at a time in call order, so each caller observes its own
    /// load and the most recent call is the last to apply.
    func loadWorkspaces() async {
        let previous = workspaceLoadTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performWorkspaceLoad()
        }
        workspaceLoadTask = task
        await task.value
    }

    private func performWorkspaceLoad() async {
        let legacySpaces = spacesManager.file
        let reconciled = await workspacesManager.load(spacesFile: legacySpaces)
        reconcileWorkspaceNavigationSelection()
        workspaceRecoveryError = workspacesManager.recoveryState
        if let recovery = workspaceRecoveryError {
            persistenceErrorHandler("Workspace Recovery Required", recovery.message)
        }
        guard let reconciled,
              spacesManager.file == legacySpaces
        else { return }
        // Loading may reveal dormant typed members, but loading itself is
        // not a user mutation. Keep that projection in memory until a later
        // explicit Spaces or Workspace action persists it.
        spacesManager.replace(file: reconciled)
    }

    func discardWorkspaceRecoveryState() async {
        do {
            try await workspaceStore.discardUnreadableState()
            workspaceRecoveryError = nil
            await loadWorkspaces()
        } catch {
            persistenceErrorHandler("Workspace Recovery Failed", error.localizedDescription)
        }
    }

    struct LanguageServerConfigChangeTracker {
        private var lastSavedLanguageServers: [LanguageServerConfig]

        init(initial: [LanguageServerConfig]) {
            lastSavedLanguageServers = initial
        }

        mutating func consumeChange(in config: AppConfig) -> Bool {
            guard config.code.languageServers != lastSavedLanguageServers else { return false }
            lastSavedLanguageServers = config.code.languageServers
            return true
        }
    }

    @discardableResult
    func saveProjects() -> Bool {
        do {
            try core.saveProjects()
            return true
        } catch {
            persistenceErrorHandler("Projects Save Failed", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func saveSpaces() -> Bool {
        scheduledSpacesSave?.cancel()
        scheduledSpacesSave = nil
        return writeSpaces()
    }

    private func writeSpaces() -> Bool {
        do {
            let file = spacesManager.file
            try store.write(file, to: Paths.spacesFile)
            enqueueWorkspaceSpaceCheckpoint(afterWriting: file)
            return true
        } catch {
            persistenceErrorHandler("Spaces Save Failed", error.localizedDescription)
            return false
        }
    }

    private func enqueueWorkspaceSpaceCheckpoint(afterWriting spacesFile: SpacesFile) {
        let previous = workspaceSpaceCheckpointTask
        let manager = workspacesManager
        workspaceSpaceCheckpointTask = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await manager.checkpointSpaceLayouts(afterWriting: spacesFile)
            } catch {
                self?.persistenceErrorHandler("Workspace Spaces Save Failed", error.localizedDescription)
            }
        }
    }

    func waitForWorkspaceSpaceCheckpoint() async {
        await workspaceSpaceCheckpointTask?.value
    }

    private func scheduleSpacesSave() {
        scheduledSpacesSave?.cancel()
        scheduledSpacesSave = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.scheduledSpacesSave = nil
            _ = self.writeSpaces()
        }
    }

    func flushScheduledSpacesSave() {
        guard scheduledSpacesSave != nil else { return }
        _ = saveSpaces()
    }

    func selectWorktree(id: String?, includeRemoteStatus: Bool = true) {
        nativePeerSessions?.clearSelection()
        workspaceNavigationState.clearCheckoutSelection()
        guard selectedWorktreeId != id || spacesManager.activeSpace?.lastSelectedWorktreeId != id else { return }
        selectedWorktreeId = id
        spacesManager.setLastSelectedWorktree(id)
        scheduleSpacesSave()
        scheduleWorktreeSelectionFollowUp(id: id, includeRemoteStatus: includeRemoteStatus)
    }

    func selectWorktreeFromSidebar(id: String) {
        selectWorktree(id: id)
        scheduleWorktreeSelectionFollowUp(id: id, acknowledgeSidebar: true)
    }

    /// Backs the sidebar's `↓N` badge. The first click pulls without changing
    /// the selection — the badge spins in the sidebar while the fetch + rebase
    /// runs, so the user keeps their current worktree. A second click while
    /// the pull is still in flight selects the worktree instead, matching the
    /// changes tab's behavior of surfacing conflicts/errors in its right pane.
    func pullWorktreeFromSidebar(id: String) {
        guard let worktree = worktree(withId: id) else { return }
        if worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: id)
            || rightPaneStore.activeState(worktreeId: id)?.pullInFlight == true {
            // Second click while a pull is already running (sidebar- or
            // changes-tab-initiated): route to selection instead.
            selectWorktreeFromSidebar(id: id)
            return
        }
        worktreeUpstreamStatusStore.markPullingUpstream(worktreeID: id)
        // Captured before the async pull starts: the project row can be
        // removed while it runs, and a linked worktree's path component is
        // its branch (the template ends in `{branch}`), not the repo name.
        let repoName = projectsManager.projects.first(where: { $0.id == worktree.projectId })?.name
            ?? worktree.path.lastPathComponent
        let pane = rightPaneStore.state(
            for: worktree,
            baseBranch: config.worktrees.baseBranch,
            comparisonMode: config.changes.comparisonMode,
            activates: false
        )
        Task { @MainActor [weak self] in
            defer { self?.worktreeUpstreamStatusStore.clearPullingUpstream(worktreeID: id) }
            // A freshly created pane has not probed its upstream yet, and
            // `pullAwaited()` no-ops until it knows the branch is behind.
            if !pane.showBehindUpstreamChip { await pane.refreshSyncStatus() }
            // Conflict auto-open only when this pull's worktree is the pane
            // the user is actually looking at — either it was already
            // selected, or the second click selected it mid-pull. Evaluated
            // at completion, so a selection made while the rebase runs still
            // opens the conflict like a changes-tab pull would.
            let result = await pane.pullAwaited(autoOpenConflicts: { [weak self] in
                self?.inAppBannerWorktreeID == pane.worktree.id
            })
            // The pull ran without switching the selection, so its outcome
            // would otherwise only surface in the right pane of a worktree
            // the user never selected. `InAppNotificationStack` renders only
            // inside a mounted `CenterPaneView`; when no such pane is on
            // screen (peer session, workspace overview, forest preview,
            // empty state) post a macOS notification instead — its
            // click-through focuses the pulled worktree.
            // Refresh the sidebar badge even when the pull was declined: the
            // sync-status probe above may have found the branch no longer
            // behind (e.g. updated by another Git client), and the stale
            // `↓N` must not stay clickable repeating the no-op.
            guard let self else { return }
            guard let result else {
                await self.refreshMainWorktreeUpstreamStatuses(projectId: worktree.projectId)
                return
            }
            if let bannerWorktreeID = self.inAppBannerWorktreeID {
                switch result {
                case .clean:
                    self.inAppNotifications.post(
                        "Pulled \(worktree.branch) from \(repoName)",
                        severity: .success,
                        worktreeID: bannerWorktreeID
                    )
                case .conflict:
                    self.inAppNotifications.post(
                        "Pull of \(worktree.branch) in \(repoName) hit conflicts",
                        severity: .error,
                        worktreeID: bannerWorktreeID
                    )
                case .error(let message):
                    self.inAppNotifications.post(
                        "Pull of \(worktree.branch) in \(repoName) failed: \(message)",
                        severity: .error,
                        worktreeID: bannerWorktreeID
                    )
                }
            } else {
                switch result {
                case .clean:
                    self.harness.notifications.notifyWorktreePull(
                        body: "Pulled \(worktree.branch) from \(repoName)",
                        projectId: worktree.projectId,
                        worktreeId: worktree.id
                    )
                case .conflict:
                    self.harness.notifications.notifyWorktreePull(
                        body: "Pull of \(worktree.branch) in \(repoName) hit conflicts — click to resolve.",
                        projectId: worktree.projectId,
                        worktreeId: worktree.id
                    )
                case .error(let message):
                    self.harness.notifications.notifyWorktreePull(
                        body: "Pull of \(worktree.branch) in \(repoName) failed: \(message)",
                        projectId: worktree.projectId,
                        worktreeId: worktree.id
                    )
                }
            }
            await self.refreshMainWorktreeUpstreamStatuses(projectId: worktree.projectId)
        }
    }

    private func scheduleWorktreeSelectionFollowUp(
        id: String?, includeRemoteStatus: Bool = true, acknowledgeSidebar: Bool = false
    ) {
        worktreeSelectionFollowUp?.cancel()
        let generation = worktreeSelectionFollowUpGeneration
        worktreeSelectionFollowUp = Task { @MainActor [weak self] in
            // Leave the click handler and initial view update free of metadata
            // work. Coalesce rapid selections before starting any refreshes.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self, !Task.isCancelled, self.selectedWorktreeId == id,
                  self.worktreeSelectionFollowUpGeneration == generation, let id else { return }
            if acknowledgeSidebar {
                self.acknowledgeAttentionSurface(worktreeID: id, target: .remoteWorktree)
            }
            self.refreshGGSidebar()
            guard let resolved = self.projectAndWorktree(withWorktreeId: id) else { return }
            if resolved.project.host == nil {
                guard !resolved.project.isFolder else { return }
                // Once a scan starts, let it finish. Canceling a later selection
                // must not terminate Git processes belonging to that scan.
                let scan = self.worktreeStatusScan
                await Task { await scan([resolved.worktree.path]) }.value
            } else {
                if includeRemoteStatus, !resolved.project.isFolder {
                    self.enqueueRemoteWorktreeStatusRescan(project: resolved.project, worktree: resolved.worktree)
                }
                await self.prepareRemoteAccelerationIfNeeded(for: resolved.project)
            }
        }
    }

    func waitForWorktreeSelectionFollowUp() async {
        await worktreeSelectionFollowUp?.value
    }

    func selectInitialWorktree(id: String?, includeRemoteStatus: Bool = true) {
        selectWorktree(id: id, includeRemoteStatus: includeRemoteStatus)
    }

    func activateWorktreeCenterTab(worktreeId: String, tabId: TabID) {
        nativePeerSessions?.clearSelection()
        if let pending = attentionPendingReviewReveal,
           pending.worktreeID != worktreeId || pending.tabID != tabId {
            attentionPendingReviewReveal = nil
        }
        tabs.activate(worktreeId: worktreeId, tabId: tabId)
        acknowledgeFocusedSessionAttention(worktreeID: worktreeId, tabID: tabId)
        if let checkout = selectedWorkspaceCheckout,
           workspaceMemberWorktreeIDs(checkout).values.contains(worktreeId) {
            tabs.clearActiveTab(owner: .workspaceCheckout(checkout.id, checkout.executionLocation))
        }
    }

    /// Composes checkout-owned session tabs with the repository tabs of the
    /// focused member. Passing no owner preserves the existing worktree-only
    /// center exactly.
    func centerTabComposition(
        focusedWorktreeID: String,
        sharedSessionOwner: SessionOwnerID? = nil
    ) -> CenterTabComposition {
        guard let sharedSessionOwner else {
            return CenterTabComposition(
                worktreeTabs: tabs.tabs(forWorktree: focusedWorktreeID),
                activeWorktreeTabId: tabs.activeTabId(forWorktree: focusedWorktreeID)
            )
        }
        return CenterTabComposition(
            sharedTabs: tabs.tabs(for: sharedSessionOwner),
            focusedMemberTabs: tabs.tabs(forWorktree: focusedWorktreeID),
            activeSharedTabId: tabs.activeTabId(for: sharedSessionOwner),
            activeFocusedMemberTabId: tabs.activeTabId(forWorktree: focusedWorktreeID)
        )
    }

    func loadSessionTabs(owner: SessionOwnerID, restoringActiveTabs: Bool = true) {
        tabs.load(owner: owner, restoringActiveTabs: restoringActiveTabs)
    }

    func archiveSessionTabs(owner: SessionOwnerID) {
        closeSharedTerminalTabs(owner: owner)
        tabs.archive(owner: owner)
    }

    /// Shared checkout sessions are owned by their frozen checkout identity,
    /// not by the member currently driving repository panes. Lifecycle code
    /// calls this when archiving a checkout.
    func stopWorkspaceCheckoutSessions(_ checkout: WorkspaceCheckout) async throws {
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        // Persisted checkout-owned tab records are archived only after live
        // sessions have drained, so unarchive cannot expose stale processes.
        try await terminateTerminalSessionsAndWait(owner: owner)
        terminal.unregisterSessions(owner: owner)
        await disposeACPManagerAndWait(owner: owner)
        archiveSessionTabs(owner: owner)
    }

#if DEBUG
    func persistedWorkspaceCheckoutTerminalSessionsForTesting(_ checkout: WorkspaceCheckout) -> [TerminalSessionIdentity] {
        persistedWorkspaceCheckoutTerminalSessions(checkout)
    }
#endif

    private func persistedWorkspaceCheckoutTerminalSessions(_ checkout: WorkspaceCheckout) -> [TerminalSessionIdentity] {
        persistedTerminalSessions(owner: .workspaceCheckout(checkout.id, checkout.executionLocation))
    }

    /// Kills every terminal process the owner has and waits for the daemon to
    /// confirm, up to a timeout. The registry is authoritative for live
    /// sessions, including a freshly opened terminal whose tab has not been
    /// persisted yet; persisted tabs cover sessions not attached this launch.
    private func terminateTerminalSessionsAndWait(owner: SessionOwnerID) async throws {
        let live = terminal.registry.all
            .filter { $0.owner == owner && $0.zmxSessionName != nil }
            .map { TerminalSessionIdentity(owner: owner, leafId: $0.id) }
        try await terminal.terminateSessionsAndWait(Array(Set(persistedTerminalSessions(owner: owner) + live)), timeout: 5)
    }

    private func persistedTerminalSessions(owner: SessionOwnerID) -> [TerminalSessionIdentity] {
        tabs.tabs(for: owner).flatMap { tab -> [TerminalSessionIdentity] in
            guard case .terminal(let state) = tab else { return [] }
            return state.root.leaves().map { TerminalSessionIdentity(owner: owner, leafId: $0.id) }
        }
    }

    /// Opens a terminal in the checkout root with the startup script frozen
    /// into the checkout snapshot. Repository Focus is deliberately absent
    /// from this API.
    @discardableResult
    func openWorkspaceCheckoutTerminalTab(_ checkout: WorkspaceCheckout) async throws -> Tab {
        guard let authoritative = await authoritativeCheckoutForWorkspaceTerminal(checkout) else {
            throw NSError(domain: "AppState", code: 3, userInfo: [NSLocalizedDescriptionKey: "The Workspace checkout root is not owned by this checkout."])
        }
        guard await !checkpointTerminalAdmissionDisabledAfterDiscovery(for: authoritative) else {
            throw TerminalLaunchError.checkpointRecoveryRequired
        }
        let context = WorkspaceTerminalContext(
            checkoutID: authoritative.id,
            executionLocation: authoritative.executionLocation,
            rootPath: authoritative.rootPath,
            branch: authoritative.branch,
            manifestPath: URL(fileURLWithPath: authoritative.rootPath)
                .appendingPathComponent(WorkspaceCheckoutManifest.fileName).path,
            startupScript: authoritative.configurationSnapshot?.shared.sessionOpenScript ?? ""
        )
        let session = try terminal.openCheckoutSession(
            context: context,
            cfg: config.terminal,
            theme: themeStore.current
        )
        session.registerForegroundPid(with: harness.detector)
        return tabs.appendTerminal(owner: context.owner, title: "Terminal", sessionId: session.id)
    }

    @discardableResult
    func openWorkspaceCheckoutAgentTerminalTab(
        _ checkout: WorkspaceCheckout,
        focusedMemberWorktree: Worktree,
        agentId: String
    ) async throws -> Tab {
        guard let authoritative = await authoritativeCheckoutForWorkspaceTerminal(checkout),
              let focusedMember = authoritativeCheckoutMember(
                for: focusedMemberWorktree,
                in: authoritative
              ),
              let project = projects.first(where: { $0.id == focusedMember.projectID })
        else {
            throw AgentTerminalLaunchError.projectUnavailable
        }
        guard await !checkpointTerminalAdmissionDisabledAfterDiscovery(for: authoritative) else {
            throw TerminalLaunchError.checkpointRecoveryRequired
        }
        let launchRoot = URL(fileURLWithPath: authoritative.rootPath)
        let launchTarget = authoritative.executionLocation.agentExecutionTarget
        if case .ssh = launchTarget {
            await loadAgentAvailability(
                worktreePath: launchRoot,
                executionTarget: launchTarget
            )
        }
        guard let agent = availableAgent(
            id: agentId,
            worktreePath: launchRoot,
            executionTarget: launchTarget
        ), agent.supportsTerminal else {
            throw AgentTerminalLaunchError.agentUnavailable
        }
        if agent.id == AgentKind.copilot.rawValue, project.host == nil {
            try CopilotInstaller(projectRootURL: focusedMemberWorktree.path).install()
        }
        let baseContext = workspaceTerminalContext(for: authoritative)
        let context = WorkspaceTerminalContext(
            checkoutID: authoritative.id,
            executionLocation: authoritative.executionLocation,
            rootPath: authoritative.rootPath,
            branch: authoritative.branch,
            manifestPath: baseContext.manifestPath,
            startupScript: [
                baseContext.startupScript,
                workspaceCheckoutAgentStartupCommand(for: agent, project: project, checkout: authoritative),
            ].filter { !$0.isEmpty }.joined(separator: "\n")
        )
        let session = try terminal.openCheckoutSession(
            context: context,
            cfg: config.terminal,
            theme: themeStore.current
        )
        session.registerForegroundPid(with: harness.detector)
        return tabs.appendTerminal(owner: context.owner, title: agent.displayName, sessionId: session.id)
    }

    /// Checkout-owned counterpart of `splitFocusedPane(worktreeId:axis:)`.
    /// It carries the frozen checkout context through the entire operation so
    /// a member focus cannot change the new shell's owner or starting cwd.
    func splitFocusedPane(checkout: WorkspaceCheckout, axis: SplitAxis) {
        Task { @MainActor in
            await splitFocusedPaneAfterCheckoutValidation(checkout: checkout, axis: axis)
        }
    }

    private func splitFocusedPaneAfterCheckoutValidation(checkout: WorkspaceCheckout, axis: SplitAxis) async {
        guard let authoritative = await authoritativeCheckoutForWorkspaceTerminal(checkout) else { return }
        let context = workspaceTerminalContext(for: authoritative)
        let owner = context.owner
        guard let tabID = tabs.activeTabId(for: owner),
              let tab = tabs.tabs(for: owner).first(where: { $0.id == tabID }),
              case .terminal(let state) = tab,
              let focused = state.root.find(leafId: state.focusedLeafId)?.leaf,
              let session = terminal.registry.session(for: focused.id)
        else { return }

        let currentCwd = session.surface.currentWorkingDirectory
        let restoredCwd = await validatedWorkspaceCheckoutRestorationCwd(
            savedPath: currentCwd?.path ?? focused.lastCwd,
            context: context,
            savedLocation: currentCwd == nil ? focused.lastCwdLocation : context.executionLocation
        )
        let cwd = restoredCwd ?? URL(fileURLWithPath: context.rootPath)
        do {
            let leafID = UUID().uuidString
            let newSession = try terminal.openCheckoutSession(
                context: context,
                cfg: config.terminal,
                theme: themeStore.current,
                forcedCwd: cwd,
                forcedCwdLocation: context.executionLocation,
                remoteCwdAlreadyValidated: restoredCwd != nil,
                leafId: leafID
            )
            newSession.registerForegroundPid(with: harness.detector)
            _ = tabs.splitFocusedLeaf(
                owner: owner,
                tabId: tabID,
                axis: axis,
                newLeafId: leafID,
                newSessionId: leafID,
                newLeafCwdLocation: context.executionLocation
            )
        } catch {
            AlasGhostty.logger.error("splitFocusedPane checkout failed: \(String(describing: error), privacy: .public)")
        }
    }

    func splitFocusedPane(worktreeId: String, sharedSessionOwner: SessionOwnerID?, axis: SplitAxis) {
        if let checkout = activeSharedCheckoutTerminal(worktreeId: worktreeId, owner: sharedSessionOwner) {
            splitFocusedPane(checkout: checkout, axis: axis)
            return
        }
        splitFocusedPane(worktreeId: worktreeId, axis: axis)
    }

    private func workspaceTerminalContext(for checkout: WorkspaceCheckout) -> WorkspaceTerminalContext {
        WorkspaceTerminalContext(
            checkoutID: checkout.id,
            executionLocation: checkout.executionLocation,
            rootPath: checkout.rootPath,
            branch: checkout.branch,
            manifestPath: URL(fileURLWithPath: checkout.rootPath).appendingPathComponent(WorkspaceCheckoutManifest.fileName).path,
            startupScript: checkout.configurationSnapshot?.shared.sessionOpenScript ?? ""
        )
    }

    private func workspaceCheckoutManifestMatches(_ checkout: WorkspaceCheckout) async -> Bool {
        let manifestPath = URL(fileURLWithPath: checkout.rootPath)
            .appendingPathComponent(WorkspaceCheckoutManifest.fileName).path
        switch checkout.executionLocation.normalized {
        case .local:
            let manifestURL = URL(fileURLWithPath: manifestPath)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(WorkspaceCheckoutManifest.self, from: data)
            else { return false }
            return manifest.checkoutID == checkout.id
                && Self.canonicalWorktreePath(manifest.rootPath) == Self.canonicalWorktreePath(checkout.rootPath)
        case .ssh(let host):
            let expectedCheckoutID = "\"checkoutID\":\"\(checkout.id.uuidString)\""
            let expectedRootPath = WorkspaceCheckoutManifest.jsonStringNeedle(key: "rootPath", value: checkout.rootPath)
            let command = """
            test -s \(SSHCommand.shellQuote(manifestPath)) \
            && grep -F \(SSHCommand.shellQuote(expectedCheckoutID)) \(SSHCommand.shellQuote(manifestPath)) >/dev/null \
            && grep -F \(SSHCommand.shellQuote(expectedRootPath)) \(SSHCommand.shellQuote(manifestPath)) >/dev/null
            """
            guard let result = try? await workspaceRemoteTransport.run(host: host, command: command) else { return false }
            return result.exitCode == 0
        }
    }

    private func validatedWorkspaceCheckoutRestorationCwd(
        savedPath: String?,
        context: WorkspaceTerminalContext,
        savedLocation: ExecutionLocation?
    ) async -> URL? {
        guard savedLocation?.normalized == context.executionLocation.normalized,
              let savedPath,
              !savedPath.isEmpty
        else { return nil }
        switch context.executionLocation.normalized {
        case .local:
            return TerminalService.checkoutRestorationCwd(
                savedPath: savedPath,
                context: context,
                savedLocation: savedLocation
            )
        case .ssh(let host):
            let command = Self.remoteCheckoutCwdContainmentCommand(
                rootPath: context.rootPath,
                savedPath: savedPath
            )
            guard let result = try? await RemoteExec.run(
                host: host,
                cwd: nil,
                command: command,
                timeout: 10
            ) else { return nil }
            return result.exitCode == 0 ? URL(fileURLWithPath: savedPath) : nil
        }
    }

    nonisolated static func remoteCheckoutCwdContainmentCommand(rootPath: String, savedPath: String) -> String {
        """
        resolve_dir() {
          [ -d "$1" ] || exit 2
          (cd "$1" 2>/dev/null && pwd -P) || exit 2
        }
        root_resolved=$(resolve_dir \(SSHCommand.shellQuote(rootPath))) || exit 2
        candidate_resolved=$(resolve_dir \(SSHCommand.shellQuote(savedPath))) || exit 2
        case "$candidate_resolved" in
          "$root_resolved"|"$root_resolved"/*) exit 0 ;;
          *) exit 1 ;;
        esac
        """
    }

    private func authoritativeCheckoutForWorkspaceTerminal(_ checkout: WorkspaceCheckout) async -> WorkspaceCheckout? {
        guard let authoritative = await workspaceStore.checkout(id: checkout.id),
              authoritative.executionLocation.normalized == checkout.executionLocation.normalized,
              authoritative.archivedAt == nil,
              authoritative.operation == .idle,
              await workspaceCheckoutManifestMatches(authoritative)
        else { return nil }
        return authoritative
    }

    func mcpServersForACPToolbar(worktree: Worktree, owner: SessionOwnerID?) -> [ProjectMCPServer] {
        if let owner,
           case .workspaceCheckout(let checkoutID, _) = owner,
           let checkout = workspacesManager.checkout(id: checkoutID) {
            return workspaceFrozenMCPServers(for: checkout)
        }
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return [] }
        // The stored attachment fingerprint includes approved repo-defined
        // servers, so the staleness comparison must feed the same merged list
        // back in - otherwise approving a pending repo server never marks the
        // session stale. Remote projects keep today's behavior.
        guard project.host == nil,
              let repo = repoConfig(worktreeRoot: worktree.path) else {
            return project.mcpServers
        }
        return RepoMCPResolver.merge(
            appServers: project.mcpServers,
            repoServers: repo.mcpServers,
            disabledNames: Set(project.disabledRepoMCPServers),
            trust: project.repoMCPTrust
        ).active
    }

    private func currentWorkspaceCheckoutSnapshot(_ checkout: WorkspaceCheckout) -> WorkspaceCheckout {
        workspacesManager.checkout(id: checkout.id) ?? checkout
    }

    private func workspaceFrozenMCPAttachments(for checkout: WorkspaceCheckout) -> (descriptors: [WorkspaceMCPServerDescriptor], unavailableDescriptorIDs: Set<String>)? {
        guard let frozenConfiguration = checkout.configurationSnapshot else { return nil }
        let unavailableMemberIDs = Set(checkout.members.filter { $0.availability != .available }.map(\.workspaceMemberID.uuidString))
        let descriptors = frozenConfiguration.members.values.flatMap(\.mcpServers)
        let unavailableDescriptors = Set(descriptors.compactMap { descriptor in
            unavailableMemberIDs.contains(where: { descriptor.id.hasPrefix($0 + ":") }) ? descriptor.id : nil
        })
        return (descriptors, unavailableDescriptors)
    }

    private func workspaceFrozenMCPServers(for checkout: WorkspaceCheckout) -> [ProjectMCPServer] {
        guard let descriptors = workspaceFrozenMCPAttachments(for: checkout)?.descriptors else { return [] }
        return MCPAttachmentPlanner.normalizedFrozenServerDescriptors(for: descriptors)
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            .map(\.server)
    }

    private func authoritativeCheckoutMember(
        for worktree: Worktree,
        in checkout: WorkspaceCheckout
    ) -> WorkspaceCheckoutMember? {
        let worktreePath = Self.canonicalWorktreePath(worktree.path.path)
        return checkout.members.first { member in
            guard member.availability == .available,
                  member.projectID == worktree.projectId,
                  Self.canonicalWorktreePath(checkout.inAppWorktreePath(member.worktreePath)) == worktreePath
            else { return false }
            if let plannedDestination = member.plan?.destinationPath {
                return Self.canonicalWorktreePath(checkout.inAppWorktreePath(plannedDestination)) == worktreePath
            }
            return true
        }
    }

    func workspaceCoordinator() -> WorkspaceCheckoutCoordinator {
        core.workspaceCoordinator()
    }

    /// Definition changes are intentionally independent of checkout snapshots:
    /// they only determine future creation requests.
    func saveWorkspaceDefinition(_ workspace: Workspace) async throws {
        guard workspacesManager.canMutate else {
            throw WorkspaceStoreError.recoveryRequired
        }
        // Make sidebar placement visible first. If its legacy Spaces write
        // fails, restore the in-memory layout and do not create an otherwise
        // invisible durable Workspace definition.
        let originalSpacesFile = spacesManager.file
        let activeID = spacesManager.activeSpaceId
        let space = spacesManager.space(id: activeID)
        let current = space?.members ?? space?.projectIds.map(SpaceMemberReference.project) ?? []
        let needsPlacement = !current.contains(.workspace(workspace.id))
        if needsPlacement {
            spacesManager.setTypedMembers(current + [.workspace(workspace.id)], forSpace: activeID)
            guard writeSpaces() else {
                spacesManager.replace(file: originalSpacesFile)
                throw WorkspaceDefinitionSaveError.spacePlacementFailed
            }
        }
        do {
            try await workspaceStore.mutate { state in
                if let index = state.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                    state.workspaces[index] = workspace
                } else {
                    state.workspaces.append(workspace)
                }
            }
        } catch {
            if needsPlacement {
                spacesManager.replace(file: originalSpacesFile)
                do {
                    try store.write(originalSpacesFile, to: Paths.spacesFile)
                    enqueueWorkspaceSpaceCheckpoint(afterWriting: originalSpacesFile)
                } catch {
                    persistenceErrorHandler("Spaces Save Failed", error.localizedDescription)
                    throw WorkspaceDefinitionSaveError.spacePlacementRollbackFailed
                }
            }
            throw WorkspaceDefinitionSaveError.workspacePersistenceFailed
        }
        await workspacesManager.refreshCheckoutSnapshots()
    }

    /// `requireNoCheckouts` closes the gap a re-scanning caller (like
    /// `deleteWorkspaceDefinitionAndCheckouts`) still has after its last scan:
    /// a checkout finishing creation between that scan and this call would
    /// otherwise get silently detached into Former Workspace here. The check
    /// runs inside the same atomic store mutation that removes the
    /// definition, against the live store rather than a cache, so nothing
    /// can land in between the check and the removal.
    func deleteWorkspaceDefinition(id workspaceID: UUID, requireNoCheckouts: Bool = false) async throws {
        guard workspacesManager.canMutate else {
            throw WorkspaceStoreError.recoveryRequired
        }
        let originalSpacesFile = spacesManager.file
        var stagedSpacesFile = originalSpacesFile
        var changedSpaces = false
        for index in stagedSpacesFile.spaces.indices {
            guard let members = stagedSpacesFile.spaces[index].members else { continue }
            let filtered = members.filter { reference in
                guard case .workspace(let id) = reference else { return true }
                return id != workspaceID
            }
            guard filtered != members else { continue }
            stagedSpacesFile.spaces[index].members = filtered
            stagedSpacesFile.spaces[index].projectIds = filtered.compactMap { reference in
                guard case .project(let id) = reference else { return nil }
                return id
            }
            changedSpaces = true
        }
        if changedSpaces {
            spacesManager.replace(file: stagedSpacesFile)
            guard writeSpaces() else {
                spacesManager.replace(file: originalSpacesFile)
                throw WorkspaceDefinitionSaveError.spacePlacementFailed
            }
        }
        do {
            try await workspaceStore.mutate { state in
                guard state.workspaces.contains(where: { $0.id == workspaceID }) else {
                    throw WorkspaceCheckoutCoordinatorError.checkoutMissing
                }
                if requireNoCheckouts, state.checkouts.contains(where: { $0.workspaceID == workspaceID }) {
                    throw WorkspaceDefinitionSaveError.checkoutsNotFullyRemoved
                }
                state.workspaces.removeAll { $0.id == workspaceID }
                for index in state.checkouts.indices where state.checkouts[index].workspaceID == workspaceID {
                    state.checkouts[index].workspaceID = nil
                }
            }
        } catch {
            if changedSpaces {
                spacesManager.replace(file: originalSpacesFile)
                do {
                    try store.write(originalSpacesFile, to: Paths.spacesFile)
                    enqueueWorkspaceSpaceCheckpoint(afterWriting: originalSpacesFile)
                } catch {
                    persistenceErrorHandler("Spaces Save Failed", error.localizedDescription)
                    throw WorkspaceDefinitionSaveError.spacePlacementRollbackFailed
                }
            }
            // The atomic requireNoCheckouts guard's refusal is the one error
            // here actionable by the user (something still needs deleting),
            // not a storage failure — preserve it through the rollback
            // rather than flattening it into the generic case below.
            if case WorkspaceDefinitionSaveError.checkoutsNotFullyRemoved = error {
                throw error
            }
            throw WorkspaceDefinitionSaveError.workspacePersistenceFailed
        }
        await workspacesManager.refreshCheckoutSnapshots()
        workspaceNavigationState.removeWorkspace(workspaceID)
    }

    /// Deletes every checkout still owned by this Workspace before dropping
    /// the definition. Stops at the first checkout that cannot be fully
    /// removed (busy, a failed member, or leftovers needing acknowledgement)
    /// and leaves both the definition and the remaining checkouts in place
    /// rather than orphaning the rest into Former Workspace.
    func deleteWorkspaceDefinitionAndCheckouts(id workspaceID: UUID) async throws {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        // Re-scan after every pass rather than snapshotting the checkout list
        // once: a checkout can be persisted under this Workspace while an
        // earlier one is still being deleted (an already-open creation dialog
        // completing mid-loop). Without this, `deleteWorkspaceDefinition`
        // below would silently detach that new checkout into Former
        // Workspace instead of it being part of "delete everything".
        var processedCheckoutIDs = Set<UUID>()
        while true {
            await workspacesManager.refreshCheckoutSnapshots()
            let pending = workspacesManager.checkouts
                .filter { $0.workspaceID == workspaceID && !processedCheckoutIDs.contains($0.id) }
                .map(\.id)
            guard !pending.isEmpty else { break }
            for checkoutID in pending {
                // Mirrors the git-risk path's existing safety: a checkout
                // with unconfirmed risks (dirty/locked members, or live
                // sessions that would silently close) refuses rather than
                // proceeding without ever showing them, exactly as
                // deleteAndForgetWorkspaceCheckout already does for git
                // risks via confirmingRisks — this closes the gap for
                // session risks, which forget() has no confirmingRisks gate
                // for at all.
                //
                // An archived checkout is refused here without ever calling
                // workspaceCheckoutDeletionConfirmation: that call unarchives
                // as prep for an imminent deletion, which is fine when the
                // caller goes on to actually delete, but this refusal path
                // does not — restoring the archive afterward isn't an option
                // either, since the only way to re-archive goes through the
                // coordinator's archive(), which stops live sessions as a
                // side effect and would defeat this very fix. An archived
                // checkout needs the interactive flow first.
                guard workspacesManager.checkout(id: checkoutID)?.archivedAt == nil else {
                    throw WorkspaceDefinitionSaveError.checkoutsNotFullyRemoved
                }
                let confirmation = try await workspaceCheckoutDeletionConfirmation(checkoutID: checkoutID)
                guard !confirmation.requiresConfirmation else {
                    throw WorkspaceDefinitionSaveError.checkoutsNotFullyRemoved
                }
                let outcome = try await deleteAndForgetWorkspaceCheckout(id: checkoutID)
                guard outcome == .forgotten else {
                    throw WorkspaceDefinitionSaveError.checkoutsNotFullyRemoved
                }
                processedCheckoutIDs.insert(checkoutID)
            }
        }
        try await deleteWorkspaceDefinition(id: workspaceID, requireNoCheckouts: true)
    }

    func preflightWorkspaceCheckout(_ request: WorkspaceCheckoutRequest) async -> WorkspaceCheckoutPreflightResult {
        await WorkspaceCheckoutPreflight(projects: projects).prepare(request)
    }

    /// The coordinator persists the frozen plan before returning. Selection is
    /// therefore never optimistic before durability is established.
    func createWorkspaceCheckout(workspace: Workspace, plan: FrozenWorkspaceCheckoutPlan) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else {
            throw WorkspaceStoreError.recoveryRequired
        }
        let coordinator = workspaceCoordinator()
        let checkout: WorkspaceCheckout
        do {
            checkout = try await coordinator.createPersisted(
                workspace: workspace,
                plan: plan,
                configurationSnapshot: workspaceConfigurationSnapshot(for: workspace, plan: plan)
            )
        } catch {
            await workspacesManager.refreshCheckoutSnapshots(reconciling: plan.checkoutID)
            throw error
        }
        await workspacesManager.refreshCheckoutSnapshots(reconciling: plan.checkoutID)
        guard workspacesManager.canMutate else {
            return try await coordinator.stopPendingCreationBeforeStart(checkoutID: checkout.id)
        }
        selectWorkspaceCheckout(id: checkout.id)
        await coordinator.beginCreation(checkoutID: checkout.id)
        Task { @MainActor [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            await coordinator.awaitCreationCompletion(checkoutID: checkout.id)
            await self.applyWorkspaceCheckoutCreationLaunchPreference(checkoutID: checkout.id)
        }
        return checkout
    }

    private func applyWorkspaceCheckoutCreationLaunchPreference(checkoutID: UUID) async {
        await workspacesManager.refreshCheckoutSnapshots(reconciling: checkoutID)
        guard let checkout = workspacesManager.checkout(id: checkoutID),
              checkout.archivedAt == nil,
              checkout.operation == .idle,
              checkout.members.allSatisfy({ $0.checkpoint == .setupComplete }),
              let preference = checkout.configurationSnapshot?.shared.creationLaunchPreference,
              preference.openAfterCreate == true
        else { return }

        await refreshWorkspaceCheckoutMemberProjects(checkout)
        await workspacesManager.refreshCheckoutSnapshots(reconciling: checkoutID)
        selectWorkspaceCheckout(id: checkout.id)
        switch preference.launcherMode ?? .terminal {
        case .terminal:
            if let agentID = preference.agentID,
               agent(id: agentID) != nil,
               let worktreeID = selectedWorktreeId,
               let worktree = worktree(withId: worktreeID) {
                do {
                    _ = try await openWorkspaceCheckoutAgentTerminalTab(
                        checkout,
                        focusedMemberWorktree: worktree,
                        agentId: agentID
                    )
                } catch {
                    _ = try? await openWorkspaceCheckoutTerminalTab(checkout)
                }
            } else {
                _ = try? await openWorkspaceCheckoutTerminalTab(checkout)
            }
        case .acp:
            guard let agentID = preference.agentID else { return }
            let checkoutRoot = URL(fileURLWithPath: checkout.rootPath)
            let target = checkout.executionLocation.agentExecutionTarget
            if case .ssh = target {
                await loadAgentAvailability(worktreePath: checkoutRoot, executionTarget: target)
            }
            guard availableAgent(
                id: agentID,
                worktreePath: checkoutRoot,
                executionTarget: target
            ) != nil else {
                return
            }
            _ = await openWorkspaceCheckoutACPSession(checkout: checkout, agentID: agentID)
        }
    }

    private func refreshWorkspaceCheckoutMemberProjects(_ checkout: WorkspaceCheckout) async {
        var refreshed = Set<String>()
        for member in checkout.members where !refreshed.contains(member.projectID) {
            refreshed.insert(member.projectID)
            _ = try? await refreshProjectWorktrees(projectId: member.projectID)
        }
    }

    private func workspaceConfigurationSnapshot(
        for workspace: Workspace,
        plan: FrozenWorkspaceCheckoutPlan
    ) -> WorkspaceCheckoutConfigurationSnapshot {
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let members = plan.members.compactMap { planned -> WorkspaceConfigurationResolver.MemberInput? in
            guard let project = projectsByID[planned.projectID] else { return nil }
            return .init(
                id: planned.workspaceMemberID,
                project: project,
                checkoutRoot: plan.rootPath,
                worktreePath: planned.destinationPath
            )
        }
        let enabledAgentIDs: Set<String> = switch plan.executionLocation.normalized {
        case .local:
            Set(agentRegistry.enabled().map(\.id))
        case .ssh:
            Set(AgentConfiguredCatalog.enabled(
                builtinState: config.agents.builtinState,
                customs: config.agents.userAgents
            ).filter(\.canRunOnRemoteHost).map(\.id))
        }
        return WorkspaceConfigurationResolver.resolve(.init(
            globalTerminal: config.terminal,
            globalLaunchPreference: .init(
                openAfterCreate: true,
                launcherMode: config.agents.defaultLauncherMode,
                agentID: config.agents.worktreeAutoLaunch.agentId,
                useBypassPermissions: config.agents.worktreeAutoLaunch.useBypassPermissions
            ),
            workspaceConfiguration: workspace.configuration,
            members: members,
            availableLauncherModes: Set(AppConfig.LauncherMode.allCases),
            enabledAgentIDs: enabledAgentIDs
        ))
    }

    func archiveWorkspaceCheckout(id: UUID) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        let wasSelected = workspaceNavigationState.selectedCheckoutID == id
        let checkout = try await workspaceCoordinator().archive(checkoutID: id)
        await workspacesManager.refreshCheckoutSnapshots()
        workspaceNavigationState.removeCheckout(id)
        if wasSelected {
            selectedWorktreeId = nil
        }
        return checkout
    }

    func unarchiveWorkspaceCheckout(id: UUID) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        let checkout = try await unarchiveWorkspaceCheckoutUnderProjectMutationGate(id: id)
        _ = await restoreWorkspaceCheckoutACPSessions(checkout)
        return checkout
    }

    /// The coordinator takes the member projects' mutation gates and refuses
    /// while a member worktree is held by another operation.
    private func unarchiveWorkspaceCheckoutUnderProjectMutationGate(id: UUID) async throws -> WorkspaceCheckout {
        try await core.unarchiveWorkspaceCheckout(id: id) {
            await self.workspacesManager.refreshCheckoutSnapshots()
        }
    }

    func stopWorkspaceCheckoutAfterCurrentOperations(id: UUID) async throws {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        try await workspaceCoordinator().stopAfterCurrentOperations(checkoutID: id)
        await workspacesManager.refreshCheckoutSnapshots()
    }

    func resumeWorkspaceCheckoutCreation(id: UUID) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        let checkout = try await workspaceCoordinator().resumeCreation(checkoutID: id)
        await workspacesManager.refreshCheckoutSnapshots()
        selectWorkspaceCheckout(id: checkout.id)
        return checkout
    }

    func resumeWorkspaceCheckoutMemberCreation(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        let checkout = try await workspaceCoordinator().resumeCreation(checkoutID: checkoutID, memberID: memberID)
        await workspacesManager.refreshCheckoutSnapshots()
        selectWorkspaceCheckout(id: checkout.id)
        focusWorkspaceCheckoutMember(id: memberID)
        return checkout
    }

    func retryWorkspaceCheckoutSetup(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        let checkout = try await workspaceCoordinator().retrySetup(checkoutID: checkoutID, memberID: memberID)
        await workspacesManager.refreshCheckoutSnapshots()
        selectWorkspaceCheckout(id: checkout.id)
        return checkout
    }

    func workspaceRepairPlan(checkoutID: UUID, memberID: UUID) throws -> WorkspaceRepairPlanModel {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        guard let checkout = workspacesManager.checkout(id: checkoutID),
              let member = checkout.members.first(where: { $0.id == memberID })
        else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
        var candidatesByPath: [String: WorkspaceRepairCandidate] = [:]
        let worktrees = projects.flatMap { projectsManager.worktrees(projectId: $0.id) }
            .filter { $0.projectId == member.projectID }
        for worktree in worktrees {
            let path = worktree.path.standardizedFileURL.path
            let lineage = worktree.lineageID ?? ""
            candidatesByPath[path] = WorkspaceRepairCandidate(
                path: path,
                lineageID: lineage,
                isExactMatch: isExactWorkspaceRepairCandidate(path: path, lineageID: lineage, member: member)
            )
        }
        if let plan = member.plan {
            let path = URL(fileURLWithPath: plan.destinationPath).standardizedFileURL.path
            candidatesByPath[path] = WorkspaceRepairCandidate(
                path: path,
                lineageID: member.gitLineageID ?? "",
                isExactMatch: candidatesByPath[path]?.isExactMatch == true
            )
        }
        return WorkspaceRepairPlanModel(
            memberName: member.fallbackProjectName,
            candidates: candidatesByPath.values.sorted { $0.path < $1.path }
        )
    }

    func useWorkspaceRepairCandidate(checkoutID: UUID, memberID: UUID, candidate: WorkspaceRepairCandidate) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        let checkout = try await workspaceCoordinator().useExistingVerifiedCandidate(
            checkoutID: checkoutID,
            memberID: memberID,
            candidate: candidate
        )
        await workspacesManager.refreshCheckoutSnapshots()
        selectWorkspaceCheckout(id: checkout.id)
        return checkout
    }

    func deleteWorkspaceCheckoutMember(checkoutID: UUID, memberID: UUID, confirmingRisks: Bool = false) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        // Claimed before the dirty-buffer prompt and save, so nothing new is
        // admitted into the member while it is being removed.
        let claimed = try core.claimWorkspaceMembersForDeletion(
            workspacesManager.checkout(id: checkoutID).flatMap { workspaceMemberWorktrees($0)[memberID] }.map { [$0] } ?? []
        )
        defer { core.releaseWorktreeClaims(claimed) }
        let resolvedWorktree = try await resolveDirtyBuffersBeforeWorkspaceMemberDeletion(checkoutID: checkoutID, memberID: memberID)
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        if let resolvedWorktree {
            try await requireCheckpointWorktreeRemovalAllowedAfterDiscovery(resolvedWorktree)
        }
        let checkout = try await workspaceCoordinator().deleteMember(checkoutID: checkoutID, memberID: memberID, confirmingRisks: confirmingRisks)
        if let resolvedWorktree,
           checkout.members.first(where: { $0.id == memberID })?.availability == .explicitlyDeleted {
            await cleanupDeletedWorkspaceMemberRuntime(resolvedWorktree, claimed: claimed)
        }
        await workspacesManager.refreshCheckoutSnapshots()
        selectWorkspaceCheckout(id: checkout.id)
        return checkout
    }

    private func resolveDirtyBuffersBeforeWorkspaceMemberDeletion(checkoutID: UUID, memberID: UUID) async throws -> Worktree? {
        guard let checkout = workspacesManager.checkout(id: checkoutID),
              let worktree = workspaceMemberWorktrees(checkout)[memberID]
        else { return nil }
        let dirty = dirtyEditorTabIds(worktreeId: worktree.id)
        guard !dirty.isEmpty else { return worktree }
        switch promptForDirtyBuffers(
            action: "Delete",
            branch: worktree.branch,
            dirtyCount: dirty.count,
            onDiskDestructive: true,
            keepBranch: true
        ) {
        case .save:
            try await requireCheckpointWorktreeRemovalAllowedAfterDiscovery(worktree)
            guard await saveDirtyBuffers(in: worktree) else { throw CocoaError(.userCancelled) }
        case .discard:
            return worktree
        case .cancel:
            throw CocoaError(.userCancelled)
        }
        return worktree
    }

    private func workspaceMemberWorktrees(_ checkout: WorkspaceCheckout) -> [UUID: Worktree] {
        let ids = workspaceMemberWorktreeIDs(checkout)
        var resolved: [UUID: Worktree] = [:]
        for member in checkout.members {
            guard let worktreeID = ids[member.id] else { continue }
            let expectedPath = URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath)).standardizedFileURL.path
            guard let worktree = projectsManager.worktrees(projectId: member.projectID).first(where: {
                $0.id == worktreeID
                    && $0.projectId == member.projectID
                    && URL(fileURLWithPath: $0.path.path).standardizedFileURL.path == expectedPath
            }) else { continue }
            resolved[member.id] = worktree
        }
        return resolved
    }

    func workspaceMemberReviewRollupBuilder(for checkout: WorkspaceCheckout) -> MemberReviewRollupBuilder {
        var stacks: [String: GGStack] = [:]
        for member in checkout.members where member.availability == .available {
            guard let worktreeID = workspaceMemberWorktreeIDs(checkout)[member.id],
                  let stack = rightPaneStore.activeState(worktreeId: worktreeID)?.ggStack
            else { continue }
            let qualifiedWorktreeID = WorkspaceReviewSessionIdentity.worktreeID(
                projectID: member.projectID,
                executionLocation: checkout.executionLocation,
                repositoryPath: checkout.inAppWorktreePath(member.worktreePath)
            )
            stacks[qualifiedWorktreeID] = stack
        }
        return MemberReviewRollupBuilder(gg: WorkspaceCachedGGStackReader(stacksByWorktreeID: stacks))
    }

    private func cleanupDeletedWorkspaceMemberRuntime(_ worktree: Worktree, claimed: [(worktree: Worktree, claim: UUID)]) async {
        cleanupWorktreeState(worktreeId: worktree.id)
        removePersistedGGWorktreeMode(projectId: worktree.projectId, worktreeId: worktree.id)
        // The claim outlives the refresh: until then the removed row is still
        // listed and must not admit new work.
        _ = try? await refreshProjectWorktrees(projectId: worktree.projectId)
        // Deleted: finished, not released, so no state it replaced returns
        // for the removed path.
        for (claimedWorktree, claim) in claimed where claimedWorktree.id == worktree.id && claimedWorktree.projectId == worktree.projectId {
            core.finishWorktreeClaim(claim, for: claimedWorktree)
        }
        if selectedWorktreeId == worktree.id {
            selectedWorktreeId = nil
        }
    }

    /// A worktree id is nothing but its own standardized path (`Worktree.makeId`),
    /// so it's always derivable from a member's persisted path without needing
    /// a live, verified `Worktree` — unlike dirty-buffer resolution, runtime
    /// session cleanup doesn't need that verification, only the id tabs would
    /// have been registered under.
    ///
    /// Only meaningful when this checkout actually owns the path: a
    /// snapshot-only member (creation never produced a worktree) or an
    /// already-deleted one (cleanup ownership is reset once its own deletion
    /// completes) has `cleanupOwnership.worktreeCreated == false`, and that
    /// path could since be occupied by something this checkout never
    /// touched — closing tabs or clearing selection there would tear down
    /// an unrelated worktree's runtime state instead of this member's own.
    private static func synthesizedWorktreeIfOwned(
        for member: WorkspaceCheckoutMember,
        in checkout: WorkspaceCheckout
    ) -> Worktree? {
        guard member.cleanupOwnership.worktreeCreated else { return nil }
        let path = URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath))
        return Worktree(
            id: Worktree.makeId(path: path),
            projectId: member.projectID,
            name: member.fallbackProjectName,
            branch: "",
            path: path,
            status: .clean,
            lastActivity: .distantPast
        )
    }

    func deleteWorkspaceCheckoutMemberSnapshot(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceCheckout {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        let checkout = try await workspaceCoordinator().deleteMemberSnapshot(checkoutID: checkoutID, memberID: memberID)
        await workspacesManager.refreshCheckoutSnapshots()
        selectWorkspaceCheckout(id: checkout.id)
        return checkout
    }

    func openWorkspaceReview(_ action: WorkspaceReviewAction) {
        guard workspacesManager.canMutate else { return }
        WorkspaceReviewActionHandler(open: { [weak self] worktreeID, record in
            guard let self else { return }
            let tab = self.tabs.openOrFocusReviewSession(worktreeId: worktreeID, record: record)
            self.activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
            self.selectedWorktreeId = worktreeID
            if let checkoutID = self.workspaceNavigationState.selectedCheckoutID,
               let checkout = self.workspacesManager.checkout(id: checkoutID),
               checkout.members.contains(where: { $0.id == action.memberID }) {
                self.workspaceNavigationState.selectMember(
                    action.memberID,
                    in: checkout,
                    resolvedWorktreeIDs: self.workspaceMemberWorktreeIDs(checkout)
                )
                self.selectedWorktreeId = self.workspaceNavigationState.repositoryFocusWorktreeID
                self.tabs.clearActiveTab(owner: .workspaceCheckout(checkout.id, checkout.executionLocation))
            }
        }).open(action)
    }

    func workspaceMemberDeletionConfirmation(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceLifecycleConfirmationModel {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        let preview = try await workspaceCoordinator().previewMemberDeletion(checkoutID: checkoutID, memberID: memberID)
        var model = WorkspaceLifecycleConfirmationModel.memberDeletion(member: preview.member, preflight: preview.preflight)
        model.risks.append(contentsOf: preview.rootObservation.leftovers)
        return model
    }

    /// Every entry point this preview feeds — the row menu and the details
    /// sheet — leads straight into deletion, so unarchiving here (rather
    /// than leaving it to a later step) is preparing that one action, not a
    /// surprising side effect of a read. The coordinator refuses to touch an
    /// archived checkout at all, so without this the preview itself would
    /// throw before the user ever sees a confirmation.
    func workspaceCheckoutDeletionConfirmation(checkoutID: UUID) async throws -> WorkspaceLifecycleConfirmationModel {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        guard var checkout = workspacesManager.checkout(id: checkoutID) else {
            throw WorkspaceCheckoutCoordinatorError.checkoutMissing
        }
        if checkout.archivedAt != nil {
            checkout = try await unarchiveWorkspaceCheckoutUnderProjectMutationGate(id: checkoutID)
        }
        let resolvedWorktreeIDs = workspaceMemberWorktreeIDs(checkout)
        var risks: [String] = []
        var requiresForce = false
        for member in checkout.members where member.availability != .explicitlyDeleted {
            let preview: WorkspaceMemberDeletionPreview
            do {
                preview = try await workspaceCoordinator().previewMemberDeletion(checkoutID: checkoutID, memberID: member.id)
            } catch WorkspaceCheckoutCoordinatorError.cleanupUnavailable where member.canUseSnapshotOnlyCheckoutDeletion {
                continue
            }
            var model = WorkspaceLifecycleConfirmationModel.memberDeletion(member: preview.member, preflight: preview.preflight)
            model.risks.append(contentsOf: preview.rootObservation.leftovers)
            requiresForce = requiresForce || preview.preflight.requiresForce
            risks.append(contentsOf: model.risks.map { "\(member.fallbackProjectName): \($0)" })
            // Mirrors the deletion path's own fallback: a member that's
            // `.missing` right now (stale reconciliation) is skipped by the
            // availability-gated resolution above, but deletion still
            // synthesizes its path-derived id and closes whatever sessions
            // are registered under it — so the risk shown here must count
            // the same sessions it's about to silently terminate.
            if let worktreeID = resolvedWorktreeIDs[member.id]
                ?? (member.cleanupOwnership.worktreeCreated
                    ? Worktree.makeId(path: URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath)))
                    : nil) {
                let sessionCount = worktreeCleanupSessionIDs(worktreeId: worktreeID).count
                if sessionCount > 0 {
                    risks.append("\(member.fallbackProjectName): \(sessionCount) \(sessionCount == 1 ? "session" : "sessions") will close")
                }
            }
        }
        // A checkout-owned terminal or ACP tab (opened at the checkout root,
        // not tied to any one member) has no worktree to key off, so the
        // per-member loop above never sees it — but `forget` still tears it
        // down, so it belongs in the risk count too.
        let checkoutSessionCount = workspaceCheckoutOwnedSessionIDs(checkout).count
        if checkoutSessionCount > 0 {
            risks.append("\(checkoutSessionCount) checkout \(checkoutSessionCount == 1 ? "session" : "sessions") will close")
        }
        return WorkspaceLifecycleConfirmationModel.checkoutDeletion(risks: risks, requiresForce: requiresForce)
    }

    private func workspaceCheckoutOwnedSessionIDs(_ checkout: WorkspaceCheckout) -> Set<String> {
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let persistedSessionIDs = tabs.tabs(for: owner).flatMap { tab -> [String] in
            switch tab {
            case .terminal(let state): return state.root.leaves().map(\.sessionId)
            case .acpSession(let state): return [state.sessionId]
            default: return []
            }
        }
        // Mirrors `stopWorkspaceCheckoutSessions`'s own two sources: the
        // registry is authoritative for a freshly opened terminal whose tab
        // hasn't been persisted yet, so a risk count built from tabs alone
        // can undercount relative to what teardown actually terminates.
        let liveTerminalSessionIDs = terminal.registry.all
            .filter { $0.owner == owner && $0.zmxSessionName != nil }
            .map(\.id)
        return Set(persistedSessionIDs + liveTerminalSessionIDs)
    }

    func workspaceForgetConfirmation(checkoutID: UUID) throws -> WorkspaceLifecycleConfirmationModel {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        guard let checkout = workspacesManager.checkout(id: checkoutID) else {
            throw WorkspaceCheckoutCoordinatorError.checkoutMissing
        }
        return WorkspaceLifecycleConfirmationModel.forgetCheckout(
            cleanups: checkout.members.compactMap(\.cleanup),
            unverifiedMemberCount: checkout.members.filter { $0.cleanup == nil }.count,
            confirmedPreserveArtifacts: false
        )
    }

    /// "Delete Checkout" now means what it says: remove every member worktree
    /// and drop the record. The record only survives when a member could not
    /// be removed or leftovers need the preserve-artifacts acknowledgement —
    /// see `WorkspaceCheckoutDeletionOutcome`.
    func deleteAndForgetWorkspaceCheckout(
        id: UUID,
        confirmingRisks: Bool = false,
        confirmedPreserveArtifacts: Bool = false
    ) async throws -> WorkspaceCheckoutDeletionOutcome {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        guard let before = workspacesManager.checkout(id: id) else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
        // Archived is a settled state, not a lock: deletion always
        // supersedes it. The coordinator itself refuses to touch an
        // archived checkout, so unarchive first rather than dead-ending.
        if before.archivedAt != nil {
            _ = try await unarchiveWorkspaceCheckoutUnderProjectMutationGate(id: id)
        }
        let activeMembers = spacesManager.activeSpace?.members
            ?? spacesManager.activeSpace?.projectIds.map(SpaceMemberReference.project)
            ?? []
        let ordered = WorkspaceSidebarLayout.visibleCheckoutIDs(
            members: activeMembers,
            workspaces: workspacesManager.workspaces,
            checkouts: workspacesManager.checkouts
        )
        let nearest = WorkspaceCheckoutDetailModel.nearestPeer(afterDeleting: id, orderedCheckoutIDs: ordered)
        // Every member is claimed for the whole deletion, before any prompt.
        let claimed = try core.claimWorkspaceMembersForDeletion(Array(workspaceMemberWorktrees(before).values))
        defer { core.releaseWorktreeClaims(claimed) }
        var resolvedWorktrees: [UUID: Worktree] = [:]
        for member in before.members {
            if let worktree = try await resolveDirtyBuffersBeforeWorkspaceMemberDeletion(checkoutID: id, memberID: member.id) {
                resolvedWorktrees[member.id] = worktree
            }
        }
        // `deleteMember` resets a member's `cleanupOwnership` to unowned once
        // its own deletion succeeds, so the ownership gate below must be
        // read from this pre-deletion snapshot — reading it from whatever
        // member snapshot comes back afterward would make every member this
        // very call just finished deleting look exactly like one that was
        // never owned at all, and its stale sessions would never close.
        let ownershipBeforeDeletion = Dictionary(uniqueKeysWithValues: before.members.map { ($0.id, $0) })
        func worktreeToCleanUp(for member: WorkspaceCheckoutMember) -> Worktree? {
            resolvedWorktrees[member.id] ?? ownershipBeforeDeletion[member.id].flatMap { Self.synthesizedWorktreeIfOwned(for: $0, in: before) }
        }
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        for worktree in resolvedWorktrees.values {
            try await requireCheckpointWorktreeRemovalAllowedAfterDiscovery(worktree)
        }
        let outcome: WorkspaceCheckoutDeletionOutcome
        do {
            outcome = try await workspaceCoordinator().deleteCheckoutAndForget(
                checkoutID: id,
                confirmingRisks: confirmingRisks,
                confirmedPreserveArtifacts: confirmedPreserveArtifacts
            )
        } catch {
            // Member worktrees can already be durably removed even when this
            // later stage (session teardown, root-artifact cleanup) throws —
            // the coordinator commits each member's deletion independently as
            // it goes. Reconcile the runtime and the cached snapshot against
            // whatever actually got persisted before surfacing the error, so
            // tabs and terminals for now-deleted worktrees don't linger.
            await workspacesManager.refreshCheckoutSnapshots()
            if let refreshed = workspacesManager.checkout(id: id) {
                for member in refreshed.members where member.availability == .explicitlyDeleted {
                    if let worktree = worktreeToCleanUp(for: member) {
                        await cleanupDeletedWorkspaceMemberRuntime(worktree, claimed: claimed)
                    }
                }
            }
            throw error
        }
        let removedMembers: [WorkspaceCheckoutMember]
        switch outcome {
        case .forgotten:
            removedMembers = before.members
        case .artifactsNeedConfirmation(let checkout), .retained(let checkout, _):
            removedMembers = checkout.members.filter { $0.availability == .explicitlyDeleted }
        }
        for member in removedMembers {
            // A member already `.missing` before deletion started is never
            // resolved into `resolvedWorktrees` (that resolution only trusts
            // a verified `.available` worktree) but the coordinator still
            // deletes it — and any stale terminal/ACP tabs left over from
            // before it went missing need closing too, keyed by the same
            // deterministic path-derived id those tabs were opened under.
            // Gated to members this checkout actually owned a worktree for
            // *before this call started* (see `ownershipBeforeDeletion`
            // above), so a snapshot-only or already-cleaned-up member never
            // tears down state for whatever unrelated worktree its old path
            // might now hold.
            if let worktree = worktreeToCleanUp(for: member) {
                await cleanupDeletedWorkspaceMemberRuntime(worktree, claimed: claimed)
            }
        }
        await workspacesManager.refreshCheckoutSnapshots()
        switch outcome {
        case .forgotten:
            workspaceNavigationState.removeCheckout(id)
            if let nearest {
                selectWorkspaceCheckout(id: nearest)
            } else {
                selectedWorktreeId = nil
            }
        case .artifactsNeedConfirmation, .retained:
            selectWorkspaceCheckout(id: id)
        }
        return outcome
    }

    private func requireCheckpointWorktreeRemovalAllowedAfterDiscovery(_ worktree: Worktree) async throws {
        guard await !checkpointWorktreeRemovalDisabledAfterDiscovery(worktree) else {
            throw WorkspaceStoreError.checkpointRecoveryBlocksRemoval
        }
    }

    func forgetWorkspaceCheckout(id: UUID, confirmedPreserveArtifacts: Bool = false) async throws {
        guard workspacesManager.canMutate else { throw WorkspaceStoreError.recoveryRequired }
        // Same reasoning as `deleteAndForgetWorkspaceCheckout`: a checkout
        // can be archived after its members were already deleted, and
        // forgetting that record is still a stronger, terminal action than
        // archiving — it must not be blocked by the archived guard.
        if workspacesManager.checkout(id: id)?.archivedAt != nil {
            _ = try await unarchiveWorkspaceCheckoutUnderProjectMutationGate(id: id)
        }
        let activeMembers = spacesManager.activeSpace?.members
            ?? spacesManager.activeSpace?.projectIds.map(SpaceMemberReference.project)
            ?? []
        let ordered = WorkspaceSidebarLayout.visibleCheckoutIDs(
            members: activeMembers,
            workspaces: workspacesManager.workspaces,
            checkouts: workspacesManager.checkouts
        )
        let nearest = WorkspaceCheckoutDetailModel.nearestPeer(afterDeleting: id, orderedCheckoutIDs: ordered)
        try await workspaceCoordinator().forget(checkoutID: id, confirmedPreserveArtifacts: confirmedPreserveArtifacts)
        await workspacesManager.refreshCheckoutSnapshots()
        workspaceNavigationState.removeCheckout(id)
        if let nearest {
            selectWorkspaceCheckout(id: nearest)
        } else {
            selectedWorktreeId = nil
        }
    }

    func activateComposedCenterTab(
        worktreeID: String,
        sharedSessionOwner: SessionOwnerID?,
        tabID: TabID
    ) {
        nativePeerSessions?.clearSelection()
        if let sharedSessionOwner,
           tabs.tabs(for: sharedSessionOwner).contains(where: { $0.id == tabID }) {
            tabs.activate(owner: sharedSessionOwner, tabId: tabID)
            tabs.clearActiveTab(worktreeId: worktreeID)
            acknowledgeFocusedSessionAttention(worktreeID: worktreeID, owner: sharedSessionOwner, tabID: tabID)
        } else {
            tabs.activate(worktreeId: worktreeID, tabId: tabID)
            acknowledgeFocusedSessionAttention(worktreeID: worktreeID, tabID: tabID)
            if let sharedSessionOwner {
                tabs.clearActiveTab(owner: sharedSessionOwner)
            }
        }
    }

    /// The ordinary tab-bar close affordance keeps the existing worktree
    /// close request path, including confirmation and closed-tab history.
    func requestCloseComposedCenterTab(
        worktreeID: String,
        projectId: String? = nil,
        sharedSessionOwner: SessionOwnerID?,
        tabID: TabID
    ) {
        if let sharedSessionOwner,
           tabs.tabs(for: sharedSessionOwner).contains(where: { $0.id == tabID }) {
            requestCloseSharedSessionTab(owner: sharedSessionOwner, tabID: tabID)
        } else {
            requestCloseTab(worktreeId: worktreeID, projectId: projectId, tabId: tabID)
        }
    }

    /// Bulk close actions retain the established bulk worktree lifecycle for
    /// member tabs. Checkout-owned tabs intentionally stay in their owner
    /// bucket and will gain Terminal/ACP teardown when those owners are
    /// generalized in the following slices.
    func closeComposedCenterTabs(
        worktreeID: String,
        projectId: String? = nil,
        sharedSessionOwner: SessionOwnerID?,
        tabIDs: [TabID]
    ) {
        let sharedIDs = Set(sharedSessionOwner.map { owner in
            tabs.tabs(for: owner).map(\.id)
        } ?? [])
        let memberIDs = tabIDs.filter { !sharedIDs.contains($0) }
        if !memberIDs.isEmpty {
            closeCenterTabs(worktreeId: worktreeID, projectId: projectId, tabIds: memberIDs)
        }
        guard let sharedSessionOwner else { return }
        for tabID in tabIDs where sharedIDs.contains(tabID) {
            closeSharedSessionTab(owner: sharedSessionOwner, tabID: tabID)
        }
    }

    private func requestCloseSharedSessionTab(owner: SessionOwnerID, tabID: TabID) {
        guard let tab = tabs.tabs(for: owner).first(where: { $0.id == tabID }) else { return }
        if let prompt = CloseTabConfirmationPolicy.prompt(for: tab, config: config),
           !confirmCloseTab(prompt) {
            return
        }
        closeSharedSessionTab(owner: owner, tabID: tabID)
    }

    private func closeSharedSessionTab(owner: SessionOwnerID, tabID: TabID) {
        closeSharedTerminalLeaves(in: tabID, owner: owner)
        if let tab = tabs.tabs(for: owner).first(where: { $0.id == tabID }),
           case .acpSession(let state) = tab {
            cleanupACPSession(owner: owner, sessionId: state.sessionId)
        }
        tabs.close(owner: owner, tabId: tabID)
    }

    /// Never remove a checkout-owned terminal tab while leaving one of its
    /// shell/zmx sessions alive. This applies to manual close, archive, and
    /// process-exit tab teardown and is independent of Repository Focus.
    private func closeSharedTerminalTabs(owner: SessionOwnerID) {
        for tab in tabs.tabs(for: owner) {
            closeSharedTerminalLeaves(in: tab.id, owner: owner)
        }
    }

    private func closeSharedTerminalLeaves(in tabID: TabID, owner: SessionOwnerID) {
        guard let tab = tabs.tabs(for: owner).first(where: { $0.id == tabID }),
              case .terminal(let state) = tab
        else { return }
        for leaf in state.root.leaves() {
            harness.detector.unregister(sessionId: leaf.id)
            harness.forgetSession(leaf.id)
            terminal.closeSession(id: leaf.id, owner: owner)
        }
    }

    func synchronizeVisibleWorktreeCenterTabIfNeeded(worktreeId: String, activeTabId: TabID?) {
        guard let activeTabId else { return }
        guard tabs.tabs(forWorktree: worktreeId).contains(where: { $0.id == activeTabId }) else { return }
        nativePeerSessions?.clearSelection()
        tabs.activate(worktreeId: worktreeId, tabId: activeTabId)
    }

    func switchToSpace(id: String) -> Bool {
        let previousSpaceId = spacesManager.activeSpaceId
        spacesManager.switchToSpace(id: id)
        guard spacesManager.activeSpaceId != previousSpaceId else { return false }
        let selection = resolvedSelectionForActiveSpace()
        selectWorktree(id: selection)
        scheduleSpacesSave()
        return true
    }

    @discardableResult
    func switchToAdjacentSpace(offset: Int) -> Bool {
        let spaces = spacesManager.spaces
        guard spaces.count > 1,
              let current = spaces.firstIndex(where: { $0.id == spacesManager.activeSpaceId })
        else { return false }
        let next = (current + offset + spaces.count) % spaces.count
        guard next != current else { return false }
        _ = switchToSpace(id: spaces[next].id)
        return true
    }

    @discardableResult
    func switchToSpace(atOneBasedIndex index: Int) -> Bool {
        let zeroBasedIndex = index - 1
        guard spacesManager.spaces.indices.contains(zeroBasedIndex) else { return false }
        return switchToSpace(id: spacesManager.spaces[zeroBasedIndex].id)
    }

    func addSpace(name: String, emoji: String) {
        _ = spacesManager.addSpace(name: name, emoji: emoji)
        saveSpaces()
    }

    func renameSpace(id: String, name: String) {
        let previous = spacesManager.space(id: id)?.name
        spacesManager.renameSpace(id: id, name: name)
        guard spacesManager.space(id: id)?.name != previous else { return }
        saveSpaces()
    }

    func setSpaceEmoji(id: String, emoji: String) {
        let previous = spacesManager.space(id: id)?.emoji
        spacesManager.setEmoji(spaceId: id, emoji: emoji.isEmpty ? SpaceConfig.defaultEmoji : emoji)
        guard spacesManager.space(id: id)?.emoji != previous else { return }
        saveSpaces()
    }

    func updateSpace(id: String, name: String, emoji: String) {
        guard let previous = spacesManager.space(id: id) else { return }
        spacesManager.renameSpace(id: id, name: name)
        spacesManager.setEmoji(spaceId: id, emoji: emoji.isEmpty ? SpaceConfig.defaultEmoji : emoji)
        guard let updated = spacesManager.space(id: id),
              updated.name != previous.name || updated.emoji != previous.emoji
        else { return }
        saveSpaces()
    }

    func setShowSingleSpaceAffordance(_ show: Bool) {
        guard spacesManager.showSingleSpaceAffordance != show else { return }
        spacesManager.setShowSingleSpaceAffordance(show)
        saveSpaces()
    }

    func deleteSpace(id: String) {
        let wasActiveSpace = spacesManager.activeSpaceId == id
        guard spacesManager.deleteSpace(id: id) else { return }
        if wasActiveSpace {
            let fallbackSelection = resolvedSelectionForActiveSpaceForStartup()
            selectWorktree(id: fallbackSelection)
        }
        saveSpaces()
    }

    func toggleProject(projectId: String, inSpace spaceId: String) {
        let wasSelectedProject = selectedWorktreeId.map { selectedId in
            projectsManager.visibleWorktrees(projectId: projectId).contains { $0.id == selectedId }
        } ?? false
        let removedFromActiveSpace = spaceId == spacesManager.activeSpaceId
            && spacesManager.space(id: spaceId)?.projectIds.contains(projectId) == true
        if spacesManager.space(id: spaceId)?.projectIds.contains(projectId) == true {
            guard spacesManager.removeProject(projectId, fromSpace: spaceId) else { return }
        } else {
            guard spacesManager.space(id: spaceId) != nil else { return }
            spacesManager.addProject(projectId, toSpace: spaceId)
            guard spacesManager.space(id: spaceId)?.projectIds.contains(projectId) == true else { return }
        }
        if removedFromActiveSpace, wasSelectedProject {
            selectWorktree(id: resolvedSelectionForActiveSpace())
        }
        saveSpaces()
    }

    func focusGlobalWorktree(id: String, projectId: String) {
        if let containing = spacesManager.containingSpaceId(forProjectId: projectId),
           containing != spacesManager.activeSpaceId {
            spacesManager.switchToSpace(id: containing)
        }
        selectWorktree(id: id)
    }

    /// Optimistically insert a worktree row and run the git operation async.
    /// Returns the optimistic worktree id so the dialog can close immediately.
    @discardableResult
    func createWorktree(
        projectId: String,
        base: String,
        branch: String,
        destination: URL,
        runStartup: Bool,
        launchSurface: WorktreeLaunchSurface,
        ggWorktreeMode: GGWorktreeMode = .inherit,
        issueAttachment: IssueAttachment? = nil,
        destinationAlreadyPrepared: Bool = false,
        namesBranchFromFirstPrompt: Bool = false,
        caller: HostCaller = .app
    ) async -> String {
        guard let project = projects.first(where: { $0.id == projectId }), !project.isFolder else {
            // Should not happen if the dialog validated the project; fail silently.
            return ""
        }
        var request = WorktreeCreateRequest(projectID: projectId, base: base, branch: branch, destination: destination)
        request.destinationAlreadyPrepared = destinationAlreadyPrepared
        request.runsStartupScripts = runStartup
        request.fetchesBaseFirst = config.worktrees.fetchRemoteBeforeCreate
        request.namesBranchFromFirstPrompt = namesBranchFromFirstPrompt
        request.ggWorktreeMode = ggWorktreeMode
        request.issueAttachment = issueAttachment
        request.launchSurface = launchSurface
        request.cancelledHookApprovalFails = true
        let pending: PendingWorktreeCreation
        do {
            pending = try await host.worktrees.beginCreate(request, caller: caller)
        } catch WorktreeCreationRefusal.alreadyListed {
            return ""
        } catch {
            showFileActionError(title: "Create Worktree Failed", message: error.localizedDescription)
            return ""
        }
        let optimistic = pending.worktree
        reconciledCreateFailureCompletionClaims.remove(
            WorktreeOperationKey(projectId: projectId, worktreeId: optimistic.id)
        )
        rightPaneStore.invalidateSnapshot(worktreeId: optimistic.id)
        if launchSurface != .delegated,
           let containing = spacesManager.containingSpaceId(forProjectId: projectId),
           containing != spacesManager.activeSpaceId {
            _ = switchToSpace(id: containing)
        }
        setUnpersistedGGWorktreeMode(
            projectId: projectId,
            worktreeId: optimistic.id,
            mode: ggWorktreeMode
        )
        rightPaneStore.reevaluateGGGate(worktreeId: optimistic.id)
        if launchSurface != .delegated {
            selectWorktree(id: optimistic.id)
        }

        Task { @MainActor in
            let outcome = await host.worktrees.finishCreate(pending)
            switch outcome {
            case .createdButNotSaved(_, let message), .failed(_, unsaved: let message?):
                persistenceErrorHandler("Projects Save Failed", message)
            default:
                break
            }
            switch outcome {
            case .created(let newWorktree), .createdButNotSaved(let newWorktree, _):
                removeUnpersistedGGWorktreeMode(projectId: project.id, worktreeId: newWorktree.id)
                rightPaneStore.reevaluateGGGate(worktreeId: newWorktree.id)
                if launchSurface != .delegated {
                    selectWorktree(id: newWorktree.id)
                }
                do {
                    try await self.launchWorktreeSurface(launchSurface, worktree: newWorktree, project: project)
                } catch {
                    self.markWorktreeLaunchFailed(
                        worktree: newWorktree,
                        error: error,
                        launchSurface: launchSurface
                    )
                }
            case .failed:
                discardUnpersistedGGWorktreeMode(
                    projectId: projectId,
                    worktreeId: optimistic.id,
                    mode: ggWorktreeMode
                )
            case .projectRemoved:
                break
            }
        }
        return optimistic.id
    }

    @MainActor
    static let folderWorktreeCreationMessage = "Folder projects are not git repositories and cannot create worktrees."

    func cliCreateWorktree(origin: Worktree, branch: String, base: String?, caller: HostCaller = .cli) async -> AlasCLIResponse {
        let prepared: PreparedWorktreeCreation
        do {
            prepared = try await host.worktrees.prepareCreate(projectID: origin.projectId, branch: branch, base: base, caller: caller)
        } catch {
            return .error(error.localizedDescription)
        }
        let destination = prepared.request.destination
        let resolvedBase = prepared.request.base
        let shownPath = prepared.shownPath
        let id = await createWorktree(
            projectId: origin.projectId,
            base: resolvedBase,
            branch: branch,
            destination: destination,
            runStartup: true,
            launchSurface: .none,
            destinationAlreadyPrepared: true,
            caller: caller
        )
        guard !id.isEmpty else {
            return .error("A worktree already exists at this path.")
        }
        return .text(["creating \(branch) at \(shownPath)"])
    }

    /// Starts a delegated worktree creation and waits for its reconciled row.
    /// The existing creation path remains the single owner of optimistic UI,
    /// startup, refresh, and failure handling.
    func createWorktreeAndWait(
        projectId: String,
        base: String,
        branch: String,
        destination: URL,
        runStartup: Bool,
        ggWorktreeMode: GGWorktreeMode = .inherit,
        destinationAlreadyPrepared: Bool = false,
        caller: HostCaller = .app
    ) async -> Result<Worktree, WorktreeCreationFailure> {
        let id = await createWorktree(
            projectId: projectId,
            base: base,
            branch: branch,
            destination: destination,
            runStartup: runStartup,
            launchSurface: .delegated,
            ggWorktreeMode: ggWorktreeMode,
            destinationAlreadyPrepared: destinationAlreadyPrepared,
            caller: caller
        )
        guard !id.isEmpty else {
            return .failure(.init(message: "Could not start worktree creation."))
        }
        return await WorktreeCreationCompletion.wait(
            id: id,
            operationState: { self.projectsManager.operationState(forWorktreeId: id, projectId: projectId) },
            worktree: { self.worktree(withId: id) },
            reconcile: { _ = try? await self.refreshProjectWorktrees(projectId: projectId) }
        )
    }

    /// Creates a worktree for delegated ACP work without changing the visible
    /// project/worktree selection. The prepared destination (remote home and
    /// virtual path applied) is recorded through `recordDestination` before
    /// anything is created, so startup recovery can find a checkout created
    /// just before the app stopped.
    func createDelegatedWorktree(
        projectId: String,
        branch: String,
        base: String?,
        recordDestination: @MainActor (URL) async throws -> Void
    ) async -> Result<Worktree, ACPSessionOrchestrationCoordinator.WorktreeCreationError> {
        let prepared: PreparedWorktreeCreation
        do {
            prepared = try await host.worktrees.prepareCreate(projectID: projectId, branch: branch, base: base, caller: .cli)
        } catch {
            return .failure(.init(message: error.localizedDescription))
        }
        let destination = prepared.request.destination
        let selectedBase = prepared.request.base
        do {
            try await recordDestination(destination)
        } catch {
            return .failure(.init(message: "Could not record the worktree destination."))
        }
        let result = await createWorktreeAndWait(
            projectId: projectId,
            base: selectedBase,
            branch: branch,
            destination: destination,
            runStartup: true,
            destinationAlreadyPrepared: true,
            caller: .cli
        )
        switch result {
        case .success(let worktree):
            return .success(worktree)
        case .failure(let error):
            return .failure(.init(message: error.message))
        }
    }

    func agentStartupCommand(for agent: AgentDefinition, project: ProjectConfig) -> String {
        agentStartupCommand(
            for: agent,
            project: project,
            useBypassPermissions: agentBypassPermissionsEnabled(for: project)
        )
    }

    private func workspaceCheckoutAgentStartupCommand(for agent: AgentDefinition, project: ProjectConfig, checkout: WorkspaceCheckout) -> String {
        agentStartupCommand(
            for: agent,
            project: project,
            useBypassPermissions: checkout.configurationSnapshot?.shared.creationLaunchPreference.useBypassPermissions == true
        )
    }

    private func agentStartupCommand(for agent: AgentDefinition, project: ProjectConfig, useBypassPermissions: Bool) -> String {
        let binary = project.host == nil
            ? Self.shellQuote(agent.resolvedBinary)
            : remoteShellBinary(agent.configuredBinary)
        var argv = [binary]
        if let extra = agent.extraTerminalArgs, !extra.isEmpty {
            argv.append(contentsOf: extra)
        }
        if useBypassPermissions,
           let flag = agent.bypassPermissionsFlag {
            argv.append(flag)
        }
        return ([binary] + argv.dropFirst().map(Self.shellQuote))
            .joined(separator: " ")
    }

    private func remoteShellBinary(_ configuredBinary: String) -> String {
        guard configuredBinary.hasPrefix("~/") else {
            return Self.shellQuote(configuredBinary)
        }
        return "\"$HOME\"/\(Self.shellQuote(String(configuredBinary.dropFirst(2))))"
    }

    enum AgentTerminalLaunchError: LocalizedError, Equatable {
        case projectUnavailable
        case agentUnavailable

        var errorDescription: String? {
            switch self {
            case .projectUnavailable:
                return "The selected worktree's project is no longer available."
            case .agentUnavailable:
                return "The selected agent is no longer enabled."
            }
        }
    }

    enum WorktreeAgentStartupError: LocalizedError, Equatable {
        case agentUnavailable

        var errorDescription: String? {
            switch self {
            case .agentUnavailable:
                return "The selected agent is not available for this worktree."
            }
        }
    }

    typealias ACPAuthTerminalLaunchError = AlasCore.ACPAuthTerminalLaunchError

    enum TerminalLaunchError: LocalizedError, Equatable {
        case checkpointRecoveryRequired
        case worktreeOperationInProgress

        var errorDescription: String? {
            switch self {
            case .checkpointRecoveryRequired:
                return "Recover the interrupted checkpoint restore before opening terminals."
            case .worktreeOperationInProgress:
                return "Wait for the current worktree operation to finish before opening terminals."
            }
        }
    }

    @discardableResult
    func openAgentTerminalTab(for worktree: Worktree, agentId: String) throws -> Tab {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw AgentTerminalLaunchError.projectUnavailable
        }
        guard let agent = availableAgent(id: agentId, for: worktree), agent.supportsTerminal else {
            throw AgentTerminalLaunchError.agentUnavailable
        }
        do {
            if agent.id == AgentKind.copilot.rawValue, project.host == nil {
                try CopilotInstaller(projectRootURL: worktree.path).install()
            }
            return try openTerminalTab(
                for: worktree,
                startupScriptSuffix: agentStartupCommand(for: agent, project: project)
            )
        } catch {
            showFileActionError(title: "Launch Agent Failed", message: error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func openAgentTerminalTabPreparingRemoteZmxIfNeeded(for worktree: Worktree, agentId: String) async throws -> Tab {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw AgentTerminalLaunchError.projectUnavailable
        }
        guard let agent = availableAgent(id: agentId, for: worktree), agent.supportsTerminal else {
            throw AgentTerminalLaunchError.agentUnavailable
        }
        do {
            if agent.id == AgentKind.copilot.rawValue, project.host == nil {
                try CopilotInstaller(projectRootURL: worktree.path).install()
            }
            return try await openTerminalTabPreparingRemoteZmxIfNeeded(
                for: worktree,
                startupScriptSuffix: agentStartupCommand(for: agent, project: project)
            )
        } catch {
            showFileActionError(title: "Launch Agent Failed", message: error.localizedDescription)
            throw error
        }
    }

    private func availableAgent(
        id: String,
        for worktree: Worktree,
        remoteHost: String? = nil
    ) -> AgentDefinition? {
        let resolvedRemoteHost = remoteHost ?? projectAndWorktree(withWorktreeId: worktree.id)?.project.host
        return availableAgent(id: id, worktreePath: worktree.path, remoteHost: resolvedRemoteHost)
    }

    private func availableAgent(
        id: String,
        worktreePath: URL,
        remoteHost: String? = nil
    ) -> AgentDefinition? {
        let target = AgentExecutionTarget.resolve(worktreePath: worktreePath, remoteHost: remoteHost)
        return availableAgent(id: id, worktreePath: worktreePath, executionTarget: target)
    }

    private func availableAgent(
        id: String,
        worktreePath: URL,
        executionTarget target: AgentExecutionTarget
    ) -> AgentDefinition? {
        agentAvailability(worktreePath: worktreePath, executionTarget: target)
            .agents
            .first { $0.id == id }
    }

    private func worktreeAgentStartupSuffix(
        agentId: String?,
        worktree: Worktree,
        project: ProjectConfig,
        refreshAvailability: Bool = false
    ) async throws -> String? {
        guard let agentId else { return nil }
        await loadAgentAvailability(for: worktree, force: refreshAvailability, retryFailed: refreshAvailability)
        guard let agent = availableAgent(id: agentId, for: worktree), agent.supportsTerminal else {
            throw WorktreeAgentStartupError.agentUnavailable
        }
        return agentStartupCommand(for: agent, project: project)
    }

    private func validateWorktreeACPAgent(
        agentID: String,
        worktree: Worktree,
        refreshAvailability: Bool = false
    ) async throws {
        await loadAgentAvailability(for: worktree, force: refreshAvailability, retryFailed: refreshAvailability)
        guard availableAgent(id: agentID, for: worktree) != nil else {
            throw WorktreeAgentStartupError.agentUnavailable
        }
    }

    /// Opens whatever `launchSurface` asks for. Returns the terminal tab it
    /// opened, when it opened one, so a caller that has more to say to that
    /// terminal (a scheduled prompt) can find its session. A chat session is
    /// found through its prepared prompt's session id instead.
    @discardableResult
    func launchWorktreeSurface(
        _ launchSurface: WorktreeLaunchSurface,
        worktree: Worktree,
        project: ProjectConfig,
        refreshAvailability: Bool = false
    ) async throws -> Tab? {
        switch launchSurface {
        case .none, .delegated:
            return nil
        case .terminal(let agentId):
            let suffix = try await worktreeAgentStartupSuffix(
                agentId: agentId,
                worktree: worktree,
                project: project,
                refreshAvailability: refreshAvailability
            )
            return try await openTerminalTabPreparingRemoteZmxIfNeeded(
                for: worktree,
                startupScriptSuffix: suffix
            )
        case .acp(let agentId, let preparedPrompt):
            try await validateWorktreeACPAgent(
                agentID: agentId,
                worktree: worktree,
                refreshAvailability: refreshAvailability
            )
            if let preparedPrompt {
                await openPreparedWorktreeACPSession(
                    worktree: worktree,
                    agentID: agentId,
                    preparedPrompt: preparedPrompt
                )
            } else {
                guard let manager = acpManager(for: worktree) else { return nil }
                openNewACPSession(
                    agentID: agentId,
                    owner: manager.owner,
                    projectId: worktree.projectId
                )
            }
            return nil
        }
    }

    func markWorktreeLaunchFailed(
        worktree: Worktree,
        error: Error,
        launchSurface: WorktreeLaunchSurface
    ) {
        core.recordLaunchFailure(worktree, message: error.localizedDescription, launchSurface: launchSurface)
    }

    func retryWorktreeLaunch(_ worktree: Worktree, project: ProjectConfig) async {
        guard case .launchFailed(_, _, let launchSurface) = projectsManager.operationState(
            forWorktreeId: worktree.id,
            projectId: worktree.projectId
        ) else {
            return
        }
        do {
            try await launchWorktreeSurface(
                launchSurface,
                worktree: worktree,
                project: project,
                refreshAvailability: true
            )
            core.clearLaunchFailure(worktree)
        } catch {
            markWorktreeLaunchFailed(
                worktree: worktree,
                error: error,
                launchSurface: launchSurface
            )
        }
    }

    @discardableResult
    func openACPAuthTerminalTab(
        for worktree: Worktree,
        acpSessionId: ACPSession.ID,
        command: ACPAuthTerminalCommand,
        onExit: @escaping () -> Void
    ) throws -> Tab {
        let startupScriptSuffix = try RunScriptCommand.shellCommand(
            command: command.command,
            args: command.args,
            env: command.env,
            exitOnCompletion: true
        )
        let tab = try openTerminalTab(
            for: worktree,
            startupScriptSuffix: startupScriptSuffix,
            includeUserStartupScript: false,
            forceInheritParentEnv: true,
            environmentOverrides: Self.acpAuthTerminalEnvironmentOverrides(extra: command.env),
            environmentRemovals: ACPProcessEnvironment.agentSessionMarkerKeys
        )
        if case .terminal(let terminal) = tab {
            acpAuthTerminalExitHandlers[terminal.root.firstLeaf().sessionId] = (acpSessionId, onExit)
        }
        return tab
    }

    @discardableResult
    func openACPAuthTerminalTabPreparingRemoteZmxIfNeeded(
        for worktree: Worktree,
        acpSessionId: ACPSession.ID,
        command: ACPAuthTerminalCommand,
        onExit: @escaping () -> Void
    ) async throws -> Tab {
        let startupScriptSuffix = try RunScriptCommand.shellCommand(
            command: command.command,
            args: command.args,
            env: command.env,
            exitOnCompletion: true
        )
        let tab = try await openTerminalTabPreparingRemoteZmxIfNeeded(
            for: worktree,
            startupScriptSuffix: startupScriptSuffix,
            includeUserStartupScript: false,
            forceInheritParentEnv: true,
            environmentOverrides: Self.acpAuthTerminalEnvironmentOverrides(extra: command.env),
            environmentRemovals: ACPProcessEnvironment.agentSessionMarkerKeys
        )
        if case .terminal(let terminal) = tab {
            acpAuthTerminalExitHandlers[terminal.root.firstLeaf().sessionId] = (acpSessionId, onExit)
        }
        return tab
    }

    nonisolated private static func acpAuthTerminalEnvironmentOverrides(
        extra: [String: String]
    ) -> [String: String] {
        var overrides = extra
        if let path = ACPProcessEnvironment.augmented()["PATH"] {
            overrides["PATH"] = path
        }
        return overrides
    }

    /// Three-layer resolution against a concrete worktree: an explicit
    /// project override, then the repo's `.alas/config.json` default (local
    /// projects only, and only when the id names an installed, enabled
    /// agent), then the global default. SSH projects never resolve to a
    /// registry install that only exists on this Mac.
    func defaultAgentID(projectId: String, worktreeRoot: URL) -> String? {
        host.sessions.defaultAgent(projectID: projectId, worktreeRoot: worktreeRoot)
    }

    private func agentBypassPermissionsEnabled(for project: ProjectConfig) -> Bool {
        switch project.startupScripts.worktreeAgentMode {
        case .disabled:
            return false
        case .useGlobal:
            return config.agents.worktreeAutoLaunch.useBypassPermissions
        case .overrideGlobal, .appendToGlobal:
            return project.startupScripts.worktreeAgentUseBypassPermissions
        }
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        ShellQuoting.quote(s)
    }

    func removeFailedOptimisticWorktree(id: String, projectId: String) {
        cleanupWorktreeState(worktreeId: id)
        removeUnpersistedGGWorktreeMode(projectId: projectId, worktreeId: id)
        projectsManager.removeGGWorktreeMode(projectId: projectId, worktreeId: id)
        projectsManager.removeOptimisticWorktree(id: id, projectId: projectId)
        saveProjects()
        if selectedWorktreeId == id {
            selectWorktree(id: resolvedSelectionForActiveSpace())
        }
    }

    func addProject(
        path: URL,
        displayName: String,
        icon: ProjectIcon,
        host: String? = nil,
        kind: ProjectKind = .git,
        id: String = UUID().uuidString,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer] = [],
        worktreeBranchTemplate: String? = nil,
        approvedRepoHookHashes: [String] = []
    ) async throws {
        guard !projectsManager.projects.contains(where: { $0.id == id }) else {
            throw ProjectCreationError.projectAlreadyExists
        }

        let project = try await projectsManager.addProject(
            path: path,
            displayName: displayName,
            icon: icon,
            host: host,
            kind: kind,
            id: id,
            startupScripts: startupScripts,
            mcpServers: mcpServers,
            worktreeBranchTemplate: worktreeBranchTemplate,
            approvedRepoHookHashes: approvedRepoHookHashes
        )
        spacesManager.addProject(project.id, toSpace: spacesManager.activeSpaceId)
        guard saveProjects() else {
            spacesManager.removeProjectEverywhere(project.id)
            projectsManager.removeProject(id: project.id)
            throw ProjectCreationError.projectPersistenceFailed
        }
        saveSpaces()
        _ = await refreshAllProjectTopologies()
        if let worktreeId = projectsManager.visibleWorktrees(projectId: project.id).first?.id {
            selectWorktree(id: worktreeId)
        }
        let refreshedProject = projectsManager.projects.first { $0.id == project.id } ?? project
        startProjectGitWatcher(for: refreshedProject)
    }

    func addProject(
        path: URL,
        displayName: String,
        color: String,
        id: String = UUID().uuidString
    ) async throws {
        try await addProject(
            path: path,
            displayName: displayName,
            icon: ProjectIcon.default(color: color),
            id: id
        )
    }

    @discardableResult
    func removeProject(id: String) -> Bool {
        removeProjectResult(id: id) == .removed
    }

    private enum ProjectRemovalResult {
        case removed
        case scheduled
        case cancelled
    }

    @discardableResult
    private func removeProjectResult(id: String) -> ProjectRemovalResult {
        guard let project = projects.first(where: { $0.id == id }) else { return .cancelled }

        let mainId = Worktree.makeId(path: URL(fileURLWithPath: project.path))
        let liveWorktrees = projectsManager.worktrees(projectId: id)
        var candidateIds = Set(liveWorktrees.map(\.id))
        candidateIds.insert(mainId)
        for hidden in project.hiddenWorktreePaths {
            candidateIds.insert(hidden)
        }
        for ordered in project.worktreeOrder {
            candidateIds.insert(ordered)
        }

        tabs.loadAll(worktreeIds: Array(candidateIds))

        let liveById = Dictionary(uniqueKeysWithValues: liveWorktrees.map { ($0.id, $0) })
        let dirtyByWorktree: [(worktree: Worktree, count: Int)] = candidateIds.compactMap { worktreeId in
            let dirty = dirtyEditorTabIds(worktreeId: worktreeId)
            guard !dirty.isEmpty else { return nil }
            if let live = liveById[worktreeId] {
                return (worktree: live, count: dirty.count)
            }
            let path = URL(fileURLWithPath: worktreeId)
            let synthetic = Worktree(
                id: worktreeId,
                projectId: project.id,
                name: path.lastPathComponent,
                branch: path.lastPathComponent,
                path: path,
                status: .clean,
                lastActivity: Date()
            )
            return (worktree: synthetic, count: dirty.count)
        }

        let dirtyTotal = dirtyByWorktree.reduce(0) { $0 + $1.count }

        if dirtyTotal > 0 {
            switch promptForDirtyBuffersOnRemoveProject(
                name: project.name,
                dirtyCount: dirtyTotal
            ) {
            case .save:
                let worktreesToSave = dirtyByWorktree.map(\.worktree)
                Task { @MainActor in
                    for worktree in worktreesToSave {
                        guard await saveDirtyBuffers(in: worktree) else { return }
                    }
                    _ = removeProjectAfterDirtyResolution(id: id, candidateIds: candidateIds)
                }
                return .scheduled
            case .discard:
                break
            case .cancel:
                return .cancelled
            }
        }

        return removeProjectAfterDirtyResolution(id: id, candidateIds: candidateIds) ? .removed : .cancelled
    }

    @discardableResult
    private func removeProjectAfterDirtyResolution(id: String, candidateIds: Set<String>) -> Bool {
        var beforeIds = allWorktreeIds()
        for candidateId in candidateIds {
            beforeIds.insert(candidateId)
        }
        stopProjectGitWatcher(projectId: id)
        unpersistedGGWorktreeModes.removeValue(forKey: id)
        // A directory this project owned goes straight back to a project that
        // lost it, so its id stays live and its tabs and sessions survive.
        let restoredProjectIds = projectsManager.removeProject(id: id)
        spacesManager.removeProjectEverywhere(id)
        runScheduler.pruneSchedules(missingProjectIDs: [id])
        saveProjects()
        saveSpaces()
        let afterIds = allWorktreeIds()
        let removedIds = beforeIds.subtracting(afterIds)
        cleanupMissingWorktreeState(beforeIds: beforeIds, afterIds: afterIds)
        for worktreeId in removedIds {
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId))
            try? FileManager.default.removeItem(at: Paths.buffersDir(forWorktreeId: worktreeId))
        }
        for projectId in restoredProjectIds {
            Task { await refreshProjectTopology(projectId: projectId) }
        }
        return true
    }

    @discardableResult
    func clearAllProjects() -> Int {
        let ids = projects.map(\.id)
        var removed = 0
        for id in ids {
            switch removeProjectResult(id: id) {
            case .removed:
                removed += 1
            case .scheduled:
                continue
            case .cancelled:
                return removed
            }
        }
        return removed
    }

    @discardableResult
    func clearProjectsWithoutWorktrees() async -> Int {
        var staleProjectIds: [String] = []
        for project in projects {
            do {
                try await refreshProjectWorktrees(projectId: project.id)
            } catch {
                guard project.host == nil else { continue }
                let pathSurvives = project.isFolder
                    ? ProjectsManager.isDirectory(project.path)
                    : FileManager.default.fileExists(atPath: project.path)
                guard !pathSurvives else { continue }
                staleProjectIds.append(project.id)
                continue
            }

            // A project whose rows all sit under another project is not empty.
            if projectsManager.worktrees(projectId: project.id).isEmpty,
               projectsManager.worktreeIdConflicts[project.id] == nil {
                staleProjectIds.append(project.id)
            }
        }

        var removed = 0
        for id in staleProjectIds {
            switch removeProjectResult(id: id) {
            case .removed:
                removed += 1
            case .scheduled:
                continue
            case .cancelled:
                return removed
            }
        }
        return removed
    }

    /// Start a ProjectGitWatcher for `project` and wire its callbacks into
    /// the fast (HEAD-only) and slow (topology) refresh paths. Idempotent:
    /// stops any existing watcher for the same project id first.
    func startProjectGitWatcher(for project: ProjectConfig) {
        stopProjectGitWatcher(projectId: project.id)
        // A folder has no git dir to watch and a fixed one-row topology.
        if project.isFolder { return }
        // Added, moved, or watched again after a while: its remotes may be new.
        pluginCodeHostMayHaveChanged(projectId: project.id)
        if project.host != nil {
            let watcher = RemoteProjectGitWatcher(projectPath: URL(fileURLWithPath: project.path))
            watcher.onHeadChanged = { [weak self] updates in
                self?.handleProjectHeadUpdates(projectId: project.id, branchByWorktreePath: updates)
                self?.rescanRemoteWorktreeStatuses(projectId: project.id)
            }
            watcher.onRevisionChanged = { [weak self] in
                self?.handleProjectRevisionChange(projectId: project.id)
                self?.rescanRemoteWorktreeStatuses(projectId: project.id)
                self?.pluginCodeHostMayHaveChanged(projectId: project.id)
            }
            watcher.onTopologyChanged = { [weak self] in
                self?.handleProjectRevisionChange(projectId: project.id)
                self?.handleProjectTopologyChange(projectId: project.id)
                self?.rescanRemoteWorktreeStatuses(projectId: project.id)
            }
            remoteProjectWatchers[project.id] = watcher
            watcher.start()
            rescanRemoteWorktreeStatuses(projectId: project.id)
            return
        }
        let watcher = projectGitWatcherFactory(URL(fileURLWithPath: project.path))
        let projectId = project.id
        watcher.onHeadChanged = { [weak self] map in
            self?.handleProjectHeadUpdates(projectId: projectId, branchByWorktreePath: map)
            self?.rescanLocalWorktreeStatuses(projectId: projectId)
        }
        watcher.onRevisionChanged = { [weak self] in
            // Covers `.git/config`, where remotes live.
            self?.pluginCodeHostMayHaveChanged(projectId: projectId)
            self?.bumpRevisionGenerationForProject(projectId: projectId)
            self?.rescanLocalWorktreeStatuses(projectId: projectId)
            Task { @MainActor [weak self] in
                await self?.refreshMainWorktreeUpstreamStatuses(projectId: projectId)
            }
        }
        watcher.onStackRevisionChanged = { [weak self] in
            self?.handleProjectStackRevisionChange(projectId: projectId)
            self?.rescanLocalWorktreeStatuses(projectId: projectId)
        }
        watcher.onTopologyChanged = { [weak self] in
            self?.handleProjectRevisionChange(projectId: projectId)
            self?.handleProjectTopologyChange(projectId: projectId)
            self?.rescanLocalWorktreeStatuses(projectId: projectId)
        }
        watcher.start()
        projectGitWatchers[projectId] = watcher
    }

    /// Projects that can have worktrees: everything but folder projects.
    var worktreeProjects: [ProjectConfig] { projects.filter { !$0.isFolder } }

    /// Resolved through the owning project: a git project and a folder project
    /// may register the same path.
    func isFolderWorktree(_ worktree: Worktree) -> Bool {
        projectsManager.projects.first { $0.id == worktree.projectId }?.isFolder == true
    }

    /// For call sites that only know a path: true when any folder project owns
    /// it, so a shared path errs toward running no git.
    func isFolderPath(_ path: URL) -> Bool {
        let id = Worktree.makeId(path: path)
        return projectsManager.projects.contains {
            $0.isFolder && Worktree.makeId(path: URL(fileURLWithPath: $0.path)) == id
        }
    }

    func stopProjectGitWatcher(projectId: String) {
        projectGitWatchers.removeValue(forKey: projectId)?.stop()
        remoteProjectWatchers.removeValue(forKey: projectId)?.stop()
    }

    func startAllProjectGitWatchers(includeRemoteProjects: Bool = true) {
        for project in projectsManager.projects {
            if !includeRemoteProjects, project.host != nil { continue }
            startProjectGitWatcher(for: project)
        }
        startWorktreeUpstreamStatusRefreshes(includeRemoteProjects: includeRemoteProjects)
    }

    func stopAllProjectGitWatchers() {
        for (_, watcher) in projectGitWatchers { watcher.stop() }
        projectGitWatchers.removeAll()
        for (_, watcher) in remoteProjectWatchers { watcher.stop() }
        remoteProjectWatchers.removeAll()
        worktreeUpstreamStatusRefreshTask?.cancel()
        worktreeUpstreamStatusRefreshTask = nil
    }

    private func startWorktreeUpstreamStatusRefreshes(includeRemoteProjects: Bool) {
        guard worktreeUpstreamStatusRefreshTask == nil else { return }
        worktreeUpstreamStatusRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let worktreeConfig = self.config.worktrees
                let refreshInterval = WorktreeUpstreamStatusStore.fetchInterval(
                    fetchIntervalMinutes: worktreeConfig.fetchIntervalMinutes
                )
                for project in self.projectsManager.projects {
                    if !includeRemoteProjects, project.host != nil { continue }
                    await self.refreshMainWorktreeUpstreamStatuses(
                        projectId: project.id,
                        allowFetch: worktreeConfig.autoFetch,
                        minFetchInterval: refreshInterval
                    )
                }
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
            }
        }
    }

    func handleProjectHeadUpdates(projectId: String, branchByWorktreePath: [URL: String]) {
        bumpRevisionGenerationForProject(projectId: projectId)
        let reportedPaths = Set(branchByWorktreePath.keys.map {
            Self.canonicalWorktreePath($0.path)
        })
        let changedPaths = projectsManager.applyHeadUpdates(
            projectId: projectId,
            branchByWorktreePath: branchByWorktreePath
        )
        if !changedPaths.isEmpty { saveProjects() }
        for worktree in projectsManager.worktrees(projectId: projectId)
            where reportedPaths.contains(Self.canonicalWorktreePath(worktree.path.path))
        {
            GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
        }
        invalidateGGStackCacheAndRebumpGeneration(projectId: projectId)
        rightPaneStore.refreshActiveGGPresentationForHeadUpdates(
            projectId: projectId,
            worktreePaths: Array(branchByWorktreePath.keys)
        )
        refreshGGSidebar()
        GGInboxStore.shared.invalidate(projectId: projectId)
        Task { @MainActor [weak self] in
            await self?.refreshMainWorktreeUpstreamStatuses(projectId: projectId)
        }
    }

    private func handleProjectRevisionChange(projectId: String) {
        bumpRevisionGenerationForProject(projectId: projectId)
        handleProjectStackRevisionChange(projectId: projectId)
        Task { @MainActor [weak self] in
            await self?.refreshMainWorktreeUpstreamStatuses(projectId: projectId)
        }
    }

    private func handleProjectStackRevisionChange(projectId: String) {
        invalidateGGStackCacheAndRebumpGeneration(projectId: projectId)
        rightPaneStore.refreshActiveGGPresentationForProjectRevision(projectId: projectId)
        refreshGGSidebar()
        GGInboxStore.shared.invalidate(projectId: projectId)
    }

    /// Invalidation itself is a fast, in-memory actor call, but it's still
    /// async relative to the synchronous generation bump these callers just
    /// made — a follower's `.task(id:)` can restart on the new generation
    /// and read the cache before this completes, resolving a GG-ID against
    /// the pre-rewrite stack. Bumping the generation again once invalidation
    /// has actually landed gives any follower that raced ahead a second,
    /// guaranteed-fresh reload instead of sticking to a stale entry.
    private func invalidateGGStackCacheAndRebumpGeneration(projectId: String) {
        Task { @MainActor in
            await ggStackCache.invalidate()
            self.bumpRevisionGenerationForProject(projectId: projectId)
        }
    }

    func revisionChangeGeneration(worktreeID: String) -> Int {
        revisionChangeGenerations[worktreeID, default: 0]
    }

    func reviewSessionRetargetGeneration(sessionID: ReviewSessionID) -> Int {
        reviewSessionRetargetGenerations[sessionID.rawValue, default: 0]
    }

    /// Reloads an open review session's diff in place, keeping its comments:
    /// scopes such as the working tree change without changing the session.
    func reloadReviewSession(sessionID: ReviewSessionID) {
        bumpReviewSessionRetargetGeneration(sessionID: sessionID)
    }

    func followRevision(worktreeID: String, tabID: TabID, target: TrackedRevisionTarget) {
        let requestKey = followRevisionRequestKey(worktreeID: worktreeID, tabID: tabID)
        let requestGeneration = bumpFollowRevisionRequestGeneration(requestKey)
        Task { @MainActor in
            await applyFollowRevision(
                worktreeID: worktreeID,
                requestKey: requestKey,
                requestGeneration: requestGeneration,
                target: target
            )
        }
    }

    func promptFollowRevision(worktreeID: String, tabID: TabID, prefill: TrackedRevisionTarget? = nil) {
        switch FollowRevisionPromptRoute.route(
            prefill: prefill,
            stackEntrySupported: ggFollowSupported(worktreeID: worktreeID)
        ) {
        case .stackEntryPicker(let isEditing):
            promptFollowStackEntry(worktreeID: worktreeID, tabID: tabID, isEditing: isEditing)
        case .expressionPrompt(let expressionPrefill, let isEditing):
            let requestKey = followRevisionRequestKey(worktreeID: worktreeID, tabID: tabID)
            let requestGeneration = bumpFollowRevisionRequestGeneration(requestKey)
            let editorGeneration = bumpFollowRevisionEditorGeneration()
            Task { @MainActor in
                let resolvedPrefill: String?
                if let expressionPrefill {
                    resolvedPrefill = expressionPrefill
                } else {
                    resolvedPrefill = await suggestedFollowRevisionPrefill(worktreeID: worktreeID, tabID: tabID)
                }
                guard isCurrentFollowRevisionRequest(
                    worktreeID: worktreeID,
                    requestKey: requestKey,
                    requestGeneration: requestGeneration
                ), followRevisionEditorGeneration == editorGeneration
                else { return }
                followRevisionEditorRequest = FollowRevisionEditorRequest(
                    worktreeID: worktreeID,
                    tabID: tabID,
                    expression: resolvedPrefill ?? "",
                    isEditing: isEditing
                )
            }
        }
    }

    func promptFollowStackEntry(worktreeID: String, tabID: TabID, isEditing: Bool = false) {
        let requestKey = followRevisionRequestKey(worktreeID: worktreeID, tabID: tabID)
        let requestGeneration = bumpFollowRevisionRequestGeneration(requestKey)
        pendingFollowStackEntry = GGFollowEntryPresentation(
            worktreeID: worktreeID,
            tabID: tabID,
            isEditing: isEditing,
            state: .loading
        )
        guard let worktree = worktree(withId: worktreeID) else { return }
        let currentGGID = followedStackEntryGGID(worktreeID: worktreeID, tabID: tabID)
        let displayedSHA = displayedCommitSHA(worktreeID: worktreeID, tabID: tabID)
        if let rightPaneState = rightPaneStore.activeState(worktreeId: worktreeID),
           rightPaneState.ggStackLoadState == .loaded,
           rightPaneState.ggStackCommitsKey == rightPaneState.currentGGStackCommitsKey,
           let stack = rightPaneState.ggStack {
            pendingFollowStackEntry?.state = .loaded(GGFollowEntryModel.make(
                entries: stack.entries,
                currentGGID: currentGGID,
                displayedSHA: displayedSHA
            ))
            return
        }
        Task { @MainActor in
            let state: GGFollowEntryLoadState
            do {
                let stack = try await ggStackCache.stack(at: worktree.path) {
                    try await GGService().currentStack(worktreePath: worktree.path.path)
                }
                if let stack {
                    state = .loaded(GGFollowEntryModel.make(
                        entries: stack.entries,
                        currentGGID: currentGGID,
                        displayedSHA: displayedSHA
                    ))
                } else {
                    state = .offStack
                }
            } catch {
                state = .failed((error as? GGServiceError)?.userMessage ?? (error as NSError).localizedDescription)
            }
            guard isCurrentFollowRevisionRequest(
                worktreeID: worktreeID,
                requestKey: requestKey,
                requestGeneration: requestGeneration
            ), pendingFollowStackEntry?.id == "\(worktreeID):\(tabID)" else { return }
            pendingFollowStackEntry?.state = state
        }
    }

    func confirmFollowStackEntry(ggID: String) {
        guard let presentation = pendingFollowStackEntry else { return }
        pendingFollowStackEntry = nil
        followRevision(
            worktreeID: presentation.worktreeID,
            tabID: presentation.tabID,
            target: .stackEntry(ggID: ggID)
        )
    }

    func cancelFollowStackEntry() {
        pendingFollowStackEntry = nil
    }

    /// Whether this worktree can follow stack entries at all: gg must be
    /// installed, enabled for the project, and the branch stack-shaped.
    ///
    /// Reads the cached, observable gg context already maintained by
    /// `rightPaneStore` (the same source `CenterPaneView`'s split-commit
    /// workflow gate reads) instead of recomputing it from disk on every
    /// call — this is invoked from SwiftUI view bodies, so it must stay
    /// cheap. Commit and review-session tabs don't activate a right-pane
    /// state on their own, so that cache can be unseeded even for a worktree
    /// with an active gg stack; fall back to deriving the context directly
    /// in that case rather than reporting unsupported.
    func ggFollowSupported(worktreeID: String) -> Bool {
        if let context = rightPaneStore.activeState(worktreeId: worktreeID)?.ggContext {
            return context.isActive
        }
        guard let worktree = worktree(withId: worktreeID),
              let project = projectsManager.projects.first(where: { $0.id == worktree.projectId })
        else { return false }
        return ggWorktreeContext(
            project: project,
            worktree: worktree,
            branch: worktree.branch
        ).isActive
    }

    private func followedStackEntryGGID(worktreeID: String, tabID: TabID) -> String? {
        guard let tab = tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID }) else { return nil }
        switch tab {
        case .commit(let state):
            return state.revision.tracked?.target.ggID
        case .reviewSession(let state):
            let record = try? core.reviewSessions.load(id: state.sessionID)
            if case .trackedCommit(let revision) = record?.target.payload {
                return revision.target.ggID
            }
            return nil
        default:
            return nil
        }
    }

    func submitFollowRevisionEditor() {
        guard var request = followRevisionEditorRequest,
              !request.isSubmitting,
              let expression = request.submissionExpression
        else { return }
        request.isSubmitting = true
        request.errorMessage = nil
        followRevisionEditorRequest = request
        followRevision(worktreeID: request.worktreeID, tabID: request.tabID, target: .expression(expression))
    }

    func dismissFollowRevisionEditor() {
        guard let request = followRevisionEditorRequest else { return }
        _ = bumpFollowRevisionRequestGeneration(
            followRevisionRequestKey(worktreeID: request.worktreeID, tabID: request.tabID)
        )
        _ = bumpFollowRevisionEditorGeneration()
        followRevisionEditorRequest = nil
    }

    private func suggestedFollowRevisionPrefill(worktreeID: String, tabID: TabID) async -> String? {
        guard let worktree = worktree(withId: worktreeID),
              let displayedSHA = displayedCommitSHA(worktreeID: worktreeID, tabID: tabID)
        else { return nil }
        let result = try? await Process.git(
            ["rev-list", "--first-parent", "--max-count=200", "HEAD"],
            cwd: worktree.path
        )
        guard result?.exitCode == 0 else { return nil }
        let firstParentSHAs = result?.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        return FollowRevisionPrefill.expression(displayedSHA: displayedSHA, firstParentSHAs: firstParentSHAs)
    }

    private func displayedCommitSHA(worktreeID: String, tabID: TabID) -> String? {
        guard let tab = tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID }) else { return nil }
        switch tab {
        case .commit(let state):
            return state.sha
        case .reviewSession(let state):
            let record = try? core.reviewSessions.load(id: state.sessionID)
            switch record?.target.payload {
            case .commit(let sha):
                return sha
            case .trackedCommit(let revision):
                return revision.resolvedSHA
            default:
                return nil
            }
        default:
            return nil
        }
    }

    func stopFollowingRevision(worktreeID: String, tabID: TabID) {
        if let tab = tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID }) {
            switch tab {
            case .commit(let state):
                guard case .following(let revision) = state.revision else { return }
                _ = bumpFollowRevisionRequestGeneration(followRevisionRequestKey(for: tab))
                _ = tabs.updateCommit(worktreeId: worktreeID, tabId: tabID) {
                    $0.fix(sha: revision.resolvedSHA)
                }
            case .reviewSession(let state):
                _ = bumpFollowRevisionRequestGeneration(followRevisionRequestKey(for: tab))
                stopFollowingReviewSession(worktreeID: worktreeID, tabID: tabID, sessionID: state.sessionID)
            default:
                return
            }
        }
    }

    func acceptTrackedRevisionCheckout(worktreeID: String, tabID: TabID) {
        guard let tab = tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID }) else { return }
        switch tab {
        case .commit(let state):
            guard case .following(let revision) = state.revision,
                  let accepted = revision.preparingPendingCheckoutAcceptance()
            else { return }
            _ = bumpFollowRevisionRequestGeneration(followRevisionRequestKey(for: tab))
            _ = tabs.updateCommit(worktreeId: worktreeID, tabId: tabID) {
                $0.revision = .following(accepted)
            }
            bumpRevisionGeneration(worktreeID: worktreeID)
        case .reviewSession(let state):
            _ = bumpFollowRevisionRequestGeneration(followRevisionRequestKey(for: tab))
            acceptTrackedReviewSessionCheckout(worktreeID: worktreeID, tabID: tabID, sessionID: state.sessionID)
        default:
            return
        }
    }

    private func applyFollowRevision(
        worktreeID: String,
        requestKey: String,
        requestGeneration: Int,
        target: TrackedRevisionTarget
    ) async {
        guard let worktree = worktree(withId: worktreeID) else { return }
        let candidate: TrackedRevisionCandidate
        do {
            candidate = try await TrackedRevisionResolver.live.resolve(at: worktree.path, target: target)
        } catch {
            guard isCurrentFollowRevisionRequest(worktreeID: worktreeID, requestKey: requestKey, requestGeneration: requestGeneration)
            else { return }
            publishFollowRevisionError(
                worktreeID: worktreeID,
                requestKey: requestKey,
                message: (error as NSError).localizedDescription
            )
            return
        }
        guard let revision = TrackedRevision(
            target: target,
            baselineBranch: candidate.branch,
            baselineHEAD: candidate.headSHA,
            resolvedSHA: candidate.sha
        ) else {
            guard isCurrentFollowRevisionRequest(worktreeID: worktreeID, requestKey: requestKey, requestGeneration: requestGeneration)
            else { return }
            publishFollowRevisionError(
                worktreeID: worktreeID,
                requestKey: requestKey,
                message: "Revision target must not be empty."
            )
            return
        }
        guard isCurrentFollowRevisionRequest(worktreeID: worktreeID, requestKey: requestKey, requestGeneration: requestGeneration),
              let tab = followRevisionRequestTab(worktreeID: worktreeID, requestKey: requestKey)
        else {
            return
        }
        if followRevisionEditorRequest.map({
            $0.worktreeID == worktreeID && followRevisionRequestKey(worktreeID: worktreeID, tabID: $0.tabID) == requestKey
        }) == true {
            followRevisionEditorRequest = nil
        }

        switch tab {
        case .commit:
            _ = tabs.updateCommit(worktreeId: worktreeID, tabId: tab.id) {
                $0.follow(revision)
            }
        case .reviewSession(let state):
            followReviewSession(worktreeID: worktreeID, tabID: tab.id, sessionID: state.sessionID, revision: revision)
        default:
            return
        }
    }

    private func publishFollowRevisionError(worktreeID: String, requestKey: String, message: String) {
        guard var request = followRevisionEditorRequest,
              request.worktreeID == worktreeID,
              followRevisionRequestKey(worktreeID: worktreeID, tabID: request.tabID) == requestKey
        else {
            Self.showWarningAlert(title: "Invalid Revision", message: message)
            return
        }
        request.isSubmitting = false
        request.errorMessage = message
        followRevisionEditorRequest = request
    }

    private func bumpFollowRevisionRequestGeneration(_ key: String) -> Int {
        let next = followRevisionRequestGenerations[key, default: 0] + 1
        followRevisionRequestGenerations[key] = next
        return next
    }

    private func bumpFollowRevisionEditorGeneration() -> Int {
        followRevisionEditorGeneration += 1
        return followRevisionEditorGeneration
    }

    private func isCurrentFollowRevisionRequest(
        worktreeID: String,
        requestKey: String,
        requestGeneration: Int
    ) -> Bool {
        followRevisionRequestGenerations[requestKey] == requestGeneration &&
            followRevisionRequestTab(worktreeID: worktreeID, requestKey: requestKey) != nil
    }

    private func followRevisionRequestTab(worktreeID: String, requestKey: String) -> Tab? {
        tabs.tabs(forWorktree: worktreeID).first { followRevisionRequestKey(for: $0) == requestKey }
    }

    private func followRevisionRequestKey(worktreeID: String, tabID: TabID) -> String {
        guard let tab = tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID }) else {
            return "\(worktreeID):\(tabID)"
        }
        return followRevisionRequestKey(for: tab)
    }

    private func followRevisionRequestKey(for tab: Tab) -> String {
        switch tab {
        case .commit(let state):
            return "\(state.worktreeId):\(state.viewID)"
        case .reviewSession(let state):
            return "\(state.worktreeId):\(state.viewID)"
        default:
            return "\(tab.id)"
        }
    }

    private func followReviewSession(
        worktreeID: String,
        tabID: TabID,
        sessionID: ReviewSessionID,
        revision: TrackedRevision
    ) {
        let store = core.reviewSessions
        guard let record = try? store.load(id: sessionID),
              let result = TrackedRevisionRetargeter.follow(
                  record: record,
                  revision: revision,
                  title: "Review \(revision.target.displayLabel)",
                  now: Date()
              )
        else { return }
        if let existing = try? store.findActive(targetID: result.record.target.id, excluding: record.id) {
            let merged = mergedReviewSession(existing: existing, source: result.record)
            do {
                let draftStore = core.reviewDrafts
                let draftSnapshot = try draftStore.snapshot()
                try draftStore.migrate(from: result.oldDraftSessionID, to: existing.target.draftSessionID)
                do {
                    try store.replace(id: record.id, with: merged)
                } catch {
                    try? draftStore.restore(draftSnapshot)
                    throw error
                }
                invalidateFollowRevisionRequests(for: [tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID })].compactMap { $0 })
                tabs.close(worktreeId: worktreeID, tabId: tabID)
            } catch {
                Self.showWarningAlert(title: "Could Not Update Review Target", message: error.localizedDescription)
                return
            }
            core.reviewCommentsDidChange()
            bumpReviewSessionRetargetGeneration(sessionID: merged.id)
            let tab = tabs.openOrFocusReviewSession(worktreeId: worktreeID, record: merged)
            activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
            return
        }
        persistReviewRetargeting(result, worktreeID: worktreeID, tabID: tabID)
    }

    private func stopFollowingReviewSession(worktreeID: String, tabID: TabID, sessionID: ReviewSessionID) {
        let store = core.reviewSessions
        guard let record = try? store.load(id: sessionID),
              let result = TrackedRevisionRetargeter.stop(
                  record: record,
                  title: "Review \(record.target.revisionDescription ?? "commit")",
                  now: Date()
              )
        else { return }
        if let existing = try? store.findActive(targetID: result.record.target.id, excluding: record.id) {
            let merged = mergedReviewSession(existing: existing, source: result.record)
            do {
                let draftStore = core.reviewDrafts
                let draftSnapshot = try draftStore.snapshot()
                try draftStore.migrate(from: result.oldDraftSessionID, to: existing.target.draftSessionID)
                do {
                    try store.replace(id: record.id, with: merged)
                } catch {
                    try? draftStore.restore(draftSnapshot)
                    throw error
                }
                invalidateFollowRevisionRequests(for: [tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID })].compactMap { $0 })
                tabs.close(worktreeId: worktreeID, tabId: tabID)
            } catch {
                Self.showWarningAlert(title: "Could Not Update Review Target", message: error.localizedDescription)
                return
            }
            core.reviewCommentsDidChange()
            bumpReviewSessionRetargetGeneration(sessionID: merged.id)
            let tab = tabs.openOrFocusReviewSession(worktreeId: worktreeID, record: merged)
            activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
            return
        }
        persistReviewRetargeting(result, worktreeID: worktreeID, tabID: tabID)
    }

    private func acceptTrackedReviewSessionCheckout(worktreeID: String, tabID: TabID, sessionID: ReviewSessionID) {
        let store = core.reviewSessions
        guard let record = try? store.load(id: sessionID),
              case .trackedCommit(let revision) = record.target.payload,
              let accepted = revision.preparingPendingCheckoutAcceptance(),
              let result = TrackedRevisionRetargeter.follow(
                  record: record,
                  revision: accepted,
                  title: "Review \(accepted.target.displayLabel)",
                  now: Date()
              )
        else { return }
        persistReviewRetargeting(result, worktreeID: worktreeID, tabID: tabID)
    }

    private func mergedReviewSession(existing: ReviewSessionRecord, source: ReviewSessionRecord) -> ReviewSessionRecord {
        ReviewSessionConsolidation.merge(existing: existing, source: source)
    }

    private func persistReviewRetargeting(
        _ result: TrackedRevisionRetargetingResult,
        worktreeID: String,
        tabID: TabID
    ) {
        let sessionStore = core.reviewSessions
        var savedRecord = false
        let previousOldRecord = try? sessionStore.load(id: result.oldRecordID)
        let previousNewRecord = try? sessionStore.load(id: result.record.id)
        do {
            try sessionStore.replace(id: result.oldRecordID, with: result.record)
            savedRecord = true
            try core.reviewDrafts.migrate(from: result.oldDraftSessionID, to: result.newDraftSessionID)
            _ = tabs.updateReviewSession(worktreeId: worktreeID, tabId: tabID) {
                $0.retarget(to: result.record)
            }
            bumpReviewSessionRetargetGeneration(sessionID: result.record.id)
        } catch {
            if savedRecord {
                if let previousOldRecord {
                    try? sessionStore.save(previousOldRecord)
                }
                if result.record.id != result.oldRecordID {
                    if let previousNewRecord {
                        try? sessionStore.save(previousNewRecord)
                    } else {
                        try? sessionStore.delete(id: result.record.id)
                    }
                }
            }
            Self.showWarningAlert(title: "Could Not Update Review Target", message: error.localizedDescription)
        }
    }

    private func bumpReviewSessionRetargetGeneration(sessionID: ReviewSessionID) {
        reviewSessionRetargetGenerations[sessionID.rawValue, default: 0] += 1
    }

    private func bumpRevisionGeneration(worktreeID: String) {
        revisionChangeGenerations[worktreeID, default: 0] += 1
    }

    private func bumpRevisionGenerationForProject(projectId: String) {
        for worktree in projectsManager.worktrees(projectId: projectId) {
            bumpRevisionGeneration(worktreeID: worktree.id)
        }
    }

    private func bumpRevisionGenerationForWorktreePaths(projectId: String, paths: [URL]) {
        let affectedPaths = Set(paths.map { Self.canonicalWorktreePath($0.path) })
        guard !affectedPaths.isEmpty else { return }
        for worktree in projectsManager.worktrees(projectId: projectId) {
            if affectedPaths.contains(Self.canonicalWorktreePath(worktree.path.path)) {
                bumpRevisionGeneration(worktreeID: worktree.id)
            }
        }
    }

    private func handleProjectTopologyChange(projectId: String) {
        Task { @MainActor in
            await refreshProjectTopology(projectId: projectId)
        }
    }

    @discardableResult
    fileprivate func refreshProjectWorktrees(projectId: String) async throws -> Bool {
        let previousPaths = Dictionary(uniqueKeysWithValues: projectsManager.projects
            .filter { $0.id == projectId }
            .map { ($0.id, $0.path) })
        let previousBranches = Dictionary(uniqueKeysWithValues: projectsManager
            .worktrees(projectId: projectId)
            .map { (Self.canonicalWorktreePath($0.path.path), (path: $0.path.path, branch: $0.branch)) })
        let previousOperationStates = projectsManager.operationStatesSnapshot()
        let changed = try await projectsManager.refreshWorktrees(projectId: projectId)
        let completedCreateFailure = await completeReconciledCreateFailures(
            projectId: projectId,
            previousOperationStates: previousOperationStates
        )
        for worktree in projectsManager.worktrees(projectId: projectId) {
            let canonicalPath = Self.canonicalWorktreePath(worktree.path.path)
            guard let previous = previousBranches[canonicalPath], previous.branch != worktree.branch else {
                continue
            }
            GGStackSummaryStore.shared.summaries[previous.path] = nil
            GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
        }
        if changed || completedCreateFailure {
            saveProjects()
            rightPaneStore.reevaluateGGGates()
        }
        // Every direct refresh can move a directory to another project, so
        // reselect here rather than in each caller.
        reconcileSelectionAfterOwnershipChange()
        restartProjectGitWatchers(previousPaths: previousPaths)
        rescanWorktreeStatuses()
        await refreshMainWorktreeUpstreamStatuses(projectId: projectId)
        return changed || completedCreateFailure
    }

    private func refreshMainWorktreeUpstreamStatuses(
        projectId: String,
        allowFetch: Bool = false,
        minFetchInterval: TimeInterval = WorktreeUpstreamStatusStore.defaultFetchInterval
    ) async {
        guard let project = projectsManager.projects.first(where: { $0.id == projectId }),
              !project.isFolder
        else { return }
        let mainWorktrees = projectsManager.worktrees(projectId: projectId).filter {
            projectsManager.isMain($0, in: project)
        }
        await worktreeUpstreamStatusStore.refresh(
            worktrees: mainWorktrees,
            allowFetch: allowFetch,
            minFetchInterval: minFetchInterval
        )
    }

    private func completeReconciledCreateFailures(
        projectId: String,
        previousOperationStates: [WorktreeOperationKey: WorktreeOperationState]
    ) async -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        var changed = false
        for (key, state) in previousOperationStates {
            guard case .createFailed(
                _,
                _,
                _,
                _,
                let launchSurface,
                let issueAttachment,
                let namesBranchFromFirstPrompt
            ) = state,
                key.projectId == projectId
            else { continue }
            let worktreeId = key.worktreeId
            guard projectsManager.operationState(forWorktreeId: worktreeId, projectId: projectId) == nil,
                  let worktree = projectsManager.worktrees(projectId: projectId).first(where: { $0.id == worktreeId })
            else { continue }
            guard reconciledCreateFailureCompletionClaims.insert(key).inserted else { continue }

            if let issueAttachment,
               projectsManager.issueAttachment(projectId: projectId, worktreeId: worktreeId) != issueAttachment {
                projectsManager.setIssueAttachment(
                    projectId: projectId,
                    worktreeId: worktreeId,
                    attachment: issueAttachment
                )
                changed = true
            }
            if namesBranchFromFirstPrompt,
               projectsManager.pendingAutoBranchName(projectId: projectId, worktreeId: worktreeId) == nil {
                projectsManager.setPendingAutoBranchName(
                    projectId: projectId,
                    worktreeId: worktreeId,
                    placeholder: worktree.branch
                )
                changed = true
            }

            if launchSurface != .delegated {
                selectWorktree(id: worktree.id)
            }

            do {
                try await launchWorktreeSurface(launchSurface, worktree: worktree, project: project)
            } catch {
                markWorktreeLaunchFailed(
                    worktree: worktree,
                    error: error,
                    launchSurface: launchSurface
                )
            }
        }
        return changed
    }

#if DEBUG
    func completeReconciledCreateFailuresForTesting(
        projectId: String,
        previousOperationStates: [WorktreeOperationKey: WorktreeOperationState]
    ) async -> Bool {
        await completeReconciledCreateFailures(
            projectId: projectId,
            previousOperationStates: previousOperationStates
        )
    }
#endif

    func refreshProjectTopology(projectId: String) async {
        let beforeIds = allWorktreeIds()
        _ = try? await refreshProjectWorktrees(projectId: projectId)
        let afterIds = allWorktreeIds()
        let addedIds = afterIds.subtracting(beforeIds)
        if !addedIds.isEmpty {
            tabs.loadAll(worktreeIds: Array(addedIds))
        }
        await cleanupMissingWorktrees(beforeIds: beforeIds)
    }

    /// Refresh every project, persist any reconciled configuration, and move
    /// existing watchers when a deleted linked-worktree anchor is replaced.
    @discardableResult
    func refreshAllProjectTopologies() async -> Bool {
        isRefreshingProjectTopologies = true
        defer { isRefreshingProjectTopologies = false }
        let previousPaths = Dictionary(uniqueKeysWithValues: projectsManager.projects.map { ($0.id, $0.path) })
        let previousOperationStates = projectsManager.operationStatesSnapshot()
        // Before the refresh, which forgets archived paths git no longer
        // lists and with them the paths whose registration needs removing.
        await projectsManager.pruneStaleArchivedWorktrees()
        let changed = await projectsManager.refreshAll()
        reconcileSelectionAfterOwnershipChange()
        var completedCreateFailure = false
        for projectId in previousPaths.keys {
            completedCreateFailure = await completeReconciledCreateFailures(
                projectId: projectId,
                previousOperationStates: previousOperationStates
            ) || completedCreateFailure
        }
        if changed || completedCreateFailure {
            saveProjects()
            rightPaneStore.reevaluateGGGates()
        }
        restartProjectGitWatchers(previousPaths: previousPaths)
        refreshGGSidebar()
        for project in projectsManager.projects {
            await refreshMainWorktreeUpstreamStatuses(projectId: project.id)
        }
        return changed || completedCreateFailure
    }

    /// Archived worktrees are hidden and no watcher reloads a project when
    /// one's directory is deleted, so check for stale ones periodically.
    func startArchivedWorktreePruning() {
        guard archivedWorktreePruneTask == nil else { return }
        archivedWorktreePruneTask = Task { @MainActor [weak self] in
            while (try? await Task.sleep(for: .seconds(300))) != nil {
                guard let self else { return }
                await self.pruneStaleArchivedWorktrees()
            }
        }
    }

    /// Forgets archived worktrees whose directory or checkout is gone.
    func pruneStaleArchivedWorktrees() async {
        for projectId in await projectsManager.pruneStaleArchivedWorktrees() {
            await refreshProjectTopology(projectId: projectId)
        }
    }

    private func restartProjectGitWatchers(previousPaths: [String: String]) {
        for project in projectsManager.projects {
            guard let previousPath = previousPaths[project.id], previousPath != project.path else { continue }
            guard projectGitWatchers[project.id] != nil || remoteProjectWatchers[project.id] != nil else { continue }
            startProjectGitWatcher(for: project)
        }
    }

    func updateProject(
        id: String,
        name: String,
        icon: ProjectIcon,
        startupScripts: ProjectStartupScripts,
        mcpServers: [ProjectMCPServer],
        worktreeBranchTemplate: String? = nil,
        shepherd: ProjectShepherdSettings? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        projectsManager.updateProject(
            id: id,
            update: ProjectUpdate(
                name: trimmedName,
                icon: icon,
                startupScripts: startupScripts,
                mcpServers: mcpServers,
                worktreeBranchTemplate: worktreeBranchTemplate,
                shepherd: shepherd
            )
        )
        saveProjects()
    }

    func updateProject(
        id: String,
        name: String,
        color: String,
        startupScripts: ProjectStartupScripts,
        mcpServers: [ProjectMCPServer]
    ) {
        updateProject(
            id: id,
            name: name,
            icon: ProjectIcon.default(color: color),
            startupScripts: startupScripts,
            mcpServers: mcpServers
        )
    }

    /// Toggles a Files-tab bookmark for the repo the worktree belongs to.
    /// Bookmarks are repo-level, so every worktree of the project sees this.
    func toggleFileBookmark(projectId: String, path: String) {
        projectsManager.toggleFileBookmark(projectId: projectId, path: path)
        saveProjects()
    }

    func toggleFileBookmark(projectId: String, node: FileTreeNode) {
        projectsManager.toggleFileBookmark(projectId: projectId, node: node)
        saveProjects()
    }

    func removeFileBookmark(projectId: String, path: String) {
        projectsManager.removeFileBookmark(projectId: projectId, path: path)
        saveProjects()
    }

    func removeFileBookmark(projectId: String, node: FileTreeNode) {
        projectsManager.removeFileBookmark(projectId: projectId, node: node)
        saveProjects()
    }

    func removeFileBookmark(projectId: String, bookmark: String) {
        projectsManager.removeFileBookmark(projectId: projectId, bookmark: bookmark)
        saveProjects()
    }

    func setWorktreeLaunchDefaults(projectId: String, openAfterCreate: Bool, launcherMode: AppConfig.LauncherMode) {
        projectsManager.setWorktreeLaunchDefaults(
            projectId: projectId,
            openAfterCreate: openAfterCreate,
            launcherMode: launcherMode
        )
        saveProjects()
    }

    /// Archive (hide) a worktree: the core stops everything in it and hides
    /// it, then selection moves on if it was selected. Does NOT touch git or
    /// disk. The returned task finishes once the archive has run.
    @discardableResult
    func archiveWorktree(_ worktree: Worktree) -> Task<Void, Never>? {
        var savesBuffers = false
        var acknowledged: [TabID: Int] = [:]
        // Snapshotted before the prompt: its run loop lets other windows keep
        // editing, and only what the user was shown counts as acknowledged.
        let dirtyAtPrompt = dirtyTabGenerations(worktreeId: worktree.id)
        if !dirtyAtPrompt.isEmpty {
            switch promptForDirtyBuffers(
                action: "Archive",
                branch: worktree.branch,
                dirtyCount: dirtyAtPrompt.count,
                onDiskDestructive: false
            ) {
            case .save:
                savesBuffers = true
            case .discard:
                acknowledged = dirtyAtPrompt
            case .cancel:
                return nil
            }
        }
        // Claimed after the prompt: `.archiving` reads as removed, so the
        // panes would go away while the user is still deciding. Work admitted
        // meanwhile is stopped by the archive's quiesce.
        let claim: UUID
        do {
            claim = try core.beginArchive(worktree)
        } catch {
            showFileActionError(title: "Archive Failed", message: error.localizedDescription)
            return nil
        }
        let removedIndex = projectsManager.visibleWorktrees(projectId: worktree.projectId)
            .firstIndex(where: { $0.id == worktree.id }) ?? 0
        return Task { @MainActor in
            if savesBuffers, await !saveDirtyBuffers(in: worktree) {
                host.worktrees.releaseClaim(claim, for: worktree)
                return
            }
            do {
                try await withAcknowledgedDirtyTabs(acknowledged, for: worktree) {
                    try await core.archiveWorktree(worktree, claim: claim)
                }
            } catch {
                showFileActionError(title: "Archive Failed", message: error.localizedDescription)
                return
            }
            finishArchivingWorktree(worktree, removedIndex: removedIndex)
        }
    }

    /// Archives one confirmed batch item through the core.
    private func archiveBatchItem(_ worktree: Worktree, acknowledgedDirtyTabs acknowledged: [TabID: Int]) async -> WorktreeBatchOutcome {
        let removedIndex = projectsManager.visibleWorktrees(projectId: worktree.projectId)
            .firstIndex(where: { $0.id == worktree.id }) ?? 0
        do {
            try await withAcknowledgedDirtyTabs(acknowledged, for: worktree) {
                try await core.archiveWorktree(worktree)
            }
        } catch {
            return .skipped(reason: error.localizedDescription)
        }
        finishArchivingWorktree(worktree, removedIndex: removedIndex)
        return .archived
    }

    /// Runs `operation` with `acknowledged` as the only unsaved edits the
    /// quiesce step may discard in `worktree`; anything dirtied since refuses.
    fileprivate func withAcknowledgedDirtyTabs<Value>(
        _ acknowledged: [TabID: Int],
        for worktree: Worktree,
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        let key = WorktreeOperationKey(projectId: worktree.projectId, worktreeId: worktree.id)
        acknowledgedDirtyTabs[key] = acknowledged
        defer { acknowledgedDirtyTabs[key] = nil }
        return try await operation()
    }

    struct UnacknowledgedEditsError: LocalizedError {
        var errorDescription: String? { "The worktree has unsaved changes made after this was confirmed." }
    }

    private func finishArchivingWorktree(
        _ worktree: Worktree,
        removedIndex: Int
    ) {
        guard projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else {
            return
        }
        refreshGGSidebar()
        if selectedWorktreeId == worktree.id {
            selectWorktree(id: selectionAfterRemoval(
                removedFromProjectId: worktree.projectId,
                removedAtIndex: removedIndex
            ))
        }
    }

    /// Restore an archived worktree. Tabs/terminals are NOT recreated — they
    /// were torn down at archive time and the user re-opens what they need.
    func unarchiveWorktree(projectId: String, path: URL) {
        do {
            try core.unarchiveWorktree(path: path, projectID: projectId)
        } catch {
            showFileActionError(title: "Unarchive Failed", message: error.localizedDescription)
            return
        }
        if let restored = projectsManager.visibleWorktrees(projectId: projectId).first(where: {
            Self.canonicalWorktreePath($0.path.path) == Self.canonicalWorktreePath(path.path)
        }) {
            rescanWorktreeStatus(worktreeId: restored.id)
        }
    }

    /// Delete every archived worktree across all projects after one
    /// confirmation. Remote worktrees and those referenced by any Workspace
    /// checkout are left for the single-item flow (the batch path's local
    /// branch and ownership re-checks refuse them), and anything
    /// git refuses without `--force` is reported so the user can delete it
    /// individually.
    ///
    /// The batch re-checks sessions, buffers, branch, and ownership but not
    /// whether a target is still archived, so the Settings pane (the only
    /// unarchive entry point) locks its archived rows while this runs.
    private(set) var isDeletingArchivedWorktrees = false

    /// Unsaved edits a confirmed archive may discard, per worktree, while it
    /// runs. Read by the quiesce step right before it closes editors.
    @ObservationIgnored private var acknowledgedDirtyTabs: [WorktreeOperationKey: [TabID: Int]] = [:]

    /// One target per id, and none for an id any representation rejects. A
    /// worktree id is its path, so one local checkout archived under two
    /// projects appears twice: ownership is checked per project, so an
    /// unowned alias must not delete a checkout the other one owns, and a
    /// duplicate id would trap the batch's per-id snapshots.
    nonisolated static func bulkDeleteTargets<T>(
        _ candidates: [T],
        id: (T) -> String,
        isEligible: (T) -> Bool
    ) -> [T] {
        let blocked = Set(candidates.filter { !isEligible($0) }.map(id))
        var seen: Set<String> = []
        return candidates.filter { !blocked.contains(id($0)) && seen.insert(id($0)).inserted }
    }

    func deleteAllArchivedWorktrees() async {
        guard !isDeletingArchivedWorktrees else { return }
        let archived = projects.flatMap { projectsManager.archivedWorktrees(projectId: $0.id) }
        let deletable = workspacesManager.canMutate
            ? Self.bulkDeleteTargets(archived, id: \.id) { worktree in
                // The batch skips any claimed worktree and retries a failed
                // delete.
                return WorktreeOperationState.admitsLifecycleOperation(projectsManager.operationState(for: worktree))
                    && !worktree.path.isRemoteAlasPath
                    && worktreeCleanupWorkspaceOwners(for: worktree).isEmpty
            }
            : []
        guard !archived.isEmpty else { return }
        guard !deletable.isEmpty else {
            showFileActionError(
                title: "Nothing to Delete",
                message: workspacesManager.canMutate
                    ? "Remote, busy, or Workspace-referenced worktrees can't be deleted in bulk. Delete them individually."
                    : "Workspace Checkout ownership could not be verified. Try again once Workspace storage is available."
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete \(deletable.count) archived \(deletable.count == 1 ? "worktree" : "worktrees")?"
        // Frozen here: the batch re-reads the setting per item, and the
        // confirmation must stay true if it is toggled mid-batch.
        let deleteBranches = config.worktrees.deleteBranchOnRemove
        var message = deleteBranches
            ? "This removes their files from disk. Local branches will be deleted if merged."
            : "This removes their files from disk. Local branches will be kept."
        if deletable.count < Set(archived.map(\.id)).count {
            message += " Remote, busy, or Workspace-referenced worktrees are skipped; delete them individually."
        }
        alert.informativeText = message
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        deleteButton.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isDeletingArchivedWorktrees = true
        defer { isDeletingArchivedWorktrees = false }
        let results = await batchDeleteWorktrees(deletable, keepBranch: !deleteBranches)
        if results.contains(where: { $0.outcome != .deleted }) {
            showFileActionError(
                title: "Some Worktrees Were Not Deleted",
                message: WorktreeCleanupModel.summary(for: results)
                    + ". Delete the remaining ones individually."
            )
        }
    }

    /// Live sessions attached to a worktree's open terminal/ACP tabs, counted
    /// directly rather than through harness activity state (busy/awaiting) —
    /// mirrors the cleanup sheet's own `activeSessionCount` probe. Used to
    /// re-check a worktree immediately before a batch action touches it: the
    /// scan that produced the candidate list can be stale by the time the
    /// user confirms, and a session opened in that window (from another
    /// window, say) must not be torn down by `cleanupWorktreeState`.
    private func hasLiveSessions(worktreeId: String) -> Bool {
        tabs.tabs(forWorktree: worktreeId).contains { tab in
            switch tab {
            case .terminal(let s):   return !s.root.leaves().isEmpty
            case .acpSession:        return true
            default:                 return false
            }
        }
    }

    /// The edit generation of every currently-dirty tab in a worktree, keyed
    /// by tab id. Used to tell "still the same dirtiness the user already
    /// discarded" apart from "re-edited since" — a tab id alone isn't enough,
    /// since discarding a buffer doesn't clear it, and it can be typed into
    /// again (from another window) while a batch is still running. A tab
    /// with no live buffer instantiated (only a persisted hot-exit snapshot)
    /// gets a fixed sentinel generation, since there is no live edit counter
    /// to read until the tab is opened; a snapshot's content can't change on
    /// its own, so this stays stable as long as the tab remains unopened.
    func dirtyTabGenerations(worktreeId: String) -> [TabID: Int] {
        Dictionary(uniqueKeysWithValues: dirtyEditorTabIds(worktreeId: worktreeId).map {
            ($0, tabs.peekBuffer(tabId: $0)?.editGeneration ?? -1)
        })
    }

    /// True when every currently-dirty tab was already dirty, at the exact
    /// same edit generation, when the batch confirmation snapshot was taken —
    /// i.e. nothing new needs protecting. A tab present in `current` but
    /// absent or at a different generation in `acknowledgedAtConfirmation` is
    /// new or changed dirtiness the user never saw or acknowledged.
    nonisolated static func hasOnlyAcknowledgedDirtiness(
        current: [TabID: Int],
        acknowledgedAtConfirmation: [TabID: Int]
    ) -> Bool {
        current.allSatisfy { tabId, generation in
            acknowledgedAtConfirmation[tabId] == generation
        }
    }

    /// Archive several worktrees at once. Nothing on disk is touched — this
    /// only marks each path hidden in `ProjectConfig`, which is what persists
    /// across relaunch.
    ///
    /// Unsaved editor buffers are checked across the whole selection before any
    /// archiving happens, so the user answers one prompt rather than one per
    /// worktree. Cancelling that prompt cancels the whole batch.
    @discardableResult
    func batchArchiveWorktrees(_ worktrees: [Worktree]) async -> [WorktreeBatchResult] {
        guard !worktrees.isEmpty else { return [] }

        // Snapshot which tabs are dirty right now, before the prompt. If the
        // user confirms "Discard & Archive", those specific buffers stay
        // marked dirty in the tab model until cleanup actually closes them —
        // discarding doesn't retroactively un-dirty anything — so the
        // per-item re-check below must compare against this snapshot rather
        // than against "is anything dirty right now", or the confirmed
        // discard would skip every worktree it was meant to cover. Recording
        // each dirty tab's edit generation, not just its id, also catches a
        // tab re-edited (from another window) after being acknowledged here.
        let dirtyTabsAtConfirmation = Dictionary(
            uniqueKeysWithValues: worktrees.map { ($0.id, dirtyTabGenerations(worktreeId: $0.id)) }
        )
        let dirtyCount = dirtyTabsAtConfirmation.values.reduce(0) { $0 + $1.count }
        if dirtyCount > 0 {
            guard promptForDirtyBuffersInBatch(
                action: "Archive",
                worktreeCount: worktrees.count,
                dirtyCount: dirtyCount,
                onDiskDestructive: false
            ) == .discard else {
                return []
            }
        }

        var results: [WorktreeBatchResult] = []
        for worktree in worktrees {
            guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
                results.append(WorktreeBatchResult(
                    worktreeId: worktree.id,
                    branch: worktree.branch,
                    outcome: .failed(message: "Could not find the project for this worktree.")
                ))
                continue
            }
            guard !projectsManager.isMain(worktree, in: project) else {
                results.append(WorktreeBatchResult(
                    worktreeId: worktree.id,
                    branch: worktree.branch,
                    outcome: .skipped(reason: "Main worktree")
                ))
                continue
            }
            // Re-check right before archiving: the scan that selected this
            // worktree — and even the whole-batch dirty-buffer prompt above —
            // can be stale by the time this specific item is reached. Only
            // dirtiness the confirmation didn't already cover counts: a tab
            // dirty at confirmation time and discarded is expected here, but
            // a tab that turned dirty (or newly opened dirty), OR was edited
            // again since being acknowledged, must not be torn down.
            let currentDirtyGenerations = dirtyTabGenerations(worktreeId: worktree.id)
            let knownDirtyGenerations = dirtyTabsAtConfirmation[worktree.id] ?? [:]
            guard Self.hasOnlyAcknowledgedDirtiness(
                current: currentDirtyGenerations,
                acknowledgedAtConfirmation: knownDirtyGenerations
            ) else {
                results.append(WorktreeBatchResult(
                    worktreeId: worktree.id,
                    branch: worktree.branch,
                    outcome: .skipped(reason: "Has unsaved changes since this list was scanned")
                ))
                continue
            }
            guard !hasLiveSessions(worktreeId: worktree.id),
                  WorktreeOperationState.admitsLifecycleOperation(projectsManager.operationState(for: worktree))
            else {
                results.append(WorktreeBatchResult(
                    worktreeId: worktree.id,
                    branch: worktree.branch,
                    outcome: .skipped(reason: "Became busy since this list was scanned")
                ))
                continue
            }

            results.append(WorktreeBatchResult(
                worktreeId: worktree.id,
                branch: worktree.branch,
                outcome: await archiveBatchItem(worktree, acknowledgedDirtyTabs: knownDirtyGenerations)
            ))
        }
        return results
    }

    func startHarness() {
        // Rewrites the user's global agent settings (~/.claude, ~/.codex,
        // ~/.cursor); an isolated profile must leave those to the main instance.
        if !AlasProfile.current.isIsolated {
            LegacyHookSweep.sweepAll()
        }
        harness.notifications.setEnabled(config.harness.notifyOnFinish)
        if hostSocket == nil {
            hostSocket = HostSocketServer(server: HostProtocolServer(host: host))
        }
        harness.start(
            stateLookup: { [weak self] sessionId in
                self?.harnessSessionLocation(sessionId: sessionId)
            },
            ownerLookup: { [weak self] sessionId in
                self?.sessionOwnerForCLI(sessionId)
            },
            shouldNotifyOnAwaiting: { [weak self] in
                self?.config.harness.notifyOnAwaiting ?? true
            },
            isExternalSession: { [weak self] sessionId in
                self?.acpManagers.values.contains { $0.liveSession(for: sessionId) != nil } ?? false
            }
        )
        // Per-leaf symlink: stays valid across Alas restarts (the next
        // launch's `linkSession` repoints the same `<socket dir>/sock-
        // <leafId>` path), and per-leaf scoping avoids collisions between
        // concurrent Alas processes.
        terminal.socketPathProvider = { [weak self] leafId in
            self?.harness.socketServer.linkSession(leafId: leafId)
        }
        terminal.socketReleaseHandler = { [weak self] leafId in
            self?.harness.socketServer.unlinkSession(leafId: leafId)
        }
        terminal.onSessionRegistered = { [weak self] session in
            self?.acquireCheckpointTerminalLease(for: session)
        }
        terminal.onSessionUnregistered = { [weak self] session in
            guard let self else { return }
            self.checkpointWriterLeases.release(sessionID: session.id, instanceID: self.instanceId)
        }
        terminal.onSessionProcessExited = { [weak self] leafId, owner, processAlive in
            self?.handleTerminalProcessExited(
                owner: owner,
                leafId: leafId,
                processAlive: processAlive
            )
        }
        harness.socketServer.onCLIRequest = { [weak self] request in
            guard let self else { return .error("Alas is not available.") }
            self.noteBuiltInMCPRequest(
                sessionId: request.sessionId, serverTransport: request.mcpServerTransport)
            return await self.handleCLIRequest(request)
        }
        // Dispatched on the main queue, like `onMCPHello`. Session links died
        // with the deleted socket directory; relink only what this instance
        // still owns, so a session whose lease moved elsewhere is left alone.
        harness.socketServer.onRebind = { [weak self] in
            guard let self else { return }
            self.refreshPersistedHookSymlinks()
            for manager in self.acpManagers.values {
                Task { [weak self] in
                    for sessionId in await manager.confirmedWriterLeaseSessionIDs() {
                        _ = self?.acpSessionSocketPath(sessionId: sessionId)
                    }
                }
            }
        }
        // The socket server dispatches this on the main queue, so the closure
        // is already main-actor context.
        harness.socketServer.onMCPHello = { [weak self] hello in
            self?.noteBuiltInMCPHello(hello)
        }
        harness.onClickThrough = { [weak self] projectId, worktreeId, sessionId in
            self?.activateHarnessSession(
                projectId: projectId, worktreeId: worktreeId, sessionId: sessionId
            )
        }
        harness.onContextClickThrough = { [weak self] context in
            if let serverId = context.peerServerId, let worktreeID = context.peerWorktreeId {
                self?.nativePeerSessions?.selectHostWorktree(serverId: serverId, worktreeID: worktreeID)
                return
            }
            if let serverId = context.peerServerId {
                self?.nativePeerSessions?.select(
                    RemoteFederatedSessionID.compose(serverId: serverId, sessionId: context.sessionId)
                )
                return
            }
            guard let owner = context.owner,
                  case .workspaceCheckout = owner
            else { return }
            self?.activateHarnessSession(owner: owner, sessionId: context.sessionId)
        }
        // Symlink refresh runs from `reloadTabs()` instead of here —
        // `startHarness()` is called before the tab JSONs have been read,
        // so projectsManager.worktrees(...) would be empty.

        // Bring the remote-control server up if the user has it enabled. Safe
        // to call here: it reads live managers lazily, so no session state is
        // required at this point.
        syncRemoteServer()
    }

    @MainActor
    private func noteBuiltInMCPHello(_ hello: MCPHelloEvent) {
        mcpRegistrationRegistry.recordHello(
            sessionId: hello.sessionId, transport: hello.transport
        )
        // Heal immediately if a slow/lazy harness registered after the
        // grace check already flipped the row to notRegistered.
        var previous: MCPServerRegistration?
        for manager in acpManagers.values {
            if let session = manager.liveSession(for: hello.sessionId) {
                previous = session.builtInMCPRegistration
                session.builtInMCPRegistration = .registered
                break
            }
        }
        mcpRegistrationLogger.notice(
            "hello session=\(hello.sessionId, privacy: .public) transport=\(hello.transport.rawValue, privacy: .public) previous=\(previous.map { "\($0)" } ?? "no live session", privacy: .public)"
        )
    }

    /// A request carrying an ACP session's id. One the built-in `alas mcp`
    /// tagged with its transport (`serverTransport`) proves a server is up
    /// even if its hello was lost; an untagged one may be the agent's shell
    /// running `alas`. See `MCPRegistrationDecision`. Neither writes the
    /// hello registry, which only a hello may advance.
    @MainActor
    private func noteBuiltInMCPRequest(sessionId: String?, serverTransport: MCPTransportKind?) {
        guard let sessionId else { return }
        for manager in acpManagers.values {
            guard let session = manager.liveSession(for: sessionId) else { continue }
            let previous = session.builtInMCPRegistration
            let attachedTransport = session.mcpAttachmentSummary?.statuses
                .first { $0.id == BuiltInAlasMCP.statusId }?.transport
            let evidence = MCPRegistrationDecision.requestEvidence(
                serverTransport: serverTransport, attachedTransport: attachedTransport)
            if previous != .registered,
               MCPRegistrationDecision.resolve(
                   evidence: evidence,
                   graceElapsed: false,
                   reattachedToRunningServer: session.builtInMCPReattachedToRunningServer,
                   requiresFreshHello: session.builtInMCPRequiresFreshHello
               ) == .registered {
                session.builtInMCPRegistration = .registered
                mcpRegistrationLogger.notice(
                    "\("\(evidence)", privacy: .public) session=\(sessionId, privacy: .public) transport=\(serverTransport?.rawValue ?? "untagged", privacy: .public) previous=\("\(previous)", privacy: .public)"
                )
            }
            return
        }
    }

    @MainActor
    private func handleCLIRequest(_ request: AlasCLIRequest) async -> AlasCLIResponse {
        await makeCLICommandRouter().handle(request)
    }

    /// The owner of terminal session `sessionId`. A zmx-persisted leaf whose
    /// `TerminalSession` has not been restored yet is found in its tab, so
    /// `alas open` and hooks still resolve it.
    func terminalSessionOwner(_ sessionId: String) -> SessionOwnerID? {
        if let terminalSessionOwnerOverride { return terminalSessionOwnerOverride(sessionId) }
        if let session = terminal.registry.session(for: sessionId) {
            return session.owner
        }
        return persistedLeafOwner(leafId: sessionId)
    }

    private func sessionOwnerForCLI(_ sessionId: String) -> SessionOwnerID? {
        host.callers.owner(ofSession: sessionId)
    }

    func harnessSessionLocation(sessionId: String) -> (projectId: String, worktreeId: String)? {
        if let session = terminal.registry.session(for: sessionId) {
            return (projectId: session.projectId, worktreeId: session.worktreeId)
        }
        // Registry miss can happen for zmx-persisted leaves the user hasn't
        // displayed yet (restoreTerminalTabIfNeeded is driven by
        // TerminalTabView.task).
        if let persisted = persistedLeafLocation(leafId: sessionId) {
            return persisted
        }
        guard let owner = acpManagers.first(where: { _, manager in
            manager.liveSession(for: sessionId) != nil
        })?.key else { return nil }
        switch owner {
        case .worktree(let worktreeId):
            guard let (project, _) = projectAndWorktree(withWorktreeId: worktreeId) else { return nil }
            return (projectId: project.id, worktreeId: worktreeId)
        case .workspaceCheckout(let checkoutId, _):
            let workspaceId = workspacesManager.checkout(id: checkoutId)?.workspaceID?.uuidString ?? ""
            return (projectId: workspaceId, worktreeId: owner.storageKey)
        }
    }

    /// Linear scan of persisted terminal tabs for the (projectId, worktreeId)
    /// owning a given leaf. Used as the fallback for harness lookups
    /// (`stateLookup` and the CLI router) when a hook arrives from a
    /// zmx-persisted shell whose `TerminalSession` hasn't been restored
    /// yet — restoration is lazy on `TerminalTabView.task`, but hooks
    /// can fire before the user opens the tab.
    func persistedLeafLocation(leafId: String) -> (projectId: String, worktreeId: String)? {
        for project in projects {
            for worktree in projectsManager.worktrees(projectId: project.id) {
                for tab in tabs.tabs(forWorktree: worktree.id) {
                    guard case .terminal(let state) = tab else { continue }
                    if state.root.leaves().contains(where: { $0.id == leafId }) {
                        return (project.id, worktree.id)
                    }
                }
            }
        }
        for checkout in workspacesManager.checkouts {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            for tab in tabs.tabs(for: owner) {
                guard case .terminal(let state) = tab else { continue }
                if state.root.leaves().contains(where: { $0.id == leafId }) {
                    // Harness notifications still require a legacy
                    // (projectId, worktreeId) tuple before they are emitted.
                    // Checkout-owned notifications carry the typed owner too,
                    // and click-through routes through that owner, so this
                    // synthetic tuple is only the compatibility key that keeps
                    // persisted checkout leaves observable before lazy restore.
                    return (checkout.workspaceID?.uuidString ?? "", owner.storageKey)
                }
            }
        }
        return nil
    }

    private func persistedLeafOwner(leafId: String) -> SessionOwnerID? {
        for project in projects {
            for worktree in projectsManager.worktrees(projectId: project.id) {
                for tab in tabs.tabs(forWorktree: worktree.id) {
                    guard case .terminal(let state) = tab else { continue }
                    if state.root.leaves().contains(where: { $0.id == leafId }) {
                        return .worktree(worktree.id)
                    }
                }
            }
        }
        for checkout in workspacesManager.checkouts {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            for tab in tabs.tabs(for: owner) {
                guard case .terminal(let state) = tab else { continue }
                if state.root.leaves().contains(where: { $0.id == leafId }) {
                    return owner
                }
            }
        }
        return nil
    }

    /// `ALAS_SOCKET_PATH` for an ACP session's adapter, `alas mcp` server and
    /// `alas` CLI: the session's own link to the live socket, not the
    /// PID-named bind path. Those processes run in brokers that survive an
    /// app quit, so a relaunch must be able to reach them again; every attach
    /// runs this and repoints the link at the new instance. Only the instance
    /// holding the session's lease attaches it, so two instances on one
    /// profile never fight over a link. Falls back to the bind path when the
    /// link cannot be created.
    /// The visual-only built-in server for an SSH session. The host's helper
    /// relays `visual_show` frames back here, where a local
    /// `alas mcp --visual-only` serves them against the app socket under this
    /// session's id; nothing local is written into the remote agent's config.
    /// `allowsPRTools` is false for Workspace Checkouts, which the PR shepherd
    /// does not support.
    func remoteVisualMCPAttachment(
        context: BuiltInMCPAttachmentContext,
        configuredServers: [ProjectMCPServer],
        allowsPRTools: Bool = true
    ) async -> BuiltInMCPAttachment {
        guard case .ssh(let host, let fence) = context.location,
              BuiltInAlasMCP.injectsRemoteVisual(
                  enabled: config.harness.exposeAlasMCP,
                  configuredServers: configuredServers,
                  injectionSupport: context.injectionSupport
              )
        else { return .omitted }
        guard let binaryPath = (try? TerminalCLIInjection.installExecutables())?
                  .appendingPathComponent(TerminalCLIInjection.executableName).path,
              let socketPath = acpSessionSocketPath(sessionId: context.sessionId)
        else { return .skipped(BuiltInAlasMCP.unavailableStatus("Alas CLI unavailable")) }
        let environment = [
            "ALAS_SOCKET_PATH": socketPath,
            "ALAS_SESSION_ID": context.sessionId,
            "ALAS_WORKTREE_DIR": context.worktreePath,
        ]
        do {
            let prepared = try await RemoteVisualMCPBridge.prepare(
                client: RemoteHelperClientPool.shared.client(for: host),
                fence: fence,
                allowsPRTools: allowsPRTools,
                makeBackend: { toolScope in
                    JSONRPCStdioTransport(
                        executable: URL(fileURLWithPath: binaryPath),
                        arguments: ["mcp", toolScope.relayBackendFlag ?? "--visual-only"],
                        environment: environment,
                        framing: .newline
                    )
                },
                authorize: { await context.isCurrent() },
                onRegistration: { await context.noteRegistered() }
            )
            return .prepared(prepared)
        } catch {
            return .skipped(BuiltInAlasMCP.unavailableStatus(error.localizedDescription))
        }
    }

    func acpSessionSocketPath(sessionId: String) -> String? {
        harness.socketServer.linkSession(leafId: AgentHookSocketServer.acpSessionLinkKey(sessionId))
            ?? harness.socketServer.socketPath
    }

    /// Walks every persisted terminal-tab leaf across every worktree and
    /// (re)points its per-leaf hook symlink at the current bind path. Run
    /// from `reloadTabs()` once persisted state is in memory so background
    /// zmx-persisted shells (whose tabs the user hasn't displayed yet —
    /// `restoreTerminalTabIfNeeded` would otherwise only fire from
    /// `TerminalTabView.task`) can deliver hooks/CLI requests to the live
    /// harness immediately.
    private func refreshPersistedHookSymlinks() {
        for project in projects {
            for worktree in projectsManager.worktrees(projectId: project.id) {
                for tab in tabs.tabs(forWorktree: worktree.id) {
                    guard case .terminal(let state) = tab else { continue }
                    for leaf in state.root.leaves() {
                        _ = harness.socketServer.linkSession(leafId: leaf.id)
                    }
                }
            }
        }
        for checkout in workspacesManager.checkouts {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            for tab in tabs.tabs(for: owner) {
                guard case .terminal(let state) = tab else { continue }
                for leaf in state.root.leaves() {
                    _ = harness.socketServer.linkSession(leafId: leaf.id)
                }
            }
        }
    }

    /// Caches the loaded file summaries of a provider review, keyed by its
    /// draft session id, so repeated `review_comment_add` calls in the same
    /// review share one `gh`/`glab diff` fetch. Best-effort and never
    /// invalidated: rename mappings rarely change mid-review, and a miss
    /// simply falls back to nil (today's behavior).
    private var providerReviewFileSummaryCache: [ReviewDraftSessionID: [DiffReviewFileSummary]] = [:]

    /// Shared orchestration coordinator: the CLI/MCP router, the manager
    /// turn-completion hooks, and startup reconciliation all talk to one
    /// instance so outcome delivery has a single producer per instance.
    @ObservationIgnored
    var acpOrchestration: ACPSessionOrchestrationCoordinator { core.orchestration }

    func makeCLICommandRouter() -> AlasCLICommandRouter {
        let callers = host.callers
        return AlasCLICommandRouter(
            host: host,
            openRelativeFile: { [weak self] relativePath, worktreeId in
                self?.openFile(relativePath: relativePath, worktreeId: worktreeId)
            },
            openExternalFile: { [weak self] url, worktreeId in
                guard let self else { return }
                if BinaryFileType.isKnownBinary(relativePath: url.path) {
                    _ = self.tabs.openBinaryPreview(worktreeId: worktreeId, relativePath: url.path)
                    if self.selectedWorktreeId != worktreeId,
                       let worktree = self.worktree(withId: worktreeId) {
                        self.focusGlobalWorktree(id: worktreeId, projectId: worktree.projectId)
                    }
                    return
                }
                _ = self.tabs.openExternalEditor(
                    worktreeId: worktreeId,
                    absoluteURL: url,
                    revealLine: nil,
                    revealCharacter: nil,
                    originatingRelativePath: nil
                )
                if self.selectedWorktreeId != worktreeId,
                   let worktree = self.worktree(withId: worktreeId) {
                    self.focusGlobalWorktree(id: worktreeId, projectId: worktree.projectId)
                }
            },
            openRelativeFileAtLines: { [weak self] relativePath, worktreeId, lines in
                self?.openFile(
                    relativePath: relativePath,
                    worktreeId: worktreeId,
                    revealLine: lines.lowerBound,
                    revealEndLine: lines.upperBound,
                    revealCharacter: 0
                )
            },
            openExternalFileAtLines: { [weak self] url, worktreeId, lines in
                guard let self else { return }
                _ = self.tabs.openExternalEditor(
                    worktreeId: worktreeId,
                    absoluteURL: url,
                    revealLine: lines.lowerBound,
                    revealCharacter: 0,
                    revealEndLine: lines.upperBound
                )
                if self.selectedWorktreeId != worktreeId,
                   let worktree = self.worktree(withId: worktreeId) {
                    self.focusGlobalWorktree(id: worktreeId, projectId: worktree.projectId)
                }
            },
            focusWorktree: { [weak self] worktree in
                self?.focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
            },
            createWorktree: { [weak self] origin, branch, base, caller in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliCreateWorktree(origin: origin, branch: branch, base: base, caller: caller)
            },
            deleteWorktree: { [weak self] worktree, force, keepBranch, caller in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliDeleteWorktree(worktree, force: force, keepBranch: keepBranch, caller: caller)
            },
            openReviewChanges: { [weak self] worktree in
                guard let self else { return }
                self.focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
                _ = self.openReviewChangesTab(for: worktree)
            },
            openReview: { [weak self] worktree, target, caller in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliOpenReview(worktree: worktree, target: target, caller: caller)
            },
            workspaceCommand: { [weak self] command, caller in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliWorkspace(command, caller: caller)
            },
            previewCommand: { [weak self] command, owner, sessionID in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliPreview(command, owner: owner, isAuthorized: { [weak self] in
                    guard let self, self.previewOwnerIsAvailable(owner) else { return false }
                    guard let sessionID else { return true }
                    guard callers.owner(ofSession: sessionID) == owner else { return false }
                    if self.session(for: sessionID) != nil {
                        return self.isAuthorizedACPWriter(sessionID: sessionID, owner: owner)
                    }
                    return self.tabs.tabs(for: owner).contains {
                        guard case .terminal(let tab) = $0 else { return false }
                        return tab.root.leaves().contains { $0.id == sessionID || $0.sessionId == sessionID }
                    }
                })
            },
            computerCommand: { [weak self] command, sessionID in
                guard let self else { return .error("Alas is not available.") }
                return await self.computerUse.perform(command, sessionID: sessionID)
            },
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }

    private func cliWorkspace(_ command: AlasCLIRequest.WorkspaceCommand, caller: HostCaller) async -> AlasCLIResponse {
        let service = WorkspaceAutomationService(
            store: workspaceStore,
            refreshNavigation: { [weak self] in
                await self?.workspacesManager.refreshCheckoutSnapshots()
            },
            selectCheckout: { [weak self] id in
                self?.selectWorkspaceCheckout(id: id)
            },
            focusMember: { [weak self] checkoutID, memberID in
                guard let self else { return }
                self.selectWorkspaceCheckout(id: checkoutID)
                self.focusWorkspaceCheckoutMember(id: memberID)
            }
        )
        do {
            switch command {
            case .list:
                return try jsonLine(WorkspaceAutomationListResponse(
                    checkouts: try await host.workspaces.list()
                ))
            case .show(let checkoutID):
                return try jsonLine(WorkspaceAutomationShowResponse(
                    checkout: try await host.workspaces.checkout(id: checkoutID)
                ))
            case .switch(let checkoutID):
                try await service.selectCheckout(id: checkoutID)
                return .ok
            case .focus(let checkoutID, let memberID):
                let target = try await service.memberTarget(checkoutID: checkoutID, memberID: memberID)
                await workspacesManager.refreshCheckoutSnapshots()
                try? await host.worktrees.refresh(projectID: target.projectID, caller: caller)
                await workspacesManager.refreshCheckoutSnapshots()
                selectWorkspaceCheckout(id: checkoutID)
                focusWorkspaceCheckoutMember(id: memberID)
                guard workspaceNavigationState.selectedCheckoutID == checkoutID,
                      workspaceNavigationState.focusedCheckoutMemberID == memberID,
                      selectedWorktreeId != nil
                else {
                    throw WorkspaceAutomationError.memberUnavailable
                }
                return .ok
            }
        } catch let error as WorkspaceAutomationError {
            return .errorWithExitCode("\(error.code): \(error.message)", error.exitCode)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func jsonLine<T: Encodable>(_ value: T) throws -> AlasCLIResponse {
        let data = try JSONEncoder.workspaceAutomation.encode(value)
        return .text([String(data: data, encoding: .utf8) ?? "{}"])
    }

    /// Activate a specific harness session: bring the app to front, select
    /// the worktree, activate the terminal or ACP tab hosting `sessionId`.
    /// For terminal tabs the owning leaf is also focused (so keyboard input
    /// follows the user's intent); ACP tabs are single-pane so no leaf
    /// focusing is needed. If the tab is no longer present (session was
    /// closed mid-flight) the worktree is still selected so the user lands
    /// somewhere sensible.
    func activateHarnessSession(projectId: String, worktreeId: String, sessionId: String) {
        focusGlobalWorktree(id: worktreeId, projectId: projectId)
        var matchedTabId: TabID?
        var matchedLeafId: String?
        for tab in tabs.tabs(forWorktree: worktreeId) {
            guard case .terminal(let s) = tab,
                  let leaf = s.root.leaves().first(where: { $0.sessionId == sessionId }) else { continue }
            matchedTabId = tab.id
            matchedLeafId = leaf.id
            break
        }
        // Fall through to ACP tabs: no leaf focusing needed — an ACP tab
        // is a single pane.
        if matchedTabId == nil {
            for tab in tabs.tabs(forWorktree: worktreeId) {
                guard case .acpSession(let s) = tab, s.sessionId == sessionId else { continue }
                matchedTabId = tab.id
                break
            }
        }
        if let tabId = matchedTabId {
            if let leafId = matchedLeafId {
                _ = tabs.setFocusedLeaf(worktreeId: worktreeId, tabId: tabId, leafId: leafId)
            }
            activateWorktreeCenterTab(worktreeId: worktreeId, tabId: tabId)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func activateHarnessSession(owner: SessionOwnerID, sessionId: String) {
        guard case .workspaceCheckout(let checkoutID, _) = owner else { return }
        selectWorkspaceCheckout(id: checkoutID)
        var matchedTabId: TabID?
        var matchedLeafId: String?
        for tab in tabs.tabs(for: owner) {
            guard case .terminal(let state) = tab,
                  let leaf = state.root.leaves().first(where: { $0.sessionId == sessionId }) else { continue }
            matchedTabId = tab.id
            matchedLeafId = leaf.id
            break
        }
        if matchedTabId == nil {
            for tab in tabs.tabs(for: owner) {
                guard case .acpSession(let state) = tab, state.sessionId == sessionId else { continue }
                matchedTabId = tab.id
                break
            }
        }
        if let tabId = matchedTabId {
            if let leafId = matchedLeafId {
                _ = tabs.setFocusedLeaf(owner: owner, tabId: tabId, leafId: leafId)
            }
            tabs.activate(owner: owner, tabId: tabId)
            if let selectedWorktreeId {
                tabs.clearActiveTab(worktreeId: selectedWorktreeId)
                acknowledgeFocusedSessionAttention(worktreeID: selectedWorktreeId, owner: owner, tabID: tabId)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func openTerminalTabPreparingRemoteZmxIfNeeded(
        for worktree: Worktree,
        startupScriptSuffix: String? = nil,
        includeUserStartupScript: Bool = true,
        forceInheritParentEnv: Bool = false,
        environmentOverrides: [String: String] = [:],
        environmentRemovals: Set<String> = [],
        titleOverride: String? = nil,
        runScriptKey: String? = nil,
        isHidden: Bool = false,
        activates: Bool = true,
        promptsForRepoHooks: Bool = true
    ) async throws -> Tab {
        guard await !checkpointTerminalAdmissionDisabledAfterDiscovery(worktreeId: worktree.id) else {
            throw TerminalLaunchError.checkpointRecoveryRequired
        }
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw NSError(domain: "AppState", code: 2)
        }
        try Task.checkCancellation()
        await prepareRemoteAccelerationIfNeeded(for: project)
        try Task.checkCancellation()
        guard !Self.blocksWorktreeSessionAdmission(
            projectsManager.operationState(for: worktree)
        ) else {
            throw TerminalLaunchError.worktreeOperationInProgress
        }
        let repoStartupScript = try await preparedRepoHook(
            event: .sessionOpen,
            project: project,
            worktree: worktree,
            context: .sessionOpen,
            includeUserStartupScript: includeUserStartupScript,
            // Opened for someone not at this screen: approved hooks run,
            // the rest are skipped without asking.
            prompter: promptsForRepoHooks ? nil : .skipping
        )
        return try openTerminalTab(
            for: worktree,
            startupScriptSuffix: startupScriptSuffix,
            repoStartupScript: repoStartupScript,
            includeUserStartupScript: includeUserStartupScript,
            forceInheritParentEnv: forceInheritParentEnv,
            environmentOverrides: environmentOverrides,
            environmentRemovals: environmentRemovals,
            titleOverride: titleOverride,
            runScriptKey: runScriptKey,
            isHidden: isHidden,
            activates: activates
        )
    }

    private func openTerminalSessionForReopen(
        worktree: Worktree,
        project: ProjectConfig,
        forcedCwd: URL?,
        repoStartupScript: String?
    ) throws -> OpenedTerminalSession {
        guard !Self.blocksWorktreeSessionAdmission(
            projectsManager.operationState(for: worktree)
        ) else {
            throw TerminalLaunchError.worktreeOperationInProgress
        }
        let opened: OpenedTerminalSession
        if let terminalSessionOpener {
            opened = try terminalSessionOpener(
                worktree,
                project,
                config.terminal,
                themeStore.current,
                forcedCwd,
                nil,
                true,
                [:],
                []
            )
        } else {
            let leafID = UUID().uuidString
            let session = try terminal.openSession(
                worktree: worktree,
                project: project,
                cfg: config.terminal,
                theme: themeStore.current,
                forcedCwd: forcedCwd,
                repoStartupScript: repoStartupScript,
                leafId: leafID
            )
            opened = .init(id: session.id, foregroundPid: { [weak session] in
                session?.surface.foregroundPid
            })
        }
        harness.detector.register(sessionId: opened.id, pidProvider: opened.foregroundPid)
        return opened
    }

    @discardableResult
    func openTerminalTab(
        for worktree: Worktree,
        startupScriptSuffix: String? = nil,
        repoStartupScript: String? = nil,
        includeUserStartupScript: Bool = true,
        forceInheritParentEnv: Bool = false,
        environmentOverrides: [String: String] = [:],
        environmentRemovals: Set<String> = [],
        titleOverride: String? = nil,
        runScriptKey: String? = nil,
        isHidden: Bool = false,
        activates: Bool = true
    ) throws -> Tab {
        guard !checkpointTerminalAdmissionDisabled(worktreeId: worktree.id) else {
            throw TerminalLaunchError.checkpointRecoveryRequired
        }
        guard !Self.blocksWorktreeSessionAdmission(
            projectsManager.operationState(for: worktree)
        ) else {
            throw TerminalLaunchError.worktreeOperationInProgress
        }
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw NSError(domain: "AppState", code: 2)
        }
        // Single identity for this pane: used with the worktree id to derive
        // the zmx session name, plus the SessionRegistry key, leaf id, persisted
        // sessionId (mirrored to id on encode), and ALAS_SESSION_ID. Generated
        // here so every downstream call site receives the same value.
        let leafId = UUID().uuidString
        var terminalConfig = config.terminal
        if forceInheritParentEnv {
            terminalConfig.inheritParentEnv = true
        }
        let opened: OpenedTerminalSession
        if let terminalSessionOpener {
            opened = try terminalSessionOpener(
                worktree,
                project,
                terminalConfig,
                themeStore.current,
                nil,
                startupScriptSuffix,
                includeUserStartupScript,
                environmentOverrides,
                environmentRemovals
            )
        } else {
            let session = try terminal.openSession(
                worktree: worktree, project: project,
                cfg: terminalConfig, theme: themeStore.current,
                startupScriptSuffix: startupScriptSuffix,
                repoStartupScript: repoStartupScript,
                includeUserStartupScript: includeUserStartupScript,
                environmentOverrides: environmentOverrides,
                environmentRemovals: environmentRemovals,
                leafId: leafId
            )
            opened = OpenedTerminalSession(id: session.id, foregroundPid: { [weak session] in
                session?.surface.foregroundPid
            })
        }
        harness.detector.register(sessionId: opened.id, pidProvider: opened.foregroundPid)
        let title = titleOverride ?? tabs.nextTerminalTitle(
            worktreeId: worktree.id,
            baseTitle: defaultTerminalTitle(for: worktree)
        )
        // `opened.id` is the live session id; for the default opener path
        // above that equals `leafId` (we passed it in). The injected
        // `terminalSessionOpener` (test-only) generates its own id and we
        // honor it for backward-compat with existing tests.
        let tab = tabs.appendTerminal(
            worktreeId: worktree.id, title: title, sessionId: opened.id,
            runScriptKey: runScriptKey, isHidden: isHidden, activates: activates
        )
        return tab
    }

    private func prepareRemoteAccelerationIfNeeded(for project: ProjectConfig) async {
        if let remoteAccelerationPreparer {
            await remoteAccelerationPreparer(project)
            return
        }
        guard let host = project.host else { return }
        if let running = remoteAccelerationTasks[host] {
            await running.value
            return
        }
        if let retryAfter = remoteAccelerationProbeFailures[host] {
            guard retryAfter <= Date() else { return }
            remoteAccelerationProbeFailures.removeValue(forKey: host)
        }
        let shouldAttemptHelper = !attemptedRemoteHelperHosts.contains(host)
        let shouldAttemptZmx = config.terminal.keepSessionsAlive
            && !attemptedRemoteZmxHosts.contains(host)
        guard shouldAttemptHelper || shouldAttemptZmx else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRemoteAccelerationPreparation(host: host)
        }
        remoteAccelerationTasks[host] = task
        await task.value
        remoteAccelerationTasks.removeValue(forKey: host)
    }

    private func performRemoteAccelerationPreparation(host: String) async {
        let shouldAttemptHelper = !attemptedRemoteHelperHosts.contains(host)
        let shouldAttemptZmx = config.terminal.keepSessionsAlive
            && !attemptedRemoteZmxHosts.contains(host)

        guard let capabilities = await RemoteHostCapabilityStore.shared.capabilities(for: host) else {
            remoteAccelerationProbeFailures[host] = Date().addingTimeInterval(remoteAccelerationProbeRetryDelay)
            return
        }
        remoteAccelerationProbeFailures.removeValue(forKey: host)
        if shouldAttemptHelper {
            attemptedRemoteHelperHosts.insert(host)
        }
        if shouldAttemptZmx {
            attemptedRemoteZmxHosts.insert(host)
        }

        guard let resources = Bundle.main.resourceURL else { return }

        let bundledHandshake = RemoteHelperInstaller.bundledHandshake(resourceURL: resources)
        let helperBinary = RemoteHelperInstaller.bundledBinaryPath(
            os: capabilities.os,
            arch: capabilities.arch,
            resourceURL: resources
        )
        let installHelper = shouldAttemptHelper && bundledHandshake.map {
            helperBinary.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true
                && RemoteHelperInstaller.needsInstall(remote: capabilities.helperHandshake, bundled: $0)
        } ?? false
        let zmxBinary = RemoteZmxInstaller.bundledBinaryPath(
            os: capabilities.os,
            arch: capabilities.arch,
            resourceURL: resources
        )
        let installZmx = shouldAttemptZmx
            && !capabilities.hasZmx
            && zmxBinary.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true
        guard installHelper || installZmx else { return }

        let defaults = AlasProfile.userDefaults
        var allowed = Set(defaults.stringArray(forKey: "remote.acceleration.allowedHosts") ?? [])
        let declined = Set(defaults.stringArray(forKey: "remote.acceleration.declinedHosts") ?? [])
            .union(defaults.stringArray(forKey: "remote.zmx.declinedHosts") ?? [])
        if !allowed.contains(host) {
            guard !declined.contains(host), confirmRemoteAcceleration(host: host) else {
                if !declined.contains(host) {
                    var updated = declined
                    updated.insert(host)
                    defaults.set(Array(updated).sorted(), forKey: "remote.acceleration.declinedHosts")
                }
                return
            }
            allowed.insert(host)
            defaults.set(Array(allowed).sorted(), forKey: "remote.acceleration.allowedHosts")
        }

        var installed = false
        if installHelper {
            installed = await RemoteHelperInstaller.install(
                host: host,
                capabilities: capabilities,
                resourceURL: resources
            )
        }
        if installZmx {
            installed = await RemoteZmxInstaller.install(
                host: host,
                capabilities: capabilities,
                resourceURL: resources
            ) || installed
        }
        if installed {
            RemoteHostCapabilityStore.shared.invalidate(host: host)
        }
    }

    private func confirmRemoteAcceleration(host: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable Alas remote acceleration on \(host)?"
        alert.informativeText = "Alas can install its remote helper and, when persistent terminals are enabled, zmx to ~/.alas/bin on \(host)."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Pane splits

    /// Per-tab cache of leaf frames, written by `SplitContainer` during layout
    /// and read by `focusPane`. Keyed by tab id; inner dictionary maps leaf id
    /// to its on-screen rect within the tab's coordinate space.
    @ObservationIgnored
    var terminalLeafFrames: [TabID: [String: CGRect]] = [:]

    /// Split the focused pane of the active terminal tab on `worktreeId`. The
    /// new pane gains focus, inherits the focused pane's current OSC-7 cwd
    /// (falling back to its lastCwd, then the worktree root) and runs a plain
    /// shell — harness state is not inherited.
    func splitFocusedPane(worktreeId: String, axis: SplitAxis) {
        Task { @MainActor in
            await splitFocusedPanePreparingRepoHook(worktreeId: worktreeId, axis: axis)
        }
    }

    private func splitFocusedPanePreparingRepoHook(worktreeId: String, axis: SplitAxis) async {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal(let state) = tab,
              let focused = state.root.find(leafId: state.focusedLeafId)?.leaf,
              let worktree = worktree(withId: worktreeId),
              let project = projects.first(where: { $0.id == worktree.projectId }),
              let focusedSession = terminal.registry.session(for: focused.id) else { return }

        let cwd = focusedSession.surface.currentWorkingDirectory
            ?? focused.lastCwd.map { URL(fileURLWithPath: $0) }
            ?? worktree.path

        do {
            let repoStartupScript = try await preparedRepoHook(
                event: .sessionOpen,
                project: project,
                worktree: worktree,
                context: .sessionOpen
            )
            guard tabs.activeTabId(forWorktree: worktreeId) == activeId,
                  let currentTab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
                  case .terminal(let currentState) = currentTab,
                  currentState.focusedLeafId == focused.id,
                  self.worktree(withId: worktreeId)?.path == worktree.path,
                  projects.first(where: { $0.id == project.id })?.path == project.path,
                  terminal.registry.session(for: focused.id) != nil,
                  !Self.blocksWorktreeSessionAdmission(projectsManager.operationState(for: worktree)) else {
                return
            }

            // Single identity for the new pane: used with the worktree id to
            // derive the zmx session name, plus the SessionRegistry key, leaf
            // id, persisted sessionId, and ALAS_SESSION_ID.
            // Generated here so the registry key matches the leaf ID stored
            // in the split tree.
            let newLeafId = UUID().uuidString
            let session = try terminal.openSession(
                worktree: worktree, project: project,
                cfg: config.terminal, theme: themeStore.current,
                forcedCwd: cwd,
                repoStartupScript: repoStartupScript,
                leafId: newLeafId
            )
            session.registerForegroundPid(with: harness.detector)
            _ = tabs.splitFocusedLeaf(
                worktreeId: worktreeId, tabId: activeId, axis: axis,
                newLeafId: newLeafId, newSessionId: newLeafId
            )
        } catch RepoHookPreflightError.cancelled {
            return
        } catch {
            AlasGhostty.logger.error("splitFocusedPane failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Called when Ghostty reports that the shell in `leafId` has exited.
    /// Locates the owning tab, removes the leaf from the pane tree, and
    /// either closes the tab (when it was the last leaf) or tears down the
    /// dead session and lets the sibling collapse take over the freed space.
    /// Idempotent: if the leaf is no longer in any tab (manual close raced
    /// ahead), returns without side effects.
    func handleTerminalProcessExited(owner: SessionOwnerID, leafId: String, processAlive: Bool) {
        guard !processAlive else { return }
        let authExitHandler = takeACPAuthTerminalExitHandler(terminalId: leafId, owner: owner)
        closePaneForProcessExit(owner: owner, leafId: leafId)
        authExitHandler?()
    }

    private func takeACPAuthTerminalExitHandler(
        terminalId: String,
        owner: SessionOwnerID
    ) -> (() -> Void)? {
        guard let handler = acpAuthTerminalExitHandlers.removeValue(forKey: terminalId),
              tabs.tabs(for: owner).contains(where: {
                  guard case .acpSession(let tab) = $0 else { return false }
                  return tab.sessionId == handler.acpSessionId
              })
        else { return nil }
        return handler.onExit
    }

    /// Legacy worktree compatibility route. Existing terminal callers retain
    /// their raw worktree identity while checkout sessions stay typed.
    func handleTerminalProcessExited(worktreeId: String, leafId: String, processAlive: Bool) {
        handleTerminalProcessExited(owner: .worktree(worktreeId), leafId: leafId, processAlive: processAlive)
    }

    func closePaneForProcessExit(owner: SessionOwnerID, leafId: String) {
        switch owner {
        case .worktree(let worktreeID):
            closePaneForProcessExit(worktreeId: worktreeID, leafId: leafId)
        case .workspaceCheckout:
            let owningTabID = tabs.tabs(for: owner).first { tab in
                guard case .terminal(let state) = tab else { return false }
                return state.root.find(leafId: leafId) != nil
            }?.id
            guard let tabID = owningTabID else { return }
            harness.detector.unregister(sessionId: leafId)
            harness.forgetSession(leafId)
            guard let outcome = tabs.removeLeaf(owner: owner, tabId: tabID, leafId: leafId) else { return }
            switch outcome {
            case .tabRemoved:
                terminal.closeSession(id: leafId, owner: owner)
                tabs.close(owner: owner, tabId: tabID)
            case .leafRemoved:
                terminal.closeSession(id: leafId, owner: owner)
            }
        }
    }

    func closePaneForProcessExit(worktreeId: String, leafId: String) {
        let owningTabId = tabs.tabs(forWorktree: worktreeId).first { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.root.find(leafId: leafId) != nil
        }?.id
        guard let tabId = owningTabId else { return }
        core.runHostExited(sessionID: leafId)
        guard let outcome = tabs.removeLeaf(
            worktreeId: worktreeId, tabId: tabId, leafId: leafId
        ) else { return }
        switch outcome {
        case .tabRemoved:
            closeTab(worktreeId: worktreeId, tabId: tabId, cancelRunScriptMonitors: false)
        case .leafRemoved:
            closeTerminalSession(
                id: leafId,
                worktreeId: worktreeId,
                projectPath: projectPath(forWorktreeId: worktreeId)
            )
        }
    }

    private func closeTerminalSession(id: String, worktreeId: String, projectPath: String?) {
        acpAuthTerminalExitHandlers.removeValue(forKey: id)
        harness.detector.unregister(sessionId: id)
        harness.forgetSession(id)
        terminal.closeSession(id: id, worktreeId: worktreeId, projectPath: projectPath)
    }

    /// Close the focused pane. If it was the last leaf, also closes the tab
    /// via the existing close-tab path (preserves today's ⌘W-on-unsplit
    /// behavior).
    func closeFocusedPane(worktreeId: String, projectId: String? = nil) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal = tab else { return }
        guard let outcome = tabs.removeFocusedLeaf(worktreeId: worktreeId, tabId: activeId) else { return }
        if case .tabRemoved = outcome {
            requestCloseTab(worktreeId: worktreeId, projectId: projectId, tabId: activeId)
        } else {
            closeRemovedTerminalLeaf(outcome.closedLeafId, worktreeId: worktreeId)
        }
    }

    /// A peer terminating console `leafId`: closes its pane as a local close
    /// does, and its tab, with reopen history, when it was the last pane. No
    /// confirmation here: the requesting Mac already asked its user.
    func closeTerminalPaneWithoutConfirmation(leafId: String) {
        guard let owner = terminal.registry.session(for: leafId)?.owner else { return }
        let owningTab = tabs.tabs(for: owner).first { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.root.find(leafId: leafId) != nil
        }
        if case .worktree(let worktreeId) = owner, let owningTab {
            switch tabs.removeLeaf(worktreeId: worktreeId, tabId: owningTab.id, leafId: leafId) {
            case .tabRemoved:
                // A hidden tab (a peer's shell, a hidden run) was never on
                // screen, so "Reopen Closed Tab" must not bring it back.
                if owningTab.isHiddenRunTab {
                    closeTab(worktreeId: worktreeId, tabId: owningTab.id)
                } else {
                    closeTabRecordingHistory(worktreeId: worktreeId, projectId: nil, tab: owningTab)
                }
            case .leafRemoved:
                closeRemovedTerminalLeaf(leafId, worktreeId: worktreeId)
            case nil:
                break
            }
        } else if owningTab != nil {
            closePaneForProcessExit(owner: owner, leafId: leafId)
        }
        // A console outside any tab has no pane; end its session directly.
        if terminal.registry.session(for: leafId) != nil {
            acpAuthTerminalExitHandlers.removeValue(forKey: leafId)
            harness.detector.unregister(sessionId: leafId)
            harness.forgetSession(leafId)
            terminal.closeSession(id: leafId, owner: owner)
        }
    }

    /// Tears down a pane already removed from its split tab.
    private func closeRemovedTerminalLeaf(_ leafId: String, worktreeId: String) {
        let authExitHandler = takeACPAuthTerminalExitHandler(terminalId: leafId, owner: .worktree(worktreeId))
        core.runHostClosed(sessionID: leafId)
        closeTerminalSession(id: leafId, worktreeId: worktreeId, projectPath: projectPath(forWorktreeId: worktreeId))
        authExitHandler?()
    }

    /// "Terminate All Terminal Sessions" menu action. Confirms with the user,
    /// then closes every terminal tab across every worktree (which kills
    /// the underlying zmx session) and sweeps any persisted-but-not-yet-
    /// restored leaves this instance owns.
    @discardableResult
    func terminateAllTerminalSessions() -> Bool {
        let snapshot = terminalTerminationSnapshot()
        let alert = NSAlert()
        alert.messageText = "Terminate All Terminal Sessions"
        alert.informativeText = "Terminate \(snapshot.sessionCount) terminal session(s)? This will kill any agent or process currently running in them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        terminateAllTerminalSessionsAfterConfirmation(snapshot: snapshot)
        return true
    }

#if DEBUG
    func terminateAllTerminalSessionsAfterConfirmationForTesting() {
        terminateAllTerminalSessionsAfterConfirmation(snapshot: terminalTerminationSnapshot())
    }

    func terminateAllTerminalSessionsAfterConfirmationWithStaleEmptySnapshotForTesting() {
        terminateAllTerminalSessionsAfterConfirmation(snapshot: TerminalTerminationSnapshot(
            terminalTabs: [],
            checkoutTerminalTabs: [],
            persistedSessions: [],
            sessionCount: 0
        ))
    }
#endif

    private struct TerminalTerminationSnapshot {
        var terminalTabs: [(worktreeId: String, tabId: TabID)]
        var checkoutTerminalTabs: [(owner: SessionOwnerID, tabId: TabID)]
        var persistedSessions: [TerminalSessionIdentity]
        var sessionCount: Int
    }

    private func terminalTerminationSnapshot() -> TerminalTerminationSnapshot {
        // Snapshot which terminal tabs exist so the confirm sheet count stays
        // accurate even if state changes between rendering and confirming.
        let terminalTabs: [(worktreeId: String, tabId: TabID)] = projects
            .flatMap { projectsManager.worktrees(projectId: $0.id) }
            .flatMap { worktree in
                tabs.tabs(forWorktree: worktree.id).compactMap { tab -> (String, TabID)? in
                    guard case .terminal = tab else { return nil }
                    return (worktree.id, tab.id)
                }
            }
        let checkoutTerminalTabs: [(owner: SessionOwnerID, tabId: TabID)] = workspacesManager.checkouts
            .flatMap { checkout in
                let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
                return tabs.tabs(for: owner).compactMap { tab -> (SessionOwnerID, TabID)? in
                    guard case .terminal = tab else { return nil }
                    return (owner, tab.id)
                }
            }
        let persistedSessions = allPersistedTerminalSessions()
        // Count individual leaves, not tabs — a single tab with split panes
        // contains multiple leaves and `terminateAll` kills every one. Union
        // with the live registry catches any session not yet flushed to disk.
        let sessionCount = Set(persistedSessions)
            .union(terminal.registry.all.map {
                TerminalSessionIdentity(owner: $0.owner, leafId: $0.id)
            })
            .count

        return TerminalTerminationSnapshot(
            terminalTabs: terminalTabs,
            checkoutTerminalTabs: checkoutTerminalTabs,
            persistedSessions: persistedSessions,
            sessionCount: sessionCount
        )
    }

    private func terminateAllTerminalSessionsAfterConfirmation(snapshot: TerminalTerminationSnapshot) {
        let confirmedSnapshot = terminalTerminationSnapshot()
        cancelPendingRunScriptLaunches()
        var seenTerminalTabs = Set<String>()
        let terminalTabs = (snapshot.terminalTabs + confirmedSnapshot.terminalTabs).filter {
            seenTerminalTabs.insert("\($0.worktreeId):\($0.tabId)").inserted
        }
        var seenCheckoutTerminalTabs = Set<String>()
        let checkoutTerminalTabs = (snapshot.checkoutTerminalTabs + confirmedSnapshot.checkoutTerminalTabs).filter {
            seenCheckoutTerminalTabs.insert("\($0.owner.storageKey):\($0.tabId)").inserted
        }
        let persistedSessions = Array(Set(snapshot.persistedSessions).union(confirmedSnapshot.persistedSessions))
        for (worktreeId, tabId) in terminalTabs {
            closeTab(worktreeId: worktreeId, tabId: tabId)
        }
        for (owner, tabId) in checkoutTerminalTabs {
            closeSharedSessionTab(owner: owner, tabID: tabId)
        }
        // Also kill persisted leaves whose tab the user never displayed
        // this run — closeTab only handles registered sessions, but we
        // own those persisted leaves too. Scoped to OUR instance's known
        // leaves so we don't trample sessions owned by a concurrently-
        // running Alas process under the same ZMX_DIR.
        terminal.terminateAll(additionalSessions: persistedSessions)
    }

    /// All terminal sessions persisted under this Alas instance's projects.
    private func allPersistedTerminalSessions() -> [TerminalSessionIdentity] {
        let worktreeSessions = projects.flatMap { project in
            projectsManager.worktrees(projectId: project.id).flatMap { worktree in
                tabs.tabs(forWorktree: worktree.id).flatMap { tab -> [TerminalSessionIdentity] in
                    guard case .terminal(let state) = tab else { return [] }
                    return state.root.leaves().map {
                        TerminalSessionIdentity(
                            worktreeId: worktree.id,
                            projectPath: project.path,
                            leafId: $0.id
                        )
                    }
                }
            }
        }
        let checkoutSessions = workspacesManager.checkouts.flatMap { checkout in
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            return tabs.tabs(for: owner).flatMap { tab -> [TerminalSessionIdentity] in
                guard case .terminal(let state) = tab else { return [] }
                return state.root.leaves().map {
                    TerminalSessionIdentity(owner: owner, leafId: $0.id)
                }
            }
        }
        return worktreeSessions + checkoutSessions
    }

    /// Move focus to the geometrically nearest leaf in `direction`. No-op when
    /// no candidate exists (no wrap-around).
    func focusPane(worktreeId: String, direction: PaneFocusDirection) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal(let state) = tab,
              let frames = terminalLeafFrames[activeId],
              let next = PaneFocusFinder.nearestLeaf(
                from: state.focusedLeafId, direction: direction, frames: frames
              ) else { return }
        _ = tabs.setFocusedLeaf(worktreeId: worktreeId, tabId: activeId, leafId: next)
        acknowledgeFocusedSessionAttention(worktreeID: worktreeId, tabID: activeId)
    }

    func focusPane(worktreeId: String, sharedSessionOwner: SessionOwnerID?, direction: PaneFocusDirection) {
        guard let owner = sharedSessionOwner,
              activeSharedCheckoutTerminal(worktreeId: worktreeId, owner: owner) != nil,
              let activeId = centerTabComposition(
                  focusedWorktreeID: worktreeId,
                  sharedSessionOwner: owner
              ).activeId,
              let tab = tabs.tabs(for: owner).first(where: { $0.id == activeId }),
              case .terminal(let state) = tab,
              let frames = terminalLeafFrames[activeId],
              let next = PaneFocusFinder.nearestLeaf(
                from: state.focusedLeafId, direction: direction, frames: frames
              )
        else {
            focusPane(worktreeId: worktreeId, direction: direction)
            return
        }
        _ = tabs.setFocusedLeaf(owner: owner, tabId: activeId, leafId: next)
        acknowledgeFocusedSessionAttention(worktreeID: worktreeId, owner: owner, tabID: activeId)
    }

    /// Resize the focused leaf's enclosing split by ±0.05 toward `direction`.
    /// Picks the innermost split on the focused-leaf's path whose axis matches
    /// the direction's axis; nudges its fraction (positive when the focused
    /// pane is the first child and direction is right/down).
    func resizePane(worktreeId: String, direction: PaneFocusDirection) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal(let state) = tab,
              let pathLeaf = state.root.find(leafId: state.focusedLeafId) else { return }
        let axis: SplitAxis = (direction == .left || direction == .right) ? .vertical : .horizontal
        guard let target = innermostSplit(matching: axis, path: pathLeaf.path, in: state.root) else { return }
        let isFirstChildOfTarget = isLeafInFirstChild(of: target, leafId: state.focusedLeafId)
        let delta = 0.05
        let signed: Double = {
            switch direction {
            case .right, .down: return isFirstChildOfTarget ? delta : -delta
            case .left, .up:    return isFirstChildOfTarget ? -delta : delta
            }
        }()
        let newFraction = target.fraction + signed
        _ = tabs.setSplitFraction(worktreeId: worktreeId, tabId: activeId, splitId: target.id, fraction: newFraction)
    }

    func resizePane(worktreeId: String, sharedSessionOwner: SessionOwnerID?, direction: PaneFocusDirection) {
        guard let owner = sharedSessionOwner,
              activeSharedCheckoutTerminal(worktreeId: worktreeId, owner: owner) != nil,
              let activeId = centerTabComposition(
                  focusedWorktreeID: worktreeId,
                  sharedSessionOwner: owner
              ).activeId,
              let tab = tabs.tabs(for: owner).first(where: { $0.id == activeId }),
              case .terminal(let state) = tab,
              let pathLeaf = state.root.find(leafId: state.focusedLeafId)
        else {
            resizePane(worktreeId: worktreeId, direction: direction)
            return
        }
        let axis: SplitAxis = (direction == .left || direction == .right) ? .vertical : .horizontal
        guard let target = innermostSplit(matching: axis, path: pathLeaf.path, in: state.root) else { return }
        let isFirstChildOfTarget = isLeafInFirstChild(of: target, leafId: state.focusedLeafId)
        let delta = 0.05
        let signed: Double = {
            switch direction {
            case .right, .down: return isFirstChildOfTarget ? delta : -delta
            case .left, .up:    return isFirstChildOfTarget ? -delta : delta
            }
        }()
        let newFraction = target.fraction + signed
        _ = tabs.setSplitFraction(owner: owner, tabId: activeId, splitId: target.id, fraction: newFraction)
    }

    private func activeSharedCheckoutTerminal(worktreeId: String, owner: SessionOwnerID?) -> WorkspaceCheckout? {
        guard let owner,
              case .workspaceCheckout(let checkoutID, _) = owner,
              let checkout = selectedWorkspaceCheckout,
              checkout.id == checkoutID,
              let activeId = centerTabComposition(
                  focusedWorktreeID: worktreeId,
                  sharedSessionOwner: owner
              ).activeId,
              tabs.tabs(for: owner).contains(where: {
                  guard $0.id == activeId,
                        case .terminal = $0
                  else { return false }
                  return true
              })
        else { return nil }
        return checkout
    }

    /// ⌘W router: if the active tab is a multi-pane terminal, close the focused
    /// pane; otherwise fall through to the existing tab-close behavior.
    func handleCloseShortcut(worktreeId: String, projectId: String? = nil) {
        if let activeId = tabs.activeTabId(forWorktree: worktreeId),
           let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
           case .terminal(let state) = tab,
           case .split = state.root {
            closeFocusedPane(worktreeId: worktreeId, projectId: projectId)
            return
        }
        if let activeId = tabs.activeTabId(forWorktree: worktreeId) {
            requestCloseTab(worktreeId: worktreeId, projectId: projectId, tabId: activeId)
        }
    }

    func handleCloseCenterShortcut(
        worktreeId: String?,
        projectId: String? = nil,
        sharedSessionOwner: SessionOwnerID? = nil
    ) {
        guard let worktreeId else { return }
        if let sharedSessionOwner,
           let activeId = centerTabComposition(
               focusedWorktreeID: worktreeId,
               sharedSessionOwner: sharedSessionOwner
           ).activeId,
           tabs.tabs(for: sharedSessionOwner).contains(where: { $0.id == activeId }) {
            requestCloseSharedSessionTab(owner: sharedSessionOwner, tabID: activeId)
            return
        }
        handleCloseShortcut(worktreeId: worktreeId, projectId: projectId)
    }

    @discardableResult
    func activateCenterTabNumber(
        _ number: Int,
        worktreeId: String?,
        sharedSessionOwner: SessionOwnerID? = nil
    ) -> TabID? {
        guard number > 0 else { return nil }
        guard let worktreeId else { return nil }
        let composition = centerTabComposition(
            focusedWorktreeID: worktreeId,
            sharedSessionOwner: sharedSessionOwner
        )
        let index = number - 1
        guard composition.tabs.indices.contains(index) else { return nil }
        return activateCenterTab(
            composition.tabs[index].id,
            worktreeId: worktreeId,
            sharedSessionOwner: sharedSessionOwner
        )
    }

    @discardableResult
    func activateAdjacentCenterTab(
        _ direction: CenterTabNavigationDirection,
        worktreeId: String?,
        sharedSessionOwner: SessionOwnerID? = nil
    ) -> TabID? {
        guard let worktreeId else { return nil }
        let composition = centerTabComposition(
            focusedWorktreeID: worktreeId,
            sharedSessionOwner: sharedSessionOwner
        )
        guard let tabID = composition.adjacentTabID(in: direction) else { return nil }
        return activateCenterTab(tabID, worktreeId: worktreeId, sharedSessionOwner: sharedSessionOwner)
    }

    private func activateCenterTab(
        _ tabID: TabID,
        worktreeId: String,
        sharedSessionOwner: SessionOwnerID? = nil
    ) -> TabID? {
        activateComposedCenterTab(
            worktreeID: worktreeId,
            sharedSessionOwner: sharedSessionOwner,
            tabID: tabID
        )
        return tabID
    }

    /// Walk down `path` collecting splits; return the innermost one whose
    /// axis matches `axis`. `path` is the list of split ids from root to (but
    /// not including) the focused leaf.
    private func innermostSplit(matching axis: SplitAxis, path: [String], in root: PaneNode) -> PaneSplit? {
        var current: PaneNode = root
        var match: PaneSplit? = nil
        for (index, splitId) in path.enumerated() {
            guard case .split(let s) = current, s.id == splitId else { return match }
            if s.axis == axis { match = s }
            let nextId: String? = (index + 1 < path.count) ? path[index + 1] : nil
            if let next = nextId {
                guard let child = s.children.first(where: { containsNode(id: next, in: $0) }) else { return match }
                current = child
            } else {
                return match
            }
        }
        return match
    }

    private func isLeafInFirstChild(of split: PaneSplit, leafId: String) -> Bool {
        split.children.first?.find(leafId: leafId) != nil
    }

    private func containsNode(id: String, in node: PaneNode) -> Bool {
        if node.id == id { return true }
        if case .split(let s) = node {
            return s.children.contains(where: { containsNode(id: id, in: $0) })
        }
        return false
    }

    /// Walk every leaf in the tab's tree and recreate any session whose
    /// `TerminalSession` is no longer alive (e.g., after relaunch).
    ///
    /// **Partial-failure contract:** if `openSession` throws midway through the
    /// walk, leaves processed up to that point have already been persisted with
    /// their new sessionIds. Re-calling this method is safe — already-restored
    /// leaves are skipped, and the failing leaf is retried.

    @discardableResult
    func restoreTerminalTabIfNeededAsync(worktreeId: String, tabId: TabID) async throws -> Tab? {
        await awaitZmxMigration()
        await retryZmxMigration(forSessions: zmxSessionNamesAwaitingRestore(owner: .worktree(worktreeId), tabId: tabId))
        guard await !checkpointTerminalAdmissionDisabledAfterDiscovery(worktreeId: worktreeId) else {
            throw TerminalLaunchError.checkpointRecoveryRequired
        }
        let legacySessionInfos = await legacySessionInfosForTerminalRestore(
            worktreeId: worktreeId,
            tabId: tabId
        )
        return try await restoreTerminalTabIfNeeded(
            worktreeId: worktreeId,
            tabId: tabId,
            legacySessionInfos: legacySessionInfos
        )
    }

    @discardableResult
    func restoreTerminalTabIfNeededAsync(owner: SessionOwnerID, tabId: TabID) async throws -> Tab? {
        await awaitZmxMigration()
        switch owner {
        case .worktree(let worktreeID):
            return try await restoreTerminalTabIfNeededAsync(worktreeId: worktreeID, tabId: tabId)
        case .workspaceCheckout(let checkoutID, _):
            await retryZmxMigration(forSessions: zmxSessionNamesAwaitingRestore(owner: owner, tabId: tabId))
            return try await restoreCheckoutTerminalTabIfNeeded(checkoutID: checkoutID, owner: owner, tabID: tabId)
        }
    }

    @discardableResult
    private func restoreCheckoutTerminalTabIfNeeded(
        checkoutID: UUID,
        owner: SessionOwnerID,
        tabID: TabID
    ) async throws -> Tab? {
        guard let checkout = await workspaceStore.checkout(id: checkoutID),
              checkout.archivedAt == nil,
              checkout.operation == .idle,
              owner == SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        else { return nil }
        guard await !checkpointTerminalAdmissionDisabledAfterDiscovery(for: checkout) else {
            throw TerminalLaunchError.checkpointRecoveryRequired
        }
        guard let tab = tabs.tabs(for: owner).first(where: { $0.id == tabID }),
              case .terminal(let state) = tab else { return nil }
        guard await workspaceCheckoutManifestMatches(checkout) else { return nil }

        if !config.terminal.keepSessionsAlive {
            let hasLiveLeaf = state.root.leaves()
                .contains { terminal.registry.session(for: $0.id) != nil }
            if !hasLiveLeaf {
                closeSharedSessionTab(owner: owner, tabID: tabID)
                return nil
            }
        }

        let context = workspaceTerminalContext(for: checkout)
        for leaf in state.root.leaves() {
            if terminal.registry.session(for: leaf.id) != nil { continue }
            if case .local = context.executionLocation,
               zmxSessionIsLeftPreFreeze(ZmxSessionName.derive(owner: owner, leafId: leaf.id)) { continue }
            let forcedCwd = await validatedWorkspaceCheckoutRestorationCwd(
                savedPath: leaf.lastCwd,
                context: context,
                savedLocation: leaf.lastCwdLocation
            )
            let session = try terminal.openCheckoutSession(
                context: context,
                cfg: config.terminal,
                theme: themeStore.current,
                forcedCwd: forcedCwd,
                forcedCwdLocation: leaf.lastCwdLocation,
                remoteCwdAlreadyValidated: forcedCwd != nil,
                leafId: leaf.id
            )
            session.registerForegroundPid(with: harness.detector)
        }
        return tabs.tabs(for: owner).first(where: { $0.id == tabID })
    }

    private func legacySessionInfosForTerminalRestore(
        worktreeId: String,
        tabId: TabID
    ) async -> [ZmxSessionInfo]? {
        guard config.terminal.keepSessionsAlive,
              terminal.zmxClient.isAvailable,
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab,
              state.root.leaves().contains(where: { terminal.registry.session(for: $0.id) == nil })
        else { return nil }

        let client = terminal.zmxClient
        return await Task.detached(priority: .utility) {
            client.listSessionInfos()
        }.value
    }

    private func restoreTerminalTabIfNeeded(
        worktreeId: String,
        tabId: TabID,
        legacySessionInfos: [ZmxSessionInfo]?
    ) async throws -> Tab? {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab,
              let worktree = worktree(withId: worktreeId),
              let project = projects.first(where: { $0.id == worktree.projectId }) else { return nil }

        // When the user has opted out of cross-quit persistence and none of
        // the tab's leaves have a live session (the only way to reach this
        // branch is a relaunch where the registry is empty for these
        // leaves), drop the persisted tab instead of opening fresh shells.
        // Otherwise the toggle would only strip the `zmx attach` wrapper and
        // still resurrect a plain shell in the same tab slot on every
        // relaunch.
        //
        // Use `closeTab` (not `tabs.close`) so harness detector state is
        // unregistered and `terminal.closeSession` issues the best-effort
        // `zmx kill` for each leaf — otherwise daemon-side sessions left
        // over from a previous keep-alive=true run stay orphaned with no
        // tab left to control them.
        if !config.terminal.keepSessionsAlive {
            let hasLiveLeaf = state.root.leaves()
                .contains { terminal.registry.session(for: $0.id) != nil }
            if !hasLiveLeaf {
                closeTab(worktreeId: worktreeId, tabId: tabId)
                return nil
            }
        }

        guard state.root.leaves().contains(where: { terminal.registry.session(for: $0.id) == nil }) else {
            return tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId })
        }
        let repoStartupScript = try await preparedRepoHook(
            event: .sessionOpen,
            project: project,
            worktree: worktree,
            context: .sessionOpen
        )
        guard let currentTab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let currentState) = currentTab,
              self.worktree(withId: worktreeId)?.path == worktree.path,
              projects.first(where: { $0.id == project.id })?.path == project.path else { return nil }
        guard !Self.blocksWorktreeSessionAdmission(projectsManager.operationState(for: worktree)) else {
            throw TerminalLaunchError.worktreeOperationInProgress
        }
        let leavesToRestore = currentState.root.leaves().filter { terminal.registry.session(for: $0.id) == nil }
        guard !leavesToRestore.isEmpty else { return currentTab }
        for leaf in leavesToRestore {
            // Idempotent: skip leaves whose session is already alive in the
            // registry. The leaf's id is the stable identity used as both
            // the registry key and the zmx session name suffix; we no longer
            // generate a fresh sessionId on each restore.
            if terminal.registry.session(for: leaf.id) != nil { continue }

            let forcedCwd = leaf.lastCwd.map { URL(fileURLWithPath: $0) }
            let allowLegacyAttach = config.terminal.keepSessionsAlive
            let preResolvedZmxSessionName = legacySessionInfos.map {
                TerminalService.resolveSessionNameForAttach(
                    worktreeId: worktree.id,
                    projectPath: project.path,
                    leafId: leaf.id,
                    allowLegacy: allowLegacyAttach,
                    legacySessionInfos: $0
                )
            }
            // A pre-freeze daemon would attach as a stuck terminal; leave the
            // pane without a session until a later restore recovers it.
            if project.host == nil,
               zmxSessionIsLeftPreFreeze(
                   preResolvedZmxSessionName ?? ZmxSessionName.derive(worktreeId: worktree.id, leafId: leaf.id)
               ) { continue }
            if currentState.runScriptLeafId == leaf.id {
                let reattachingPersistedSession = preResolvedZmxSessionName.map { sessionName in
                    legacySessionInfos?.contains { $0.name == sessionName } ?? false
                } ?? false
                if !reattachingPersistedSession {
                    _ = tabs.clearRunScriptMarker(worktreeId: worktreeId, tabId: tabId)
                }
            }
            let session = try terminal.openSession(
                worktree: worktree, project: project,
                cfg: config.terminal, theme: themeStore.current,
                forcedCwd: forcedCwd,
                repoStartupScript: repoStartupScript,
                leafId: leaf.id,
                allowLegacyAttach: allowLegacyAttach,
                preResolvedZmxSessionName: preResolvedZmxSessionName
            )
            session.registerForegroundPid(with: harness.detector)
        }
        return tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId })
    }

    func saveActiveTab(worktreeId: String) {
        Task {
            guard await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId) else { return }
            _ = await tabs.saveActiveAsync(worktreeId: worktreeId, config: config.code)
        }
    }

    func saveAllTabs() {
        Task { @MainActor in
            var roots: [String: URL] = [:]
            for project in projects {
                for worktree in projectsManager.worktrees(projectId: project.id) {
                    guard await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktree.id) else { continue }
                    roots[worktree.id] = roots[worktree.id] ?? worktree.path
                }
            }
            let errors = await tabs.saveAllAwaitingRemote(worktreeRoots: roots, allowedWorktreeIDs: Set(roots.keys))
            guard !errors.isEmpty else { return }
            showFileActionError(
                title: "Save All Failed",
                message: "\(errors.count) file\(errors.count == 1 ? "" : "s") could not be saved."
            )
        }
    }

    func revertActiveTab(worktreeId: String) {
        _ = tabs.revertActive(worktreeId: worktreeId)
    }

    func newFile(in worktreeId: String) {
        guard let (project, worktree) = projectAndWorktree(withWorktreeId: worktreeId) else { return }
        if let host = project.host {
            guard let relativePath = promptForRemoteRelativePath(
                title: "New File",
                message: "Enter a path relative to the remote worktree.",
                defaultValue: "untitled.txt",
                confirmTitle: "Create",
                errorTitle: "New File Failed"
            ) else { return }
            guard !tabs.hasEditor(worktreeId: worktreeId, relativePath: relativePath) else {
                showFileActionError(title: "New File Failed", message: "That file is already open in another editor tab.")
                return
            }
            Task { @MainActor [weak self] in
                guard let self,
                      await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
                else { return }
                do {
                    try await Self.createRemoteEmptyFile(host: host, worktreeRoot: worktree.path, relativePath: relativePath)
                    self.openFile(relativePath: relativePath, worktreeId: worktreeId)
                } catch {
                    self.showFileActionError(title: "New File Failed", message: error.localizedDescription)
                }
            }
            return
        }
        let panel = NSSavePanel()
        panel.title = "New File"
        panel.message = "Choose where to create the new file."
        panel.directoryURL = worktree.path
        panel.nameFieldStringValue = "untitled.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
            else { return }
            do {
                let relativePath = try self.relativePath(for: url, in: worktree.path)
                if FileManager.default.fileExists(atPath: url.path) {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url, options: .withoutOverwriting)
                self.openFile(relativePath: relativePath, worktreeId: worktreeId)
            } catch {
                self.showFileActionError(title: "New File Failed", message: error.localizedDescription)
            }
        }
    }

    func newFile(
        in worktreeId: String,
        directoryPath: String,
        onCreated: @escaping @MainActor () -> Void
    ) {
        guard let (project, worktree) = projectAndWorktree(withWorktreeId: worktreeId),
              let name = promptForChildName(title: "New File", defaultValue: "untitled.txt")
        else { return }
        let relativePath = Self.childPath(name: name, directoryPath: directoryPath)

        if let host = project.host {
            Task { @MainActor [weak self] in
                guard let self,
                      await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
                else { return }
                do {
                    try await Self.createRemoteEmptyFile(
                        host: host,
                        worktreeRoot: worktree.path,
                        relativePath: relativePath
                    )
                    self.openFile(relativePath: relativePath, worktreeId: worktreeId)
                    onCreated()
                } catch {
                    self.showFileActionError(title: "New File Failed", message: error.localizedDescription)
                }
            }
            return
        }

        let url = worktree.path.appendingPathComponent(relativePath)
        Task { @MainActor [weak self] in
            guard let self,
                  await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
            else { return }
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                self.openFile(relativePath: relativePath, worktreeId: worktreeId)
                onCreated()
            } catch {
                self.showFileActionError(title: "New File Failed", message: error.localizedDescription)
            }
        }
    }

    func newFolder(
        in worktreeId: String,
        directoryPath: String,
        onCreated: @escaping @MainActor () -> Void
    ) {
        guard let (project, worktree) = projectAndWorktree(withWorktreeId: worktreeId),
              let name = promptForChildName(title: "New Folder", defaultValue: "New Folder")
        else { return }
        let relativePath = Self.childPath(name: name, directoryPath: directoryPath)

        if let host = project.host {
            Task { @MainActor [weak self] in
                guard let self,
                      await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
                else { return }
                do {
                    try await Self.createRemoteDirectory(
                        host: host,
                        worktreeRoot: worktree.path,
                        relativePath: relativePath
                    )
                    onCreated()
                } catch {
                    self.showFileActionError(title: "New Folder Failed", message: error.localizedDescription)
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self,
                  await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
            else { return }
            do {
                try FileManager.default.createDirectory(
                    at: worktree.path.appendingPathComponent(relativePath, isDirectory: true),
                    withIntermediateDirectories: false
                )
                onCreated()
            } catch {
                self.showFileActionError(title: "New Folder Failed", message: error.localizedDescription)
            }
        }
    }

    nonisolated static func childPath(name: String, directoryPath: String) -> String {
        directoryPath.isEmpty ? name : "\(directoryPath)/\(name)"
    }

    nonisolated static func normalizedChildName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw NSError(
                domain: "AppState",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Enter a name without path separators."]
            )
        }
        return name
    }

    private func promptForChildName(title: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Enter a name."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            return try Self.normalizedChildName(field.stringValue)
        } catch {
            showFileActionError(title: "Invalid Name", message: error.localizedDescription)
            return nil
        }
    }

    nonisolated private static func createRemoteEmptyFile(host: String, worktreeRoot: URL, relativePath: String) async throws {
        let path = worktreeRoot.appendingPathComponent(relativePath).path
        try await RemotePathContainment.verifyRemoteContainment(host: host, path: path, worktreeRoot: worktreeRoot.path)
        let result = try await RemoteExec.run(host: host, cwd: nil, command: RemoteFileOps.createEmptyFileCommand(path: path))
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        guard result.exitCode == 0 else {
            if result.exitCode == 1 {
                throw CocoaError(.fileWriteFileExists)
            }
            throw RemoteFileAccessError.writeFailed(result.stderr)
        }
    }

    nonisolated private static func createRemoteDirectory(host: String, worktreeRoot: URL, relativePath: String) async throws {
        let path = worktreeRoot.appendingPathComponent(relativePath).path
        try await RemotePathContainment.verifyRemoteContainment(host: host, path: path, worktreeRoot: worktreeRoot.path)
        let result = try await RemoteExec.run(host: host, cwd: nil, command: RemoteFileOps.createDirectoryCommand(path: path))
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        guard result.exitCode == 0 else {
            throw RemoteFileAccessError.writeFailed(result.stderr)
        }
    }

    func saveActiveTabAs(worktreeId: String) {
        guard !checkpointFileWritesDisabled(worktreeId: worktreeId) else { return }
        guard let worktree = worktree(withId: worktreeId),
              let context = tabs.activeEditorContext(worktreeId: worktreeId) else { return }
        let currentURL = worktree.path.appendingPathComponent(context.tab.relativePath)
        if context.buffer.isRemote {
            guard let relativePath = promptForRemoteRelativePath(
                title: "Save As",
                message: "Enter a path relative to the remote worktree.",
                defaultValue: context.tab.relativePath,
                confirmTitle: "Save",
                errorTitle: "Save As Failed"
            ) else { return }
            guard !tabs.hasEditor(worktreeId: worktreeId, relativePath: relativePath, excluding: context.tab.id) else {
                showFileActionError(title: "Save As Failed", message: "That file is already open in another editor tab.")
                return
            }
            Task { @MainActor [weak self] in
                do {
                    guard let self,
                          await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
                    else { return }
                    try await context.buffer.saveAsRemote(relativePath: relativePath)
                    _ = self.tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
                } catch {
                    self?.showFileActionError(title: "Save As Failed", message: error.localizedDescription)
                }
            }
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.message = "Choose the new path for this editor buffer."
        panel.directoryURL = currentURL.deletingLastPathComponent()
        panel.nameFieldStringValue = currentURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
            else { return }
            do {
                let relativePath = try self.relativePath(for: url, in: worktree.path)
                guard !self.tabs.hasEditor(worktreeId: worktreeId, relativePath: relativePath, excluding: context.tab.id) else {
                    self.showFileActionError(title: "Save As Failed", message: "That file is already open in another editor tab.")
                    return
                }
                try context.buffer.saveAs(relativePath: relativePath)
                _ = self.tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
            } catch {
                self.showFileActionError(title: "Save As Failed", message: error.localizedDescription)
            }
        }
    }

    private func promptForRemoteRelativePath(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String,
        errorTitle: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            return try Self.normalizedRemoteRelativePath(field.stringValue)
        } catch {
            showFileActionError(title: errorTitle, message: error.localizedDescription)
            return nil
        }
    }

    nonisolated static func normalizedRemoteRelativePath(_ raw: String) throws -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else {
            throw NSError(
                domain: "AppState",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Enter a relative path inside the remote worktree."]
            )
        }
        return normalized
    }

    func renameActiveFile(worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId),
              let context = tabs.activeEditorContext(worktreeId: worktreeId) else { return }
        let currentURL = worktree.path.appendingPathComponent(context.tab.relativePath)
        if context.buffer.isRemote {
            guard let relativePath = promptForRemoteRelativePath(
                title: "Rename File",
                message: "Enter a path relative to the remote worktree.",
                defaultValue: context.tab.relativePath,
                confirmTitle: "Rename",
                errorTitle: "Rename File Failed"
            ) else { return }
            guard relativePath != context.tab.relativePath else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
                else { return }
                do {
                    try await context.buffer.moveToRemote(relativePath: relativePath)
                    _ = self.tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
                } catch {
                    self.showFileActionError(title: "Rename File Failed", message: error.localizedDescription)
                }
            }
            return
        }
        let panel = NSSavePanel()
        panel.title = "Rename File"
        panel.message = "Choose the new path for this file."
        panel.directoryURL = currentURL.deletingLastPathComponent()
        panel.nameFieldStringValue = currentURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  await !self.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
            else { return }
            do {
                let relativePath = try self.relativePath(for: url, in: worktree.path)
                guard relativePath != context.tab.relativePath else { return }
                try context.buffer.moveTo(relativePath: relativePath)
                _ = self.tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
            } catch {
                self.showFileActionError(title: "Rename File Failed", message: error.localizedDescription)
            }
        }
    }

    func renameTerminalTab(worktreeId: String, tabId: TabID) {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab else { return }
        renameTerminalTab(initialTitle: state.title, tabID: tabId) { [tabs] title in
            _ = tabs.renameTerminal(worktreeId: worktreeId, tabId: tabId, title: title)
        }
    }

    func renameTerminalTab(owner: SessionOwnerID, tabId: TabID) {
        guard let tab = tabs.tabs(for: owner).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab else { return }
        renameTerminalTab(initialTitle: state.title, tabID: tabId) { [tabs] title in
            _ = tabs.renameTerminal(owner: owner, tabId: tabId, title: title)
        }
    }

    private func renameTerminalTab(initialTitle: String, tabID: TabID, applyTitle: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Rename Terminal"
        alert.informativeText = "Choose a stable name for this terminal tab."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initialTitle
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyTitle(field.stringValue)
        tabs.clearTerminalRuntimeTitles(forLeavesInTabId: tabID)
    }

    func renameACPSessionTab(worktreeId: String, tabId: TabID) {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .acpSession(let state) = tab,
              let worktree = worktree(withId: worktreeId),
              let mgr = acpManager(for: worktree) else { return }
        renameACPSessionTab(tabState: state, manager: mgr) { [tabs] title in
            _ = tabs.renameACPSession(worktreeId: worktreeId, tabId: tabId, title: title)
        }
    }

    func renameACPSessionTab(owner: SessionOwnerID, tabId: TabID) {
        guard let tab = tabs.tabs(for: owner).first(where: { $0.id == tabId }),
              case .acpSession(let state) = tab,
              let mgr = acpManager(for: owner) else { return }
        renameACPSessionTab(tabState: state, manager: mgr) { [tabs] title in
            _ = tabs.renameACPSession(owner: owner, tabId: tabId, title: title)
        }
    }

    private func renameACPSessionTab(
        tabState state: ACPSessionTabState,
        manager mgr: ACPSessionManager,
        applyTabTitle: (String) -> Void
    ) {
        guard let newTitle = promptForSessionTitle(state.title) else { return }
        mgr.renameSession(id: state.sessionId, title: newTitle, source: .manual)
        applyTabTitle(newTitle)
    }

    /// The trimmed title the user chose for a session; nil when cancelled or blank.
    private func promptForSessionTitle(_ title: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Choose a name for this ACP session."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = title
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let newTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return newTitle.isEmpty ? nil : newTitle
    }

    /// Renames a peer session tab with the local prompt.
    func renamePeerSessionTab(_ session: RemoteSessionSummary) {
        guard let client = nativePeerSessions, let title = promptForSessionTitle(session.title) else { return }
        client.renameSession(session.id, title: title)
    }

    /// Copy and Save Session as Markdown for a peer session, whose
    /// transcript is only here while its tab is selected.
    func copyPeerSessionMarkdown(_ session: RemoteSessionSummary) {
        guard let markdown = peerSessionMarkdown(session) else { return }
        Clipboard.copy(markdown)
    }

    func exportPeerSessionMarkdown(_ session: RemoteSessionSummary) {
        guard let markdown = peerSessionMarkdown(session) else { return }
        exportMarkdown(markdown, title: session.title)
    }

    private func peerSessionMarkdown(_ session: RemoteSessionSummary) -> String? {
        nativePeerSessions?.transcriptMarkdown(
            of: session.id, title: session.title, agentName: agent(id: session.agentId)?.displayName
        )
    }

    /// Copy the active ACP session's conversation (user + agent, Markdown)
    /// to the pasteboard. Silent on success, matching `onCopyPath`.
    func copyACPSessionMarkdown(worktreeId: String, tabId: TabID) {
        Task { @MainActor in
            await withHydratedACPSession(worktreeId: worktreeId, tabId: tabId) { session in
                Clipboard.copy(ACPTranscriptMarkdown.document(
                    title: session.title,
                    agentName: agent(id: session.agentId)?.displayName,
                    messages: session.transcript.messages
                ))
            }
        }
    }

    func copyACPSessionMarkdown(owner: SessionOwnerID, tabId: TabID) {
        Task { @MainActor in
            await withHydratedACPSession(owner: owner, tabId: tabId) { session in
                Clipboard.copy(ACPTranscriptMarkdown.document(
                    title: session.title,
                    agentName: agent(id: session.agentId)?.displayName,
                    messages: session.transcript.messages
                ))
            }
        }
    }

    /// Save the active ACP session's conversation to a `.md` file via a
    /// save panel. Cancel is a no-op; write failures surface through the
    /// shared file-action error handler.
    func exportACPSessionMarkdown(worktreeId: String, tabId: TabID) {
        Task { @MainActor in
            await withHydratedACPSession(worktreeId: worktreeId, tabId: tabId) { session in
                exportMarkdown(for: session)
            }
        }
    }

    func exportACPSessionMarkdown(owner: SessionOwnerID, tabId: TabID) {
        Task { @MainActor in
            await withHydratedACPSession(owner: owner, tabId: tabId) { session in
                exportMarkdown(for: session)
            }
        }
    }

    private func exportMarkdown(for session: ACPSession) {
        exportMarkdown(
            ACPTranscriptMarkdown.document(
                title: session.title,
                agentName: agent(id: session.agentId)?.displayName,
                messages: session.transcript.messages
            ),
            title: session.title
        )
    }

    private func exportMarkdown(_ markdown: String, title: String) {
        let panel = NSSavePanel()
        panel.title = "Save Session as Markdown"
        panel.message = "Choose where to save this conversation."
        panel.nameFieldStringValue = ACPTranscriptMarkdown.sanitizedFilename(title: title)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showFileActionError(title: "Export Failed", message: error.localizedDescription)
        }
    }

    /// Resolve + hydrate the ACP session backing a tab, run `body` with it,
    /// then release. Reopened-but-inactive tabs hold only a `.loading`
    /// placeholder with an empty transcript until they're shown (hydration
    /// is driven by `ACPTabView`'s `.task`), so reading `transcript.messages`
    /// without hydrating would serialize an empty conversation;
    /// `hydrateIfNeeded` is a no-op once `.ready`.
    ///
    /// The retain/release pair bounds the lifetime of a session we
    /// materialize purely for a one-off export: `releaseSession` evicts it
    /// again once `body` returns, instead of leaving a full transcript
    /// resident at refcount 0 until the app quits. A session that's also
    /// open in a visible tab already holds its own retain, so this just
    /// balances out and leaves it untouched — and the retain also stops the
    /// session being evicted mid-export if its tab disappears underneath us.
    /// No-op for non-ACP tabs or when the session no longer exists.
    private func withHydratedACPSession(
        worktreeId: String, tabId: TabID, _ body: (ACPSession) -> Void
    ) async {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .acpSession(let tabState) = tab,
              let worktree = worktree(withId: worktreeId),
              let mgr = acpManager(for: worktree),
              mgr.placeholderSession(id: tabState.sessionId) != nil else { return }
        mgr.retainSession(id: tabState.sessionId)
        defer { mgr.releaseSession(id: tabState.sessionId) }
        await mgr.hydrateIfNeeded(id: tabState.sessionId)
        // Hydration applies the tail synchronously and backfills older
        // messages on a follow-up task. Exporters need the FULL transcript,
        // so block until backfill is done before handing the session to
        // `body` — otherwise a long conversation would serialize as just
        // its last 30 entries.
        await mgr.awaitBackfill(id: tabState.sessionId)
        guard let session = mgr.sessions[tabState.sessionId] else { return }
        body(session)
    }

    private func withHydratedACPSession(
        owner: SessionOwnerID, tabId: TabID, _ body: (ACPSession) -> Void
    ) async {
        guard let tab = tabs.tabs(for: owner).first(where: { $0.id == tabId }),
              case .acpSession(let tabState) = tab,
              let mgr = acpManager(for: owner),
              mgr.placeholderSession(id: tabState.sessionId) != nil else { return }
        mgr.retainSession(id: tabState.sessionId)
        defer { mgr.releaseSession(id: tabState.sessionId) }
        await mgr.hydrateIfNeeded(id: tabState.sessionId)
        await mgr.awaitBackfill(id: tabState.sessionId)
        guard let session = mgr.sessions[tabState.sessionId] else { return }
        body(session)
    }

    func closeTab(worktreeId: String, tabId: TabID, cancelRunScriptMonitors: Bool = true) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let projectPath = projectPath(forWorktreeId: worktreeId)
        if let tab = allTabs.first(where: { $0.id == tabId }) {
            if case .terminal(let s) = tab {
                for leaf in s.root.leaves() {
                    let authExitHandler = takeACPAuthTerminalExitHandler(
                        terminalId: leaf.id,
                        owner: .worktree(worktreeId)
                    )
                    if cancelRunScriptMonitors {
                        core.runHostClosed(sessionID: leaf.id)
                    }
                    closeTerminalSession(id: leaf.id, worktreeId: worktreeId, projectPath: projectPath)
                    authExitHandler?()
                }
            }
            if case .editor = tab {
                tabs.discardBuffer(worktreeId: worktreeId, tabId: tabId)
            }
            if case .acpSession(let s) = tab {
                cleanupACPSession(worktreeId: worktreeId, sessionId: s.sessionId)
            }
            invalidateFollowRevisionRequests(for: [tab])
        }
        tabs.close(worktreeId: worktreeId, tabId: tabId)
    }

    func requestCloseTab(worktreeId: String, projectId: String? = nil, tabId: TabID) {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }) else { return }
        if let prompt = CloseTabConfirmationPolicy.prompt(for: tab, config: config),
           !confirmCloseTab(prompt) {
            return
        }
        closeTabRecordingHistory(worktreeId: worktreeId, projectId: projectId, tab: tab)
    }

    /// Closes a session tab on the paired Mac that hosts it, after the same
    /// confirmation a local chat tab gets.
    func requestClosePeerSessionTab(_ sessionId: String) {
        guard let client = nativePeerSessions,
              let peer = client.snapshot.groups.first(where: { group in
                  group.sessions.contains { $0.id == sessionId }
              }),
              client.canCloseSessionTabs(on: peer.serverId) else { return }
        if config.harness.confirmCloseChatTabs, !confirmCloseTab(.chat, onPeer: peer.name) { return }
        client.closeSessionTab(sessionId)
    }

    /// Closes `tab` and records it so the user can reopen it.
    private func closeTabRecordingHistory(worktreeId: String, projectId: String?, tab: Tab) {
        closedTabHistory.record(ClosedTabEntry(
            snapshot: .worktree(
                worktreeID: worktreeId,
                projectID: projectId ?? worktree(withId: worktreeId)?.projectId,
                tab: tab
            ),
            placement: .init(tabID: tab.id, orderedIDs: tabs.tabs(forWorktree: worktreeId).map(\.id))
        ))
        closeTab(worktreeId: worktreeId, tabId: tab.id)
    }

    /// Closing a peer console tab always asks, whatever
    /// `confirmCloseTabs` says: it ends a process on another Mac.
    func requestTerminatePeerConsole(serverId: String, consoleId: String, peerName: String) {
        guard let consoles = nativePeerSessions?.consoles, consoles.canTerminate(serverId: serverId),
              confirmCloseTab(.terminal, onPeer: peerName) else { return }
        consoles.terminate(serverId: serverId, consoleId: consoleId)
    }

    private func confirmCloseTab(_ prompt: CloseTabConfirmationPolicy.Prompt, onPeer peer: String? = nil) -> Bool {
        if let closeTabConfirmer {
            return closeTabConfirmer(prompt)
        }
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message(onPeer: peer)
        alert.alertStyle = .warning
        alert.addButton(withTitle: prompt.confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func cleanupTerminals(worktreeId: String, allTabs: [Tab], tabIds: [TabID]) {
        let projectPath = projectPath(forWorktreeId: worktreeId)
        for id in tabIds {
            if let tab = allTabs.first(where: { $0.id == id }),
               case .terminal(let s) = tab {
                for leaf in s.root.leaves() {
                    let authExitHandler = takeACPAuthTerminalExitHandler(
                        terminalId: leaf.id,
                        owner: .worktree(worktreeId)
                    )
                    core.runHostClosed(sessionID: leaf.id)
                    closeTerminalSession(id: leaf.id, worktreeId: worktreeId, projectPath: projectPath)
                    authExitHandler?()
                }
            }
        }
    }

    private func cleanupClosedEditorBuffers(worktreeId: String, allTabs: [Tab], closedIds: [TabID]) {
        for id in closedIds {
            if let tab = allTabs.first(where: { $0.id == id }), case .editor = tab {
                tabs.discardBuffer(worktreeId: worktreeId, tabId: id)
            }
        }
    }

    private func cleanupACPSessions(worktreeId: String, allTabs: [Tab], closedIds: [TabID]) {
        for id in closedIds {
            if let tab = allTabs.first(where: { $0.id == id }),
               case .acpSession(let s) = tab {
                cleanupACPSession(worktreeId: worktreeId, sessionId: s.sessionId)
            }
        }
    }

    private func invalidateFollowRevisionRequests(for tabs: [Tab]) {
        for tab in tabs {
            switch tab {
            case .commit, .reviewSession:
                _ = bumpFollowRevisionRequestGeneration(followRevisionRequestKey(for: tab))
            default:
                continue
            }
        }
    }

    private func invalidateFollowRevisionRequests(allTabs: [Tab], closedIds: [TabID]) {
        let closedSet = Set(closedIds)
        invalidateFollowRevisionRequests(for: allTabs.filter { closedSet.contains($0.id) })
    }

    /// Dispose a single ACP session's runner and remove it from the
    /// worktree's manager. Different from `disposeACPManager`, which
    /// tears down the whole worktree's manager — this leaves the
    /// manager (and any sibling sessions) running.
    private func cleanupACPSession(worktreeId: String, sessionId: String) {
        cleanupACPSession(owner: .worktree(worktreeId), sessionId: sessionId)
    }

    private func cleanupACPSession(owner: SessionOwnerID, sessionId: String) {
        dropRecapPrecompute(sessionId: sessionId)
        guard let manager = acpManagers[owner] else { return }
        Task { await manager.dismissSideQuestion(parentID: sessionId) }
        if retainedScheduledSessionStillNeedsRunner(manager: manager, sessionId: sessionId) {
            scheduleRetainedACPSessionCleanup(owner: owner, sessionId: sessionId)
            return
        }
        cancelRetainedACPSessionCleanup(owner: owner, sessionId: sessionId)
        // Flush any in-flight debounced draft write for this session
        // before the tab goes away. The manager itself stays alive
        // (other tabs may share it), so the global flush from
        // disposeACPManager wouldn't fire here.
        manager.flushPendingDraftWrite(forSession: sessionId)
        // Dispose unconditionally — a session can hold a writer lease
        // + heartbeat + writer-watch before its runner is registered (the
        // "attach window"). If we returned early when no runner was present,
        // closing the tab during that window would leak all of those
        // resources. Disposal is idempotent: releaseWriterLease is owner-
        // scoped, and endMirroring / stopHeartbeat / stopWriterWatch are
        // all no-ops when not active.
        if let runner = manager.runners[sessionId] {
            runner.stop()
        }
        scheduledAgentTurns.sessionClosed(sessionId)
        let pendingID = UUID()
        let pendingKey = owner.storageKey
        let task = Task { @MainActor in
            if let acpDetachRunner {
                await acpDetachRunner(manager, sessionId)
            } else {
                do {
                    try await manager.disposeSession(id: sessionId)
                } catch {
                    Self.logger.error("Failed to close ACP session: \(String(describing: error), privacy: .public)")
                    showFileActionError(
                        title: "Close Session Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
        pendingACPDetachTasks[pendingKey, default: [:]][sessionId] = PendingACPDetach(id: pendingID, task: task)
        Task { @MainActor [weak self] in
            await task.value
            self?.clearPendingACPDetach(worktreeId: pendingKey, sessionId: sessionId, id: pendingID)
        }
    }

    private func retainedScheduledSessionStillNeedsRunner(manager: ACPSessionManager, sessionId: ACPSession.ID) -> Bool {
        retainedScheduledSessionCleanupDelay(manager: manager, sessionId: sessionId) != nil
    }

    private func retainedScheduledSessionCleanupDelay(
        manager: ACPSessionManager,
        sessionId: ACPSession.ID,
        retainActivePrompt: Bool = false
    ) -> Duration? {
        guard let session = manager.liveSession(for: sessionId) else { return nil }
        let nextScheduledAt = session.queue.compactMap { item -> Date? in
            guard item.status == .pending, item.lastError == nil else { return nil }
            return item.scheduledAt
        }.min()
        if case .needsAuth = session.setupState { return nil }
        let hasScheduledQueueWork = nextScheduledAt != nil || session.queue.contains {
            $0.status == .sending && $0.scheduledAt != nil
        }
        let hasForcedQueueWork = session.queue.contains {
            $0.scheduledAt == nil && (
                $0.status == .sending || ($0.status == .pending && session.pendingQueuePersistenceCount > 0)
            )
        }
        switch session.agentState {
        case .ready, .spawning:
            break
        case .disconnected:
            guard hasScheduledQueueWork || hasForcedQueueWork else { return nil }
        case .idle:
            guard hasScheduledQueueWork || hasForcedQueueWork else { return nil }
        case .failed:
            guard hasScheduledQueueWork || hasForcedQueueWork else { return nil }
        }
        if session.queue.first?.lastError != nil { return nil }
        let activePromptCleanupDelay: Duration = switch session.transcript.streamingState {
        case .awaitingInput, .awaitingPermission: .seconds(3600)
        case .idle, .sending, .streaming: .milliseconds(250)
        }
        if retainActivePrompt && manager.retainedCleanupHasActivePromptWork(for: sessionId) {
            return activePromptCleanupDelay
        }
        if session.queue.contains(where: {
            $0.status == .sending && ($0.scheduledAt != nil || nextScheduledAt != nil)
        }) {
            return activePromptCleanupDelay
        }
        if hasForcedQueueWork, manager.retainedCleanupHasActivePromptWork(for: sessionId) {
            return activePromptCleanupDelay
        }
        if manager.retainedCleanupHasSteerWork(for: sessionId) {
            return activePromptCleanupDelay
        }
        if manager.retainedCleanupHasForkBarrierWork(for: sessionId) {
            return .seconds(30)
        }
        guard let nextScheduledAt else { return nil }
        let secondsUntilScheduledSend = nextScheduledAt.timeIntervalSinceNow
        if case .disconnected = session.agentState, secondsUntilScheduledSend <= 0 {
            return .seconds(30)
        }
        if case .idle = session.agentState, secondsUntilScheduledSend <= 0 {
            return .seconds(30)
        }
        if case .spawning = session.agentState, secondsUntilScheduledSend <= 0 {
            return .seconds(30)
        }
        guard secondsUntilScheduledSend > 0 else { return activePromptCleanupDelay }
        return .seconds(secondsUntilScheduledSend)
    }

    private func scheduleRetainedACPSessionCleanup(
        owner: SessionOwnerID,
        sessionId: ACPSession.ID,
        retainActivePrompt: Bool = false
    ) {
        let key = owner.storageKey
        guard retainedACPSessionCleanupTasks[key]?[sessionId] == nil else { return }
        acpManagers[owner]?.retainSession(id: sessionId)
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let manager = self.acpManagers[owner] else {
                    self.clearRetainedACPSessionCleanup(owner: owner, sessionId: sessionId, id: id)
                    return
                }
                guard let delay = self.retainedScheduledSessionCleanupDelay(
                    manager: manager,
                    sessionId: sessionId,
                    retainActivePrompt: retainActivePrompt
                ) else {
                    self.clearRetainedACPSessionCleanup(owner: owner, sessionId: sessionId, id: id)
                    self.cleanupACPSession(owner: owner, sessionId: sessionId)
                    return
                }
                self.reattachRetainedScheduledSessionIfDue(manager: manager, sessionId: sessionId)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
        retainedACPSessionCleanupTasks[key, default: [:]][sessionId] = PendingACPDetach(id: id, task: task)
    }

    private func reattachRetainedScheduledSessionIfDue(manager: ACPSessionManager, sessionId: ACPSession.ID) {
        guard let session = manager.liveSession(for: sessionId) else { return }
        switch session.agentState {
        case .disconnected, .failed:
            break
        case .idle:
            break
        case .ready, .spawning:
            return
        }
        guard session.queue.contains(where: { item in
            (item.status == .pending || item.status == .sending)
                && item.lastError == nil
                && (item.scheduledAt?.timeIntervalSinceNow ?? .greatestFiniteMagnitude) <= 0
        }) else { return }
        Task { @MainActor in await manager.reattach(to: sessionId) }
    }

    private func restartRetainedACPSessionCleanupIfNeeded(
        owner: SessionOwnerID,
        sessionId: ACPSession.ID,
        retainActivePrompt: Bool = false
    ) {
        guard retainedACPSessionCleanupTasks[owner.storageKey]?[sessionId] != nil else { return }
        acpManagers[owner]?.retainSession(id: sessionId)
        defer { acpManagers[owner]?.releaseSession(id: sessionId) }
        cancelRetainedACPSessionCleanup(owner: owner, sessionId: sessionId)
        guard retainActivePrompt else {
            cleanupACPSession(owner: owner, sessionId: sessionId)
            return
        }
        scheduleRetainedACPSessionCleanup(owner: owner, sessionId: sessionId, retainActivePrompt: true)
    }

    private func cancelRetainedACPSessionCleanup(owner: SessionOwnerID, sessionId: ACPSession.ID) {
        let key = owner.storageKey
        guard let pending = retainedACPSessionCleanupTasks[key]?[sessionId] else { return }
        pending.task.cancel()
        retainedACPSessionCleanupTasks[key]?.removeValue(forKey: sessionId)
        if retainedACPSessionCleanupTasks[key]?.isEmpty == true {
            retainedACPSessionCleanupTasks.removeValue(forKey: key)
        }
        acpManagers[owner]?.releaseSession(id: sessionId)
    }

    private func cancelRetainedACPSessionCleanups(owner: SessionOwnerID) {
        let key = owner.storageKey
        if let pendingBySession = retainedACPSessionCleanupTasks[key] {
            for (sessionId, pending) in pendingBySession {
                pending.task.cancel()
                acpManagers[owner]?.releaseSession(id: sessionId)
            }
        }
        retainedACPSessionCleanupTasks.removeValue(forKey: key)
    }

    private func clearRetainedACPSessionCleanup(owner: SessionOwnerID, sessionId: ACPSession.ID, id: UUID) {
        let key = owner.storageKey
        guard retainedACPSessionCleanupTasks[key]?[sessionId]?.id == id else { return }
        retainedACPSessionCleanupTasks[key]?.removeValue(forKey: sessionId)
        if retainedACPSessionCleanupTasks[key]?.isEmpty == true {
            retainedACPSessionCleanupTasks.removeValue(forKey: key)
        }
        acpManagers[owner]?.releaseSession(id: sessionId)
    }

    private func awaitPendingACPDetach(worktreeId: String, sessionId: ACPSession.ID) async {
        await awaitPendingACPDetach(owner: .worktree(worktreeId), sessionId: sessionId)
    }

    private func awaitPendingACPDetach(owner: SessionOwnerID, sessionId: ACPSession.ID) async {
        let key = owner.storageKey
        guard let pending = pendingACPDetachTasks[key]?[sessionId] else { return }
        await pending.task.value
        clearPendingACPDetach(worktreeId: key, sessionId: sessionId, id: pending.id)
    }

    private func clearPendingACPDetach(worktreeId: String, sessionId: ACPSession.ID, id: UUID) {
        guard pendingACPDetachTasks[worktreeId]?[sessionId]?.id == id else { return }
        pendingACPDetachTasks[worktreeId]?.removeValue(forKey: sessionId)
        if pendingACPDetachTasks[worktreeId]?.isEmpty == true {
            pendingACPDetachTasks.removeValue(forKey: worktreeId)
        }
    }

    func closeOtherTabs(worktreeId: String, keeping tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeOthers(worktreeId: worktreeId, keeping: tabId)
        invalidateFollowRevisionRequests(allTabs: allTabs, closedIds: closed)
        cleanupTerminals(worktreeId: worktreeId, allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        cleanupACPSessions(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    func closeCenterTabs(worktreeId: String, projectId: String? = nil, tabIds: [TabID]) {
        let ids = Set(tabIds)
        guard !ids.isEmpty else { return }
        closedTabHistory.record(contentsOf: closedTabEntries(
            worktreeID: worktreeId,
            projectId: projectId,
            tabIDs: tabIds
        ))
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = allTabs.map(\.id).filter(ids.contains)
        invalidateFollowRevisionRequests(allTabs: allTabs, closedIds: closed)
        for id in closed {
            tabs.close(worktreeId: worktreeId, tabId: id)
        }
        cleanupTerminals(worktreeId: worktreeId, allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        cleanupACPSessions(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    private func closedTabEntries(
        worktreeID: String,
        projectId: String? = nil,
        tabIDs: [TabID]
    ) -> [ClosedTabEntry] {
        let local = tabs.tabs(forWorktree: worktreeID)
        return tabIDs.compactMap { tabID in
            guard let tab = local.first(where: { $0.id == tabID }) else { return nil }
            return ClosedTabEntry(
                snapshot: .worktree(
                    worktreeID: worktreeID,
                    projectID: projectId ?? worktree(withId: worktreeID)?.projectId,
                    tab: tab
                ),
                placement: .init(tabID: tabID, orderedIDs: local.map(\.id))
            )
        }
    }

    func reopenLastClosedTab() async {
        guard !isReopeningClosedTab else { return }
        isReopeningClosedTab = true
        defer { isReopeningClosedTab = false }

        while let entry = closedTabHistory.last {
            switch entry.snapshot {
            case .worktree(let worktreeID, let projectID, let tab):
                guard worktree(withId: worktreeID) != nil else {
                    closedTabHistory.remove(id: entry.id)
                    continue
                }
                if case .terminal = tab {
                    await reopenTerminalTab(entry: entry, worktreeID: worktreeID, tab: tab)
                    return
                }
                if case .acpSession(let state) = tab {
                    await awaitPendingACPDetach(worktreeId: worktreeID, sessionId: state.sessionId)
                    cancelRetainedACPSessionCleanup(owner: .worktree(worktreeID), sessionId: state.sessionId)
                    guard closedTabHistory.last?.id == entry.id else { continue }
                    guard !Self.blocksWorktreeSessionAdmission(projectsManager.operationState(
                        forWorktreeId: worktreeID,
                        projectId: projectID
                            ?? projectAndWorktree(withWorktreeId: worktreeID)?.worktree.projectId
                            ?? ""
                    )) else {
                        closedTabHistory.remove(id: entry.id)
                        return
                    }
                    guard worktree(withId: worktreeID) != nil else {
                        closedTabHistory.remove(id: entry.id)
                        continue
                    }
                }
                selectWorktree(id: worktreeID)
                _ = tabs.restore(tab: tab, worktreeID: worktreeID, placement: entry.placement)
                activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
                closedTabHistory.remove(id: entry.id)
                return
            }
        }
    }

    private func reopenTerminalTab(entry: ClosedTabEntry, worktreeID: String, tab: Tab) async {
        guard case .terminal(let oldState) = tab else {
            return
        }

        if tabs.tabs(forWorktree: worktreeID).contains(where: { $0.id == tab.id }) {
            selectWorktree(id: worktreeID)
            activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
            closedTabHistory.remove(id: entry.id)
            return
        }

        guard let initialWorktree = worktree(withId: worktreeID),
              let initialProject = projects.first(where: { $0.id == initialWorktree.projectId }) else {
            showFileActionError(
                title: "Reopen Tab Failed",
                message: "Could not find the terminal tab's worktree or project."
            )
            return
        }

        await prepareRemoteAccelerationIfNeeded(for: initialProject)

        guard closedTabHistory.last?.id == entry.id else { return }
        guard let worktree = worktree(withId: worktreeID),
              let project = projects.first(where: { $0.id == worktree.projectId }) else {
            closedTabHistory.remove(id: entry.id)
            return
        }

        var openedIDs: [String] = []
        do {
            let repoStartupScript = try await preparedRepoHook(
                event: .sessionOpen,
                project: project,
                worktree: worktree,
                context: .sessionOpen
            )
            guard closedTabHistory.last?.id == entry.id else { return }
            guard self.worktree(withId: worktreeID)?.path == worktree.path,
                  projects.first(where: { $0.id == project.id })?.path == project.path else {
                closedTabHistory.remove(id: entry.id)
                return
            }
            guard !Self.blocksWorktreeSessionAdmission(projectsManager.operationState(for: worktree)) else { return }
            var replacements: [String: PaneLeaf] = [:]
            var focusedLeafID = oldState.focusedLeafId
            for oldLeaf in oldState.root.leaves() {
                let opened = try openTerminalSessionForReopen(
                    worktree: worktree,
                    project: project,
                    forcedCwd: oldLeaf.lastCwd.map(URL.init(fileURLWithPath:)),
                    repoStartupScript: repoStartupScript
                )
                openedIDs.append(opened.id)
                replacements[oldLeaf.id] = PaneLeaf(
                    id: opened.id,
                    sessionId: opened.id,
                    lastCwd: oldLeaf.lastCwd
                )
                if oldLeaf.id == oldState.focusedLeafId {
                    focusedLeafID = opened.id
                }
            }

            let reopened = TerminalTabState(
                id: oldState.id,
                title: oldState.title,
                root: oldState.root.replacingLeaves(using: replacements),
                focusedLeafId: focusedLeafID
            )
            _ = tabs.restore(tab: .terminal(reopened), worktreeID: worktreeID, placement: entry.placement)
            selectWorktree(id: worktreeID)
            activateWorktreeCenterTab(worktreeId: worktreeID, tabId: reopened.id)
            closedTabHistory.remove(id: entry.id)
        } catch RepoHookPreflightError.cancelled {
            for id in openedIDs {
                closeTerminalSession(id: id, worktreeId: worktreeID, projectPath: project.path)
            }
        } catch {
            for id in openedIDs {
                closeTerminalSession(id: id, worktreeId: worktreeID, projectPath: project.path)
            }
            showFileActionError(title: "Reopen Tab Failed", message: error.localizedDescription)
        }
    }

    /// Tear down every tab/terminal/harness reference for a worktree id without
    /// touching git. Shared between Close-All, archive, and delete so the
    /// bookkeeping stays in one place.
    @discardableResult
    private func cleanupWorktreeState(
        worktreeId: String,
        purgeRunScriptFailures: Bool = true,
        purgeRunHistory: Bool = true
    ) -> Task<Void, Never>? {
        inAppNotifications.remove(worktreeID: worktreeId)
        let runHistoryPurgeTask: Task<Void, Never>?
        if purgeRunScriptFailures {
            runHistoryPurgeTask = cleanupRunScriptState(worktreeID: worktreeId, purgeFailures: true, purgeHistory: purgeRunHistory)
        } else {
            cancelPendingRunScriptLaunches(worktreeID: worktreeId)
            runHistoryPurgeTask = nil
        }
        closedTabHistory.purge(worktreeID: worktreeId)
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeAll(worktreeId: worktreeId)
        invalidateFollowRevisionRequests(allTabs: allTabs, closedIds: closed)
        cleanupTerminals(worktreeId: worktreeId, allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        disposeACPManager(for: worktreeId)
        if purgeRunScriptFailures {
            // Archive and delete, not Close-All: the worktree is going away.
            tabs.disposeWorkspaceEditHistory(worktreeId: worktreeId)
            // Worktree ids are standardized paths (`Worktree.makeId`).
            let root = URL(fileURLWithPath: worktreeId)
            Task { [symbolIndex] in await symbolIndex.remove(root: root) }
        }
        return runHistoryPurgeTask
    }

    /// Stops everything using a worktree whose files are about to go: its
    /// agents (awaited), terminals, tabs, buffers and pending runs. Run
    /// history stays until the removal has succeeded.
    fileprivate func quiesceWorktreeForRemoval(_ worktree: Worktree) async throws {
        let owner = SessionOwnerID.worktree(worktree.id)
        await disposeACPManagerAndWait(owner: owner)
        // Closing a tab only queues the daemon-side kill; wait for it so no
        // terminal process still writes while the checkout is audited.
        try await terminateTerminalSessionsAndWait(owner: owner)
        // Checked with no suspension before the editors close: an open
        // buffer can still be edited while the operation awaits above.
        if let acknowledged = acknowledgedDirtyTabs[WorktreeOperationKey(projectId: worktree.projectId, worktreeId: worktree.id)],
           !Self.hasOnlyAcknowledgedDirtiness(current: dirtyTabGenerations(worktreeId: worktree.id), acknowledgedAtConfirmation: acknowledged) {
            throw UnacknowledgedEditsError()
        }
        cleanupWorktreeState(worktreeId: worktree.id, purgeRunHistory: false)
    }

    func closeAllTabs(worktreeId: String) {
        cleanupWorktreeState(worktreeId: worktreeId, purgeRunScriptFailures: false)
    }

    func closeTabsToLeft(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToLeft(worktreeId: worktreeId, of: tabId)
        invalidateFollowRevisionRequests(allTabs: allTabs, closedIds: closed)
        cleanupTerminals(worktreeId: worktreeId, allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        cleanupACPSessions(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    func closeTabsToRight(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToRight(worktreeId: worktreeId, of: tabId)
        invalidateFollowRevisionRequests(allTabs: allTabs, closedIds: closed)
        cleanupTerminals(worktreeId: worktreeId, allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        cleanupACPSessions(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    private func defaultTerminalTitle(for worktree: Worktree) -> String {
        let folder = worktree.path.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folder.isEmpty { return folder }
        let name = worktree.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let branch = worktree.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? "Terminal" : branch
    }

    /// A first match is unambiguous: `ProjectsManager` lets one local
    /// directory belong to only one project, and remote ids carry their host.
    func worktree(withId id: String) -> Worktree? {
        if let focused = workspaceSelectedWorktree(matching: id) {
            return focused.worktree
        }
        for project in projects {
            if let worktree = projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return worktree
            }
        }
        return nil
    }

    func projectAndWorktree(withWorktreeId id: String) -> (project: ProjectConfig, worktree: Worktree)? {
        if let focused = workspaceSelectedWorktree(matching: id),
           let project = projects.first(where: { $0.id == focused.worktree.projectId }) {
            return (project, focused.worktree)
        }
        for project in projects {
            if let worktree = projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return (project, worktree)
            }
        }
        return nil
    }

    private func workspaceSelectedWorktree(matching id: String) -> (checkout: WorkspaceCheckout, member: WorkspaceCheckoutMember, worktree: Worktree)? {
        guard workspaceNavigationState.repositoryFocusWorktreeID == id,
              let checkout = selectedWorkspaceCheckout,
              let memberID = workspaceNavigationState.focusedCheckoutMemberID,
              let member = checkout.members.first(where: { $0.id == memberID && $0.availability == .available })
        else { return nil }
        let targetPath = URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath)).standardizedFileURL.path
        guard let worktree = projectsManager.worktrees(projectId: member.projectID).first(where: {
            $0.id == id && $0.path.standardizedFileURL.path == targetPath
        }) else { return nil }
        return (checkout, member, worktree)
    }

    private func acpQuestionNotificationBody(from params: ACPQuestionRequestParams) -> String? {
        if let title = params.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return params.questions
            .map(\.prompt)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Permissions only reach here once parked for a human: auto-run and
    /// remembered decisions never block, so they never notify.
    private func notifyACPPermissionBlocked(_ blocker: ACPChildBlocker) {
        guard blocker.kind == .permission,
              config.harness.notifyOnAwaiting,
              let (owner, manager) = acpManagers.first(where: { $0.value.liveSession(for: blocker.sessionId) != nil }),
              let session = manager.liveSession(for: blocker.sessionId),
              let location = harnessSessionLocation(sessionId: blocker.sessionId)
        else { return }
        harness.notifications.notifyHarnessPermission(
            agent: ACPHarnessBridge.agentKind(for: session.agentId),
            body: blocker.summary,
            projectId: location.projectId,
            worktreeId: location.worktreeId,
            sessionId: blocker.sessionId,
            owner: owner
        )
    }

    private func acpInputNotificationBody(from request: ACPUserInputRequest) -> String? {
        switch request.source {
        case .cursor(_, let params):
            return acpQuestionNotificationBody(from: params)
        case .elicitation:
            let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { return title }
            let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        case .visualAid:
            return nil
        }
    }

    private func acpPlanNotificationBody(from request: ACPCursorPlanRequest) -> String? {
        let name = request.params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let overview = request.params.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty { return overview }
        let plan = request.params.plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return plan.isEmpty ? nil : plan
    }

    private func notificationRequestId(for request: ACPUserInputRequest) -> String {
        switch request.source {
        case .cursor(let id, _), .elicitation(let id, _):
            return notificationRequestId(for: id)
        case .visualAid(let id):
            return id.uuidString
        }
    }

    private func notificationRequestId(for id: JSONRPCID) -> String {
        switch id {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }

    private func projectPath(forWorktreeId id: String) -> String? {
        guard let worktree = worktree(withId: id) else { return nil }
        return projects.first(where: { $0.id == worktree.projectId })?.path
    }

    var activeTab: Tab? {
        guard let worktreeId = selectedWorktreeId else { return nil }
        return tabs.activeTab(forWorktree: worktreeId)
    }

    var hasActiveEditorTab: Bool {
        guard case .editor = activeTab else { return false }
        return true
    }

    var hasActiveCodeEditorTab: Bool {
        guard case .editor(let state) = activeTab else { return false }
        let path = state.isExternal ? (state.externalAbsolutePath ?? "") : state.relativePath
        return !MarkdownFileType.supportsRichPreview(relativePath: path)
    }

    var hasAnyDirtyEditorTab: Bool {
        var result = false
        for project in projects {
            for worktree in projectsManager.worktrees(projectId: project.id) {
                for tab in tabs.tabs(forWorktree: worktree.id) {
                    guard case .editor(let state) = tab else { continue }
                    if let buffer = tabs.peekBuffer(tabId: state.id) {
                        _ = buffer.editGeneration
                        if buffer.dirty { result = true }
                    }
                }
            }
        }
        return result
    }

    /// Pick a sensible new selection after a worktree was removed (archived or
    /// deleted) from the given project at the given index in its visible list.
    /// Prefers the entry now occupying that index in the same project (i.e.
    /// what was the next sibling). Falls back to the new last entry if the
    /// removed worktree was the last one. If the project has no remaining
    /// visible worktrees, picks the first visible worktree in the active space.
    /// Returns `nil` if the active space has no visible worktrees.
    private func selectionAfterRemoval(removedFromProjectId: String, removedAtIndex: Int) -> String? {
        let siblings = projectsManager.visibleWorktrees(projectId: removedFromProjectId)
        if !siblings.isEmpty {
            let i = min(removedAtIndex, siblings.count - 1)
            return siblings[i].id
        }
        for project in activeSpaceProjects {
            if let first = projectsManager.visibleWorktrees(projectId: project.id).first {
                return first.id
            }
        }
        return nil
    }

    func firstVisibleWorktreeId() -> String? {
        firstVisibleWorktreeId(in: projects)
    }

    func firstVisibleWorktreeId(in projects: [ProjectConfig]) -> String? {
        for project in projects {
            if let first = projectsManager.visibleWorktrees(projectId: project.id).first {
                return first.id
            }
        }
        return nil
    }

    private func resolvedSelectionForActiveSpace() -> String? {
        if let remembered = spacesManager.activeSpace?.lastSelectedWorktreeId,
           activeSpaceProjects.contains(where: { project in
               projectsManager.visibleWorktrees(projectId: project.id).contains(where: { $0.id == remembered })
           }) {
            return remembered
        }
        return firstVisibleWorktreeId(in: activeSpaceProjects)
    }

    func resolvedSelectionForActiveSpaceForStartup() -> String? {
        resolvedSelectionForActiveSpace()
    }

    private func reconcileMissingSpaceProjects() -> Bool {
        var changed = false
        let validProjectIds = Set(projects.map(\.id))
        if spacesManager.pruneMissingProjects(validProjectIds: validProjectIds) {
            changed = true
        }
        for project in projects where spacesManager.membershipCount(forProject: project.id) == 0 {
            spacesManager.addProject(project.id, toSpace: spacesManager.activeSpaceId)
            changed = true
        }
        return changed
    }

    var canFocusMainWorktreeForCurrentProject: Bool {
        mainWorktreeForCurrentProject() != nil
    }

    func focusMainWorktreeForCurrentProject() {
        guard let main = mainWorktreeForCurrentProject() else { return }
        selectWorktree(id: main.id)
    }

    private func mainWorktreeForCurrentProject() -> Worktree? {
        guard let current = selectedWorktreeId else { return nil }
        for project in projects {
            let visible = projectsManager.visibleWorktrees(projectId: project.id)
            guard visible.contains(where: { $0.id == current }) else { continue }
            return projectsManager.visibleMainWorktree(projectId: project.id)
        }
        return nil
    }

    private func makeSearchEnvironment() -> SearchEnvironment {
        let fileSearchBackend = FffFileSearchBackend()
        let fileSearchRanker = FileSearchRanker()
        // Invariant: the two synchronous closures below are only invoked
        // from `SearchModel`, which is `@MainActor` — so `assumeIsolated`
        // is sound. If a future caller invokes them off-main this will
        // trap; keep them on main or convert to async.
        return SearchEnvironment(
            currentWorktreeId: { [weak self] in
                MainActor.assumeIsolated { self?.selectedWorktreeId }
            },
            allWorktrees: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return [] }
                    var out: [SearchWorktree] = []
                    for project in self.projects {
                        for wt in self.projectsManager.visibleWorktrees(projectId: project.id) {
                            out.append(SearchWorktree(
                                id: wt.id,
                                projectId: project.id,
                                displayName: project.isFolder ? wt.title : wt.branch,
                                absolutePath: wt.path,
                                executionLocation: project.host.map(ExecutionLocation.ssh),
                                isFolder: project.isFolder
                            ))
                        }
                    }
                    return out
                }
            },
            entries: { [fileIndex] wt in
                try await fileIndex.entries(for: wt)
            },
            statuses: { [statusCache] wt in
                wt.isFolder ? [:] : try await statusCache.statuses(for: wt)
            },
            workspaceCheckoutWorktrees: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let checkout = self.selectedWorkspaceCheckout else { return [] }
                    let resolved = self.workspaceMemberWorktreeIDs(checkout)
                    return checkout.members.compactMap { member in
                        guard let worktreeID = resolved[member.id],
                              let worktree = self.worktree(withId: worktreeID)
                        else { return nil }
                        return SearchWorktree(
                            id: worktree.id,
                            projectId: worktree.projectId,
                            displayName: worktree.branch,
                            absolutePath: worktree.path,
                            executionLocation: checkout.executionLocation,
                            workspaceCheckoutID: checkout.id,
                            workspaceCheckoutMemberID: member.id
                        )
                    }
                }
            },
            fileSearch: { query, wt in
                // fff scans the whole tree, bypassing the folder index's cap and pruning.
                wt.isFolder ? nil : try await fileSearchBackend.search(query: query, worktree: wt, limit: 50)
            },
            rankFiles: { query, sources in
                try await fileSearchRanker.rank(query: query, sources: sources)
            },
            contentSearch: { [contentSearcher = ContentSearcher()] query, options, targets in
                contentSearcher.search(query: query, options: options, worktrees: targets)
            }
        )
    }

    /// Keeps an already-built symbol index current. Never builds one: the
    /// index is created lazily by the `@` picker.
    func refreshSymbolIndexIfLoaded(worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId), !worktree.path.isRemoteAlasPath else { return }
        let root = worktree.path
        let isFolder = isFolderWorktree(worktree)
        Task { [fileIndex, symbolIndex] in
            await symbolIndex.refreshIfLoaded(root: root) {
                await fileIndex.invalidate(forWorktreePath: root)
                // `try?` without a fallback: a failed enumeration leaves the index alone.
                return (try? await fileIndex.entries(forWorktreePath: root, isFolder: isFolder))?.map(\.relativePath)
            }
        }
    }

    /// Open a file in the right-pane code editor by routing through the
    /// existing tabs system. Switches `selectedWorktreeId` if the file is
    /// in a different worktree.
    func openFile(
        relativePath: String,
        worktreeId: String,
        revealLine: Int? = nil,
        revealEndLine: Int? = nil,
        revealCharacter: Int? = nil
    ) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        // Reject archived worktrees: their ids may still appear in some legacy
        // call sites (e.g. older persisted tabs). Selecting one would set
        // `selectedWorktreeId` to a hidden id that `RootView.selectedWorktree()`
        // (now visibility-aware) would reject anyway, leaving an empty pane.
        guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
        nativePeerSessions?.clearSelection()
        if selectedWorktreeId != worktree.id {
            focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        }

        let hasRevealTarget = revealLine != nil || revealCharacter != nil
        if ImageFileType.isSupported(relativePath: relativePath),
           !hasRevealTarget || !ImageFileType.isTextBacked(relativePath: relativePath) {
            _ = tabs.openImagePreview(worktreeId: worktree.id, relativePath: relativePath)
            return
        }
        if BinaryFileType.isKnownBinary(relativePath: relativePath) {
            _ = tabs.openBinaryPreview(worktreeId: worktree.id, relativePath: relativePath)
            return
        }

        _ = tabs.openEditor(
            worktreeId: worktree.id,
            relativePath: relativePath,
            revealLine: revealLine,
            revealCharacter: revealCharacter,
            revealEndLine: revealEndLine
        )
    }

    func revealInFiles(worktreeId: String, path: String, opensPane: Bool) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        config.rightPaneVisible = true
        _ = saveConfig()
        let rps = rightPaneStore.state(
            for: worktree,
            baseBranch: config.worktrees.baseBranch,
            comparisonMode: config.changes.comparisonMode
        )
        rps.reveal(path: path, opensPane: opensPane)
    }

    /// Open a markdown relative-link target as a new editor tab in the same worktree.
    /// Delegates to `openFile` which handles find-or-create, activate, and
    /// worktree-switch if necessary.
    func openMarkdownLink(worktreeId: String, worktreeRoot: URL, relativePath: String) {
        openFile(relativePath: relativePath, worktreeId: worktreeId)
    }

    /// Where a clicked ACP transcript link ends up.
    enum TranscriptLinkRoute: Equatable {
        /// Opened inside Alas, possibly after switching worktrees.
        case opened
        /// An existing file or directory outside every open worktree. The
        /// caller hands this `file:` URL to the system: the raw markdown
        /// destination is schemeless (`/Users/me/notes.md` parses as a
        /// relative URL), and `NSWorkspace` rejects that form with paramErr
        /// (-50) instead of opening the file.
        case systemOpen(URL)
        /// A local path (absolute, relative, or `file:`) that names nothing on
        /// disk. Claimed so the caller can say so: the system's default action
        /// rejects the schemeless form with a bare paramErr (-50) dialog.
        case missing(path: String)
        /// Not a local path we can resolve; let the default URL action run.
        case unhandled
        /// A remote worktree's absolute link outside it: claimed, nothing opens.
        case ignored
    }

    /// How a clicked absolute link from a session in `worktreeRoot` is routed
    /// before any local lookup.
    enum AbsoluteLinkRoute: Equatable {
        /// Not a remote absolute link; the local routing decides.
        case local
        /// Inside the remote worktree: open in the editor, which reads the
        /// file on its host. `line`/`column` are 1-based.
        case remoteEditor(relativePath: String, line: Int?, column: Int?)
        /// A remote absolute link outside the worktree. It is claimed and
        /// opens nothing, so the system never opens a same-path local twin.
        case ignored
    }

    /// A remote session's absolute paths (plain or `file:`, optionally
    /// `:line[:column]`) name files on its host. They are never probed or
    /// opened locally; containment is decided lexically on the virtual path.
    nonisolated static func absoluteLinkRoute(_ raw: String, worktreeRoot: String) -> AbsoluteLinkRoute {
        guard RemotePath.split(worktreeRoot) != nil else { return .local }
        var path = raw
        if let url = URL(string: raw), url.isFileURL { path = url.path }
        guard path.hasPrefix("/") else { return .local }
        // Without an existence probe, trailing sentence punctuation is
        // dropped lexically instead of retried.
        if path.hasSuffix("."), path.count > 1 { path.removeLast() }
        var line: Int?
        var column: Int?
        if let parsed = parseLocalPathPosition(path) {
            path = parsed.path
            line = parsed.line
            column = parsed.column
        }
        let target = URL(fileURLWithPath: RemotePath.virtualizing(path, like: worktreeRoot)).standardizedFileURL.path
        let root = URL(fileURLWithPath: worktreeRoot).standardizedFileURL.path
        guard target.hasPrefix(root + "/") else { return .ignored }
        return .remoteEditor(relativePath: String(target.dropFirst(root.count + 1)), line: line, column: column)
    }

    /// How a transcript link from a session rooted at `worktreeRoot` routes
    /// on a remote host. A relative path names a file on that host, so it
    /// joins the virtual root and routes lexically, unprobed. That includes
    /// `Package.swift:2`, which Foundation parses as having a scheme, unless
    /// the system has an app for that scheme (`tel:123`). A `mailto:` link
    /// is no path and stays `.local`.
    nonisolated static func transcriptRemoteLinkRoute(
        _ rawPath: String,
        isLocalPathForm: Bool,
        schemeHasSystemHandler: Bool,
        worktreeRoot: String
    ) -> AbsoluteLinkRoute {
        let isRelativePath = !rawPath.hasPrefix("/") && (isLocalPathForm
            || (!schemeHasSystemHandler && parseLocalPathPosition(rawPath) != nil))
        return absoluteLinkRoute(isRelativePath ? worktreeRoot + "/" + rawPath : rawPath, worktreeRoot: worktreeRoot)
    }

    /// Opens or claims a remote link; nil lets local routing run.
    private func routeRemoteLink(_ route: AbsoluteLinkRoute, worktree: Worktree) -> TranscriptLinkRoute? {
        switch route {
        case .local:
            return nil
        case .ignored:
            return .ignored
        case let .remoteEditor(relativePath, line, column):
            openFile(
                relativePath: relativePath,
                worktreeId: worktree.id,
                revealLine: line.map { $0 - 1 },
                revealCharacter: line.map { _ in (column ?? 1) - 1 }
            )
            NSApp.activate(ignoringOtherApps: true)
            return .opened
        }
    }

    /// Route a clicked markdown link from an ACP transcript. Paths inside
    /// the session worktree open as editor tabs; absolute paths inside any
    /// other open worktree — what an agent writes when it reports a file in
    /// a sibling worktree of the same repo — open there, switching the
    /// selected worktree. Anything else that exists on disk comes back as a
    /// `file:` URL for the system to open.
    ///
    /// `session` is the tab's worktree. A Workspace checkout's tab gets a
    /// synthetic root worktree no project lists: its links still resolve
    /// against that root and open in the member worktree that contains them.
    func transcriptLinkRoute(_ url: URL, in session: Worktree) -> TranscriptLinkRoute {
        let registered = worktree(withId: session.id)

        let rawPath: String
        // Only file URLs and schemeless paths are unambiguously local. A
        // `scheme:rest` destination may be `Package.swift:2` or `mailto:`, so
        // the system keeps it when nothing on disk matches.
        let isLocalPathForm: Bool
        if url.isFileURL {
            // `file://server/share` names a network volume, not a local path.
            guard url.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true else { return .unhandled }
            rawPath = url.path
            isLocalPathForm = true
        } else if url.scheme == nil {
            // `//host/path` names an authority, not a local path.
            guard url.host == nil else { return .unhandled }
            rawPath = url.path.removingPercentEncoding ?? url.path
            isLocalPathForm = true
        } else if !url.absoluteString.contains("://") {
            rawPath = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            isLocalPathForm = false
        } else {
            return .unhandled
        }
        guard !rawPath.isEmpty else { return .unhandled }
        let remoteRoute = Self.transcriptRemoteLinkRoute(
            rawPath,
            isLocalPathForm: isLocalPathForm,
            schemeHasSystemHandler: !isLocalPathForm && NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
            worktreeRoot: session.path.path
        )
        if let registered {
            if let remote = routeRemoteLink(remoteRoute, worktree: registered) { return remote }
        } else if remoteRoute != .local {
            // A remote checkout root has no editor of its own and nothing
            // local to probe.
            return .ignored
        }

        var candidates = [rawPath]
        // Trailing-period fallback: transcript prose can include sentence
        // punctuation in a markdown link destination.
        if rawPath.hasSuffix("."), rawPath.count > 1 {
            candidates.append(String(rawPath.dropLast()))
        }

        for candidate in candidates {
            switch transcriptRoute(forLocalPath: candidate, session: session, opensInSession: registered != nil) {
            case .opened:
                NSApp.activate(ignoringOtherApps: true)
                return .opened
            case .systemOpen(let fileURL):
                return .systemOpen(fileURL)
            case .unhandled, .ignored, .missing:
                continue
            }
        }

        return isLocalPathForm ? .missing(path: rawPath) : .unhandled
    }

    private func transcriptRoute(forLocalPath candidatePath: String, session: Worktree, opensInSession: Bool) -> TranscriptLinkRoute {
        guard let target = localFileOpenTarget(
            candidatePath,
            worktree: session,
            baseDirectory: session.path
        ) else { return .unhandled }
        guard !target.isDirectory else { return .systemOpen(target.url) }

        if opensInSession, let relativePath = Self.containedRelativePath(for: target.url, in: session.path) {
            openFile(
                relativePath: relativePath,
                worktreeId: session.id,
                revealLine: target.revealLine,
                revealCharacter: target.revealCharacter
            )
            return .opened
        }
        if let match = deepestVisibleWorktree(containing: target.url) {
            openFile(
                relativePath: match.relativePath,
                worktreeId: match.worktree.id,
                revealLine: target.revealLine,
                revealCharacter: target.revealCharacter
            )
            return .opened
        }
        return .systemOpen(target.url)
    }

    /// Route a cmd-clicked URL from a Ghostty terminal surface. Mirrors `alas
    /// open` for files inside the session's worktree (resolving relatives
    /// against the shell cwd first, then falling back to the worktree root),
    /// and returns false for anything else so the caller can fall back to
    /// `NSWorkspace.shared.open`.
    func routeTerminalOpenURL(rawURL: String, sessionId: String) -> Bool {
        guard let session = terminal.registry.session(for: sessionId),
              let worktree = worktree(withId: session.worktreeId) else { return false }
        if routeRemoteLink(Self.absoluteLinkRoute(rawURL, worktreeRoot: worktree.path.path), worktree: worktree) != nil {
            return true
        }

        let path: String
        if let parsed = URL(string: rawURL), parsed.isFileURL {
            path = parsed.path
        } else {
            path = rawURL
        }
        guard !path.isEmpty else { return false }

        func attemptOpen(_ candidatePath: String) -> Bool {
            if attemptOpenLocalFilePath(candidatePath, worktree: worktree, baseDirectory: session.surface.currentWorkingDirectory) {
                NSApp.activate(ignoringOtherApps: true)
                return true
            }
            return false
        }

        if attemptOpen(path) { return true }

        // Trailing-period fallback: agents sometimes write paths like
        // "src/foo.ts." where the final period is sentence punctuation that
        // Ghostty includes in the link. Retry without it.
        if path.hasSuffix(".") {
            let trimmed = String(path.dropLast())
            if !trimmed.isEmpty { return attemptOpen(trimmed) }
        }

        return false
    }

    private func attemptOpenLocalFilePath(
        _ candidatePath: String,
        worktree: Worktree,
        baseDirectory: URL?
    ) -> Bool {
        guard let target = localFileOpenTarget(
            candidatePath,
            worktree: worktree,
            baseDirectory: baseDirectory
        ), !target.isDirectory,
            let relativePath = Self.containedRelativePath(for: target.url, in: worktree.path)
        else { return false }

        openFile(
            relativePath: relativePath,
            worktreeId: worktree.id,
            revealLine: target.revealLine,
            revealCharacter: target.revealCharacter
        )
        return true
    }

    /// Resolve a clicked path — plain, or suffixed with `:line[:column]` —
    /// to something that actually exists on disk, or nil.
    private func localFileOpenTarget(
        _ candidatePath: String,
        worktree: Worktree,
        baseDirectory: URL?
    ) -> LocalFileOpenTarget? {
        let target: LocalFileOpenTarget
        let resolved = Self.resolveLocalFilePath(candidatePath, worktree: worktree, baseDirectory: baseDirectory)
        if FileManager.default.fileExists(atPath: resolved.path) {
            target = LocalFileOpenTarget(url: resolved, revealLine: nil, revealCharacter: nil)
        } else if let parsed = Self.parseLocalPathPosition(candidatePath) {
            let resolvedParsed = Self.resolveLocalFilePath(parsed.path, worktree: worktree, baseDirectory: baseDirectory)
            target = LocalFileOpenTarget(
                url: resolvedParsed,
                revealLine: parsed.line - 1,
                revealCharacter: (parsed.column ?? 1) - 1
            )
        } else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory) else {
            return nil
        }
        var existing = target
        existing.isDirectory = isDirectory.boolValue
        return existing
    }

    /// The deepest open worktree that contains `url`, with the matching
    /// worktree-relative path. Deepest wins so a file inside a worktree
    /// nested under another worktree's root opens in the nested one.
    private func deepestVisibleWorktree(containing url: URL) -> (worktree: Worktree, relativePath: String)? {
        var best: (worktree: Worktree, relativePath: String, depth: Int)?
        for project in projects {
            for candidate in projectsManager.visibleWorktrees(projectId: project.id) {
                guard let relativePath = Self.containedRelativePath(for: url, in: candidate.path) else { continue }
                let depth = candidate.path.resolvingSymlinksInPath().standardizedFileURL.pathComponents.count
                if let current = best, depth <= current.depth { continue }
                best = (candidate, relativePath, depth)
            }
        }
        guard let best else { return nil }
        return (best.worktree, best.relativePath)
    }

    /// Worktree-relative path for `url` when it sits strictly inside
    /// `root`. Symlinks are resolved on both sides first so an in-tree
    /// symlink pointing outside the worktree (e.g.
    /// `worktree/escape -> /elsewhere`) isn't mistaken for worktree content.
    nonisolated private static func containedRelativePath(for url: URL, in root: URL) -> String? {
        let resolvedTarget = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = resolvedRoot.pathComponents
        let targetComponents = resolvedTarget.pathComponents
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        let relativePath = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return relativePath.isEmpty ? nil : relativePath
    }

    nonisolated private static func resolveLocalFilePath(
        _ rawPath: String,
        worktree: Worktree,
        baseDirectory: URL?
    ) -> URL {
        if (rawPath as NSString).isAbsolutePath {
            return URL(fileURLWithPath: rawPath).standardizedFileURL
        }
        let base = baseDirectory ?? worktree.path
        let baseRelative = base.appendingPathComponent(rawPath).standardizedFileURL
        let rootRelative = worktree.path.appendingPathComponent(rawPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: baseRelative.path) {
            return baseRelative
        }
        if baseRelative.path != rootRelative.path,
           FileManager.default.fileExists(atPath: rootRelative.path) {
            return rootRelative
        }
        return baseRelative
    }

    private struct LocalFileOpenTarget {
        var url: URL
        var revealLine: Int?
        var revealCharacter: Int?
        var isDirectory: Bool = false
    }

    private struct LocalPathPosition {
        var path: String
        var line: Int
        var column: Int?
    }

    nonisolated private static func parseLocalPathPosition(_ rawPath: String) -> LocalPathPosition? {
        guard let lineSplit = splitTrailingPositiveInteger(from: rawPath) else { return nil }
        if let columnSplit = splitTrailingPositiveInteger(from: lineSplit.prefix) {
            return LocalPathPosition(
                path: columnSplit.prefix,
                line: columnSplit.value,
                column: lineSplit.value
            )
        }
        return LocalPathPosition(path: lineSplit.prefix, line: lineSplit.value, column: nil)
    }

    nonisolated private static func splitTrailingPositiveInteger(from value: String) -> (prefix: String, value: Int)? {
        guard let colon = value.lastIndex(of: ":") else { return nil }
        let suffixStart = value.index(after: colon)
        let suffix = value[suffixStart...]
        guard !suffix.isEmpty,
              suffix.allSatisfy(\.isNumber),
              let number = Int(suffix),
              number > 0 else { return nil }
        let prefix = String(value[..<colon])
        guard !prefix.isEmpty else { return nil }
        return (prefix, number)
    }

    private func relativePath(for url: URL, in worktreeRoot: URL) throws -> String {
        let root = worktreeRoot.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(rootWithSlash) else {
            throw NSError(
                domain: "AppState",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "File must be inside the selected worktree."]
            )
        }
        let rel = String(target.dropFirst(rootWithSlash.count))
        guard !rel.isEmpty, !rel.split(separator: "/").contains("..") else {
            throw NSError(
                domain: "AppState",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Invalid file path."]
            )
        }
        return rel
    }

    func showFileActionError(title: String, message: String) {
        fileActionErrorHandler(title, message)
    }

    /// Never modal under a test host. `runModal` waits for a click that can
    /// never come there, so it blocks the main thread for the rest of the run:
    /// the suite stops dead at whichever test raised the error, reporting no
    /// failure and producing no further output. A test that cares about the
    /// error injects `fileActionErrorHandler`; every other test at least keeps
    /// running, and the log says what was suppressed.
    private static func showWarningAlert(title: String, message: String) {
        guard !isRunningUnitTests else {
            logger.error("Suppressed alert under tests: \(title, privacy: .public) — \(message, privacy: .public)")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Whether this process is an XCTest host. Swift Testing runs inside one
    /// too, so this covers both frameworks.
    nonisolated static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || CommandLine.arguments.contains { $0.localizedCaseInsensitiveContains("xctest") }
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || Bundle.allBundles.contains { bundle in
                bundle.bundlePath.hasSuffix(".xctest")
                    || bundle.bundleIdentifier?.hasPrefix("com.apple.dt.XCTest") == true
            }
    }

    /// Delete a worktree from disk. Shows a confirm dialog; on dirty-tree
    /// failure sets `pendingForceDeleteWorktree` so SwiftUI can present a
    /// state-driven confirmation. Cleans up in-app state on success.
    /// A Workspace checkout still owning this worktree must be the one that
    /// deletes it — going through the plain worktree path leaves the
    /// checkout record behind pointing at a "missing" member with no hint
    /// that the checkout, not the worktree, is what needs attention.
    func workspaceOwnershipDeletionRefusal(for worktree: Worktree) -> String? {
        guard workspacesManager.canMutate else {
            return "Workspace Checkout ownership could not be verified. Try again once Workspace storage is available."
        }
        // Only a checkout still actively managing this worktree's lifecycle
        // owns the delete. An archived or Former Workspace checkout no
        // longer does, and the row's own removal actions are the only way
        // to clear those — refusing here would make them dead ends.
        guard let owner = worktreeCleanupWorkspaceOwners(for: worktree).first(where: {
            $0.state == .active || core.isUnarchivingWorkspaceCheckout($0.id)
        }) else { return nil }
        return "This worktree is owned by Workspace checkout \u{201C}\(owner.name)\u{201D}. Delete it from the checkout instead."
    }

    func deleteWorktree(_ worktree: Worktree, keepBranch: Bool = false) {
        if let refusal = workspaceOwnershipDeletionRefusal(for: worktree) {
            showFileActionError(title: "Delete Failed", message: refusal)
            return
        }
        // Snapshotted before the prompt: only what the user was shown counts
        // as acknowledged.
        let dirtyAtPrompt = dirtyTabGenerations(worktreeId: worktree.id)
        var saveBuffersFirst = false
        var acknowledged: [TabID: Int] = [:]
        if !dirtyAtPrompt.isEmpty {
            switch promptForDirtyBuffers(
                action: "Delete",
                branch: worktree.branch,
                dirtyCount: dirtyAtPrompt.count,
                onDiskDestructive: true,
                keepBranch: keepBranch
            ) {
            case .save: saveBuffersFirst = true
            case .discard: acknowledged = dirtyAtPrompt
            case .cancel: return
            }
        }
        if saveBuffersFirst {
            Task { @MainActor in
                guard await !checkpointWorktreeRemovalDisabledAfterDiscovery(worktree) else {
                    if let claim = try? host.worktrees.beginDelete(worktree, caller: .app) {
                        host.worktrees.failClaim(claim, for: worktree, message: Self.checkpointRecoveryBlocksWorktreeRemovalMessage)
                    }
                    return
                }
                guard await saveDirtyBuffers(in: worktree) else { return }
                beginDeleteWorktree(worktree, keepBranch: keepBranch, acknowledgedDirtyTabs: [:])
            }
            return
        }
        beginDeleteWorktree(worktree, keepBranch: keepBranch, acknowledgedDirtyTabs: acknowledged)
    }

    /// Delete several worktrees in one pass, reusing the single-item deletion
    /// path so every existing protection applies. Up to
    /// `worktreeCleanupConcurrency` items run at once; results keep the input
    /// order. A failure is recorded and the batch continues.
    ///
    /// Callers are responsible for confirming with the user first — this method
    /// deletes without prompting. Unsaved editor buffers are checked across the
    /// whole selection before any deletion happens: `performDeleteWorktree`
    /// alone does not check them (that gate lives in the single-item
    /// `deleteWorktree`, above `beginDeleteWorktree`), so without this check a
    /// worktree that is clean on disk but has an unsaved buffer would be
    /// deleted and its buffer silently discarded by `cleanupWorktreeState`.
    ///
    /// `forgeConfirmedMergedBranchSHAs` maps a worktree id to the exact HEAD
    /// SHA the cleanup scanner verified as merged via the code host (a
    /// SHA-matched, confirmed-merged review request) rather than by git's own
    /// local ancestry check. Git's `branch -d` cannot recognize a squash- or
    /// rebase-merged branch as merged — the resulting commit on the base
    /// branch isn't a descendant of the original tip by history alone — so it
    /// silently leaves those branches behind. For worktrees in this map,
    /// branch deletion uses `-D` instead, trusting the code host's stronger
    /// evidence over git's blind spot — but only once the deletion path
    /// re-confirms the branch's current tip still matches the recorded SHA,
    /// since a new commit could have landed on it between this scan and now.
    /// Empty by default, so existing callers are unaffected.
    func batchDeleteWorktrees(
        _ worktrees: [Worktree],
        keepBranch: Bool,
        forgeConfirmedMergedBranchSHAs: [String: String] = [:],
        authorization: WorktreeCleanupDeleteAuthorization? = nil
    ) async -> [WorktreeBatchResult] {
        guard !worktrees.isEmpty else { return [] }

        // Snapshot which tabs are dirty right now, before the prompt. If the
        // user confirms "Discard & Delete", those specific buffers stay
        // marked dirty in the tab model until cleanup actually closes them —
        // discarding doesn't retroactively un-dirty anything — so the
        // per-item re-check below must compare against this snapshot rather
        // than against "is anything dirty right now", or the confirmed
        // discard would skip every worktree it was meant to cover. Recording
        // each dirty tab's edit generation, not just its id, also catches a
        // tab re-edited (from another window) after being acknowledged here.
        let dirtyTabsAtConfirmation = authorization?.dirtyTabsByWorktree
            ?? Dictionary(
                uniqueKeysWithValues: worktrees.map {
                    ($0.id, dirtyTabGenerations(worktreeId: $0.id))
                }
            )
        let dirtyCount = dirtyTabsAtConfirmation.values.reduce(0) { $0 + $1.count }
        if authorization == nil, dirtyCount > 0 {
            guard promptForDirtyBuffersInBatch(
                action: "Delete",
                worktreeCount: worktrees.count,
                dirtyCount: dirtyCount,
                onDiskDestructive: true
            ) == .discard else {
                return []
            }
        }

        // The git removal itself still serializes per project inside
        // `ProjectMutationGate`; what overlaps is the work around it —
        // preflights, fingerprints, and stopping each worktree's sessions.
        // Every item re-checks its own state right before it mutates, so
        // interleaving with its siblings is no different from interleaving
        // with any other main-actor work.
        let deleteBranchIfMerged = Self.resolveDeleteBranchIfMerged(
            globalDeleteOnRemove: config.worktrees.deleteBranchOnRemove,
            keepBranch: keepBranch
        )
        let outcomes = await boundedConcurrentMap(worktrees, limit: Self.worktreeCleanupConcurrency) { @MainActor worktree in
            await self.deleteCleanupBatchItem(
                worktree,
                deleteBranchIfMerged: deleteBranchIfMerged,
                authorization: authorization,
                acknowledgedDirtyTabs: dirtyTabsAtConfirmation[worktree.id] ?? [:],
                verifiedMergedBranchSHA: forgeConfirmedMergedBranchSHAs[worktree.id]
            )
        }
        let results = outcomes.map(\.result)
        let removed = zip(worktrees, outcomes).compactMap { worktree, outcome in
            outcome.removedClaim.map { (worktree: worktree, claim: $0) }
        }
        let touchedProjectIds = Set(zip(worktrees, outcomes).filter(\.1.attemptedRemoval).map(\.0.projectId))

        // The removals' claims are held until their projects are refreshed.
        do {
            try await core.finishDeletions(removed)
        } catch {
            persistenceErrorHandler("Projects Save Failed", error.localizedDescription)
        }
        // A failed removal can still have changed what Git lists.
        for projectId in touchedProjectIds.subtracting(removed.map(\.worktree.projectId)) {
            _ = try? await refreshProjectWorktrees(projectId: projectId)
        }
        // Per-item deletion skipped selection reconciliation because the list
        // was still stale at that point. Now that every touched project has
        // been refreshed, drop a selection that points at a deleted worktree.
        if let current = selectedWorktreeId, !allWorktreeIds().contains(current) {
            selectWorktree(id: resolvedSelectionForActiveSpace())
        }
        return results
    }

    private struct CleanupDeleteItemOutcome: Sendable {
        let result: WorktreeBatchResult
        /// Held until the batch refreshes the project.
        var removedClaim: UUID?
        /// Git was asked to remove it, so the project listing may have changed.
        var attemptedRemoval = false

        static func skipped(_ worktree: Worktree, _ outcome: WorktreeBatchOutcome) -> Self {
            .init(result: WorktreeBatchResult(worktreeId: worktree.id, branch: worktree.branch, outcome: outcome))
        }
    }

    /// One item of `batchDeleteWorktrees`, re-validated right before removal.
    private func deleteCleanupBatchItem(
        _ worktree: Worktree,
        deleteBranchIfMerged: Bool,
        authorization: WorktreeCleanupDeleteAuthorization?,
        acknowledgedDirtyTabs: [TabID: Int],
        verifiedMergedBranchSHA: String?
    ) async -> CleanupDeleteItemOutcome {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            return .skipped(worktree, .failed(message: "Could not find the project for this worktree."))
        }
        guard !projectsManager.isMain(worktree, in: project) else {
            return .skipped(worktree, .skipped(reason: "Main worktree"))
        }
        // Re-check right before deleting. This closes two gaps at once: the
        // scan that selected this worktree (or even the whole-batch
        // dirty-buffer prompt) can be stale by the time the user confirms,
        // and — because every item suspends and yields the main actor — this
        // item can pick up a buffer edited or a session opened while a
        // sibling was being removed. Only dirtiness the confirmation didn't
        // already cover counts: a tab dirty at confirmation time and
        // discarded is expected here, but a tab that turned dirty, or was
        // edited again since being acknowledged, must not be torn down.
        guard Self.hasOnlyAcknowledgedDirtiness(
            current: dirtyTabGenerations(worktreeId: worktree.id),
            acknowledgedAtConfirmation: acknowledgedDirtyTabs
        ) else {
            return .skipped(worktree, .skipped(reason: "Has unsaved changes since this list was scanned"))
        }
        let sessionStateIsAcknowledged: Bool
        if let authorization {
            sessionStateIsAcknowledged = worktreeCleanupSessionIDs(worktreeId: worktree.id)
                .isSubset(of: authorization.sessionIDsByWorktree[worktree.id] ?? [])
        } else {
            sessionStateIsAcknowledged = !hasLiveSessions(worktreeId: worktree.id)
        }
        let ownershipIsValid = authorization == nil || (
            workspacesManager.canMutate && worktreeCleanupWorkspaceOwners(for: worktree).isEmpty
        )
        guard sessionStateIsAcknowledged,
              WorktreeOperationState.admitsLifecycleOperation(projectsManager.operationState(for: worktree)),
              ownershipIsValid
        else {
            return .skipped(worktree, .skipped(reason: "Worktree changed since confirmation"))
        }
        // Re-read the worktree's actual current branch immediately before
        // removal — the cached `Worktree.branch` from the scan could be
        // stale if something switched this checkout to a detached HEAD (or a
        // different branch entirely) in the meantime. A detached worktree's
        // commits are reachable only via its own HEAD, so removing one on
        // stale information risks orphaning commits.
        guard WorktreeService.localBranchName(forWorktreeAt: worktree.path) == worktree.branch else {
            return .skipped(worktree, .skipped(reason: "Branch changed since this list was scanned"))
        }

        let force: Bool
        if let authorization {
            do {
                let preflight = try await Task.detached {
                    try await WorktreeService().deletePreflight(worktreePath: worktree.path)
                }.value
                guard let acknowledgedPreflight = authorization.preflightByWorktree[worktree.id],
                      preflight.reasons.isSubset(of: acknowledgedPreflight.reasons),
                      !preflight.requiresForce
                          || authorization.forceWorktreeIDs.contains(worktree.id)
                else {
                    return .skipped(worktree, .skipped(reason: "Git deletion risks changed since confirmation"))
                }
                if let acknowledgedFingerprint = authorization.contentFingerprintsByWorktree[worktree.id] {
                    let currentFingerprint = try await Self.worktreeDeleteContentFingerprint(
                        worktreePath: worktree.path
                    )
                    guard currentFingerprint == acknowledgedFingerprint else {
                        return .skipped(worktree, .skipped(reason: "Git deletion risks changed since confirmation"))
                    }
                }
                let postPreflightDirtyIsAcknowledged = Self.hasOnlyAcknowledgedDirtiness(
                    current: dirtyTabGenerations(worktreeId: worktree.id),
                    acknowledgedAtConfirmation: acknowledgedDirtyTabs
                )
                let postPreflightSessionsAreAcknowledged = worktreeCleanupSessionIDs(worktreeId: worktree.id)
                    .isSubset(of: authorization.sessionIDsByWorktree[worktree.id] ?? [])
                let postPreflightOwnershipIsValid = workspacesManager.canMutate && worktreeCleanupWorkspaceOwners(for: worktree).isEmpty
                let postPreflightBranchMatches =
                    WorktreeService.localBranchName(forWorktreeAt: worktree.path) == worktree.branch
                guard postPreflightDirtyIsAcknowledged,
                      postPreflightSessionsAreAcknowledged,
                      postPreflightBranchMatches,
                      WorktreeOperationState.admitsLifecycleOperation(projectsManager.operationState(for: worktree)),
                      postPreflightOwnershipIsValid
                else {
                    return .skipped(worktree, .skipped(reason: "Worktree changed since confirmation"))
                }
                force = preflight.requiresForce
            } catch {
                return .skipped(worktree, .skipped(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        } else {
            force = false
        }

        let removedIndex = projectsManager.visibleWorktrees(projectId: worktree.projectId)
            .firstIndex(where: { $0.id == worktree.id }) ?? 0
        let claim: UUID
        do {
            claim = try host.worktrees.beginDelete(worktree, caller: .app)
        } catch {
            return .skipped(worktree, .skipped(reason: WorktreeRemovalResult.changedSinceConfirmationMessage))
        }
        host.worktrees.confirmDelete(claim, for: worktree)

        let outcome = await performDeleteWorktree(
            worktree: worktree,
            claim: claim,
            repoPath: URL(fileURLWithPath: project.path),
            deleteBranchIfMerged: deleteBranchIfMerged,
            force: force,
            removedIndex: removedIndex,
            // One refresh at the end, not one per item.
            refreshAfter: false,
            promptsForForce: false,
            isBatch: true,
            authorizedDeleteContentFingerprint: authorization?.contentFingerprintsByWorktree[worktree.id],
            acknowledgedDirtyTabs: acknowledgedDirtyTabs,
            verifiedMergedBranchSHA: verifiedMergedBranchSHA
        )
        return CleanupDeleteItemOutcome(
            result: WorktreeBatchResult(worktreeId: worktree.id, branch: worktree.branch, outcome: outcome),
            removedClaim: outcome == .deleted ? claim : nil,
            attemptedRemoval: true
        )
    }

    /// The worktrees cleanup considers: visible ones, minus the main checkout,
    /// which is never removed and is the costliest to probe.
    func worktreeCleanupScanTargets(project: ProjectConfig) -> [Worktree] {
        projectsManager.visibleWorktrees(projectId: project.id)
            .filter { !projectsManager.isMain($0, in: project) }
    }

    /// One live cleanup scan against git, the code host, and session state.
    /// Shared by the cleanup sheet and the background monitor so both apply
    /// the same rules.
    func scanWorktreesForCleanup(
        project: ProjectConfig,
        worktrees: [Worktree],
        onUpdate: @escaping @Sendable (WorktreeCleanupScanUpdate) async -> Void = { _ in }
    ) async -> [WorktreeCleanupCandidate] {
        let projectId = project.id
        let idleThresholdDays = config.worktrees.cleanupIdleDays
        // `config.worktrees.baseBranch` is a global default across every
        // project and may not exist in this repository. Resolve it against the
        // repo's real branches the way every other base-branch consumer does,
        // and do it per scan: branches can change between scans.
        let configuredDefault = config.worktrees.baseBranch
        let availableBranches = (try? await GitService().branches(at: URL(fileURLWithPath: project.path))) ?? []
        let baseBranch = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: availableBranches,
            configuredDefault: configuredDefault
        )
        let scanner = WorktreeCleanupScanner(
            dependencies: WorktreeCleanupScanner.Dependencies(
                gitFacts: { worktree in
                    await WorktreeCleanupScanner.gitFacts(
                        worktreePath: worktree.path,
                        branch: worktree.branch,
                        baseBranch: baseBranch
                    )
                },
                mergeIndex: { project, branches in
                    await Self.forgeMergeIndex(project: project, baseBranch: baseBranch, branches: branches)
                },
                // These hop to the main actor: session and operation state are
                // main-actor isolated, the scanner is not. The closures never
                // outlive this call, so capturing `self` strongly is fine.
                activeSessionCount: { worktreeId in
                    await MainActor.run {
                        self.worktreeCleanupSessionCounts(worktreeId: worktreeId).total
                    }
                },
                busySessionCount: { worktreeId in
                    await MainActor.run {
                        self.worktreeCleanupSessionCounts(worktreeId: worktreeId).busy
                    }
                },
                // A failed delete awaits retry, so it does not block selection.
                operationInFlight: { worktreeId in
                    await MainActor.run {
                        !WorktreeOperationState.admitsLifecycleOperation(self.projectsManager.operationState(
                            forWorktreeId: worktreeId,
                            projectId: projectId
                        ))
                    }
                },
                workspaceOwners: { worktree in
                    await MainActor.run {
                        self.worktreeCleanupWorkspaceOwners(for: worktree)
                    }
                },
                workspaceOwnershipAvailable: {
                    await MainActor.run {
                        self.workspacesManager.canMutate
                    }
                }
            )
        )
        return await scanner.scan(
            project: project,
            worktrees: worktrees,
            baseBranch: baseBranch,
            now: Date(),
            idleThresholdDays: idleThresholdDays,
            onUpdate: onUpdate
        )
    }

    /// Builds a cleanup model wired to live git, code-host, and session state.
    /// Returns nil when the project no longer exists.
    func makeWorktreeCleanupModel(projectId: String) -> WorktreeCleanupModel? {
        guard let project = projects.first(where: { $0.id == projectId }), !project.isFolder else { return nil }

        return WorktreeCleanupModel(
            projectId: projectId,
            worktrees: worktreeCleanupScanTargets(project: project),
            keepBranches: !config.worktrees.deleteBranchOnRemove,
            loadWorktrees: { [weak self] in
                self?.worktreeCleanupScanTargets(project: project) ?? []
            },
            scan: { [weak self] worktrees, onUpdate in
                guard let self else { return .success([]) }
                return .success(await self.scanWorktreesForCleanup(
                    project: project,
                    worktrees: worktrees,
                    onUpdate: onUpdate
                ))
            },
            deleteBatch: { [weak self] worktrees, keepBranch, forgeConfirmedMergedBranchSHAs in
                guard let self else { return [] }
                return await self.batchDeleteWorktrees(
                    worktrees,
                    keepBranch: keepBranch,
                    forgeConfirmedMergedBranchSHAs: forgeConfirmedMergedBranchSHAs
                )
            },
            archiveBatch: { [weak self] worktrees in
                await self?.batchArchiveWorktrees(worktrees) ?? []
            },
            confirm: { title, message, confirmButtonTitle in
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.alertStyle = .warning
                let confirmButton = alert.addButton(withTitle: confirmButtonTitle)
                alert.addButton(withTitle: "Cancel")
                confirmButton.hasDestructiveAction = true
                return alert.runModal() == .alertFirstButtonReturn
            },
            authorizeDelete: { [weak self] worktrees in
                guard let self else {
                    return .init(unavailableReasons: Dictionary(
                        uniqueKeysWithValues: worktrees.map { ($0.id, "Alas is no longer available") }
                    ))
                }
                return await self.worktreeCleanupDeleteAuthorization(for: worktrees)
            },
            authorizedDeleteBatch: { [weak self] authorization, worktrees, keepBranch, forgeConfirmedMergedBranchSHAs in
                guard let self else { return [] }
                return await self.batchDeleteWorktrees(
                    worktrees,
                    keepBranch: keepBranch,
                    forgeConfirmedMergedBranchSHAs: forgeConfirmedMergedBranchSHAs,
                    authorization: authorization
                )
            },
            authorizeArchive: { [weak self] worktrees in
                self?.worktreeCleanupArchiveAuthorization(for: worktrees)
            },
            authorizedArchiveBatch: { [weak self] authorization, worktrees in
                guard let self else { return [] }
                return await self.batchArchiveWorktrees(authorization, worktrees)
            }
        )
    }

    private func worktreeCleanupSessionCounts(worktreeId: String) -> (total: Int, busy: Int) {
        tabs.tabs(forWorktree: worktreeId).reduce(into: (total: 0, busy: 0)) { counts, tab in
            switch tab {
            case .terminal(let state):
                for leaf in state.root.leaves() {
                    counts.total += 1
                    if harnessSessionIsBusy(leaf.sessionId)
                        || terminal.registry.session(for: leaf.sessionId)?.surface.foregroundPid != nil {
                        counts.busy += 1
                    }
                }
            case .acpSession(let state):
                counts.total += 1
                if harnessSessionIsBusy(state.sessionId) {
                    counts.busy += 1
                }
            default:
                break
            }
        }
    }

    /// A failed foreground turn can coexist with live background work, so
    /// liveness checks both.
    private func harnessSessionIsBusy(_ sessionId: String) -> Bool {
        Self.harnessActivityIsBusy(harness.activityBySession[sessionId]?.state)
            || harness.hasBackgroundActivity(sessionId: sessionId)
    }
    nonisolated static func blocksWorktreeSessionAdmission(_ state: WorktreeOperationState?) -> Bool {
        state?.blocksAdmission ?? false
    }

    nonisolated static func harnessActivityIsBusy(_ state: ActivityState?) -> Bool {
        switch state {
        case nil, .idle, .failed:
            // A failed turn has stopped; its badge just outlives it.
            return false
        case .busy, .awaitingInput, .permissionRequest, .limited:
            return true
        }
    }
    private func worktreeCleanupWorkspaceOwners(
        for worktree: Worktree
    ) -> [WorktreeCleanupWorkspaceOwner] {
        let path = worktree.path.standardizedFileURL.path

        return workspacesManager.checkouts.compactMap { checkout in
            guard let member = checkout.members.first(where: { member in
                guard member.projectID == worktree.projectId,
                      URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath)).standardizedFileURL.path == path
                else { return false }
                if let memberLineage = member.gitLineageID,
                   let worktreeLineage = worktree.lineageID,
                   memberLineage != worktreeLineage {
                    return false
                }
                return !(member.availability == .explicitlyDeleted
                    && member.cleanup?.worktreeRemoved == true)
            }) else { return nil }
            let state: WorktreeCleanupWorkspaceOwner.State
            if checkout.workspaceID == nil {
                state = .formerWorkspace
            } else if checkout.archivedAt != nil {
                state = .archived
            } else {
                state = .active
            }
            _ = member
            return .init(id: checkout.id, name: checkout.fallbackWorkspaceName, state: state)
        }
    }

    private func worktreeCleanupSessionIDs(worktreeId: String) -> Set<String> {
        Set(tabs.tabs(forWorktree: worktreeId).flatMap { tab -> [String] in
            switch tab {
            case .terminal(let state):
                state.root.leaves().map(\.sessionId)
            case .acpSession(let state):
                [state.sessionId]
            default:
                []
            }
        })
    }

    private func worktreeCleanupDeleteAuthorization(
        for worktrees: [Worktree]
    ) async -> WorktreeCleanupDeleteAuthorization {
        var forceWorktreeIDs: Set<String> = []
        var dirtyTabsByWorktree: [String: [TabID: Int]] = [:]
        var sessionIDsByWorktree: [String: Set<String>] = [:]
        var forceReasons: [String: [String]] = [:]
        var preflightByWorktree: [String: WorktreeDeletePreflight] = [:]
        var unavailableReasons: [String: String] = [:]
        var contentFingerprintsByWorktree: [String: String] = [:]

        var eligible: [Worktree] = []
        for worktree in worktrees {
            guard workspacesManager.canMutate else {
                unavailableReasons[worktree.id] = "Workspace Checkout ownership could not be verified"
                continue
            }
            guard worktreeCleanupWorkspaceOwners(for: worktree).isEmpty else {
                unavailableReasons[worktree.id] = "This worktree is managed by a Workspace Checkout"
                continue
            }
            guard WorktreeOperationState.admitsLifecycleOperation(projectsManager.operationState(for: worktree)) else {
                unavailableReasons[worktree.id] = "Another operation is in progress"
                continue
            }
            eligible.append(worktree)
        }

        // Each preflight walks `git status` (and submodules); running them one
        // by one kept the confirmation waiting on the slowest sum.
        let inspections = await boundedConcurrentMap(eligible, limit: Self.worktreeCleanupConcurrency) { worktree in
            await Self.inspectWorktreeForCleanupDelete(worktree.path)
        }
        for (worktree, inspection) in zip(eligible, inspections) {
            let preflight: WorktreeDeletePreflight
            switch inspection {
            case .failure(let error):
                unavailableReasons[worktree.id] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                continue
            case .success(let result):
                preflight = result.preflight
                contentFingerprintsByWorktree[worktree.id] = result.contentFingerprint
            }
            preflightByWorktree[worktree.id] = preflight

            if preflight.requiresForce {
                forceWorktreeIDs.insert(worktree.id)
                var reasons: [String] = []
                if preflight.reasons.contains(.dirty) {
                    reasons.append("Git will force-remove modified or untracked files")
                }
                if preflight.reasons.contains(.locked) {
                    reasons.append("Git will force-remove this locked worktree")
                }
                forceReasons[worktree.id] = reasons
            }
            let dirty = dirtyTabGenerations(worktreeId: worktree.id)
            if !dirty.isEmpty { dirtyTabsByWorktree[worktree.id] = dirty }
            sessionIDsByWorktree[worktree.id] = worktreeCleanupSessionIDs(worktreeId: worktree.id)
        }
        return .init(
            forceWorktreeIDs: forceWorktreeIDs,
            dirtyTabsByWorktree: dirtyTabsByWorktree,
            sessionIDsByWorktree: sessionIDsByWorktree,
            forceReasons: forceReasons,
            preflightByWorktree: preflightByWorktree,
            unavailableReasons: unavailableReasons,
            contentFingerprintsByWorktree: contentFingerprintsByWorktree
        )
    }

    /// Worktrees cleanup inspects or deletes at once. Git's own mutations stay
    /// serialized per project by `ProjectMutationGate`; this bounds the work
    /// around them (status walks, session teardown) and the processes spawned.
    static let worktreeCleanupConcurrency = 4

    /// The preflight, plus the content fingerprint a force-delete must later
    /// match. A failure of either makes the worktree unavailable.
    nonisolated private static func inspectWorktreeForCleanupDelete(
        _ path: URL
    ) async -> Result<(preflight: WorktreeDeletePreflight, contentFingerprint: String?), Error> {
        do {
            let preflight = try await WorktreeService().deletePreflight(worktreePath: path)
            guard preflight.requiresForce else { return .success((preflight, nil)) }
            return .success((preflight, try await worktreeDeleteContentFingerprint(worktreePath: path)))
        } catch {
            return .failure(error)
        }
    }

    private func worktreeCleanupArchiveAuthorization(
        for worktrees: [Worktree]
    ) -> WorktreeCleanupArchiveAuthorization? {
        var dirtyTabsByWorktree: [String: [TabID: Int]] = [:]
        var sessionIDsByWorktree: [String: Set<String>] = [:]
        var unavailableReasons: [String: String] = [:]

        for worktree in worktrees {
            guard workspacesManager.canMutate else {
                unavailableReasons[worktree.id] = "Workspace Checkout ownership could not be verified"
                continue
            }
            guard worktreeCleanupWorkspaceOwners(for: worktree).isEmpty else {
                unavailableReasons[worktree.id] = "This worktree is managed by a Workspace Checkout"
                continue
            }
            guard WorktreeOperationState.admitsLifecycleOperation(projectsManager.operationState(for: worktree)) else {
                unavailableReasons[worktree.id] = "Another operation is in progress"
                continue
            }
            let dirty = dirtyTabGenerations(worktreeId: worktree.id)
            if !dirty.isEmpty { dirtyTabsByWorktree[worktree.id] = dirty }
            sessionIDsByWorktree[worktree.id] = worktreeCleanupSessionIDs(worktreeId: worktree.id)
        }

        let targets = worktrees.filter { unavailableReasons[$0.id] == nil }
        guard !targets.isEmpty else {
            return .init(
                dirtyTabsByWorktree: dirtyTabsByWorktree,
                sessionIDsByWorktree: sessionIDsByWorktree,
                unavailableReasons: unavailableReasons,
                bufferResolution: .save
            )
        }

        let alert = NSAlert()
        alert.messageText = "Archive \(targets.count) \(targets.count == 1 ? "worktree" : "worktrees")?"
        let list = targets.map(\.branch).map { "• \($0)" }.joined(separator: "\n")
        let sessionCount = targets.reduce(0) {
            $0 + (sessionIDsByWorktree[$1.id]?.count ?? 0)
        }
        var message = """
        These worktrees will be hidden from the sidebar. Their files and branches stay on disk.

        \(list)
        """
        if sessionCount > 0 {
            message += "\n\n\(sessionCount) attached terminal or agent \(sessionCount == 1 ? "session will" : "sessions will") be closed."
        }
        alert.informativeText = message
        alert.alertStyle = .warning
        let resolution: WorktreeCleanupArchiveBufferResolution
        if dirtyTabsByWorktree.isEmpty {
            alert.addButton(withTitle: "Archive")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            resolution = .save
        } else {
            alert.addButton(withTitle: "Save & Archive")
            let discard = alert.addButton(withTitle: "Discard & Archive")
            discard.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                resolution = .save
            case .alertSecondButtonReturn:
                resolution = .discard
            default:
                return nil
            }
        }
        return .init(
            dirtyTabsByWorktree: dirtyTabsByWorktree,
            sessionIDsByWorktree: sessionIDsByWorktree,
            unavailableReasons: unavailableReasons,
            bufferResolution: resolution
        )
    }

    func batchArchiveWorktrees(
        _ authorization: WorktreeCleanupArchiveAuthorization,
        _ worktrees: [Worktree]
    ) async -> [WorktreeBatchResult] {
        var results: [WorktreeBatchResult] = []
        for worktree in worktrees {
            if authorization.bufferResolution == .save,
               authorization.dirtyTabsByWorktree[worktree.id] != nil,
               await !saveDirtyBuffers(in: worktree) {
                results.append(.init(
                    worktreeId: worktree.id,
                    branch: worktree.branch,
                    outcome: .skipped(reason: "Could not save unsaved editor changes")
                ))
                continue
            }
            let dirtyIsAcknowledged = Self.hasOnlyAcknowledgedDirtiness(
                current: dirtyTabGenerations(worktreeId: worktree.id),
                acknowledgedAtConfirmation: authorization.dirtyTabsByWorktree[worktree.id] ?? [:]
            )
            let sessionsAreAcknowledged = worktreeCleanupSessionIDs(worktreeId: worktree.id)
                .isSubset(of: authorization.sessionIDsByWorktree[worktree.id] ?? [])
            let ownershipIsValid = workspacesManager.canMutate && worktreeCleanupWorkspaceOwners(for: worktree).isEmpty
            guard dirtyIsAcknowledged,
                  sessionsAreAcknowledged,
                  WorktreeOperationState.admitsLifecycleOperation(projectsManager.operationState(for: worktree)),
                  ownershipIsValid
            else {
                results.append(.init(
                    worktreeId: worktree.id,
                    branch: worktree.branch,
                    outcome: .skipped(reason: "Worktree changed since confirmation")
                ))
                continue
            }
            results.append(.init(
                worktreeId: worktree.id,
                branch: worktree.branch,
                outcome: await archiveBatchItem(
                    worktree,
                    acknowledgedDirtyTabs: authorization.bufferResolution == .save ? [:] : authorization.dirtyTabsByWorktree[worktree.id] ?? [:]
                )
            ))
        }
        return results
    }

    /// One merged-review-request query per repository, scoped to `branches`.
    /// Any failure — no remote, no provider, CLI missing, auth expired —
    /// surfaces as a `.failure` so the scanner can report `unknown` rather
    /// than inventing a "not merged" answer.
    nonisolated private static func forgeMergeIndex(
        project: ProjectConfig,
        baseBranch: String,
        branches: [String]
    ) async -> Result<WorktreeForgeMergeIndex, Error> {
        guard !branches.isEmpty else { return .success(WorktreeForgeMergeIndex(refs: [])) }
        let repoPath = URL(fileURLWithPath: project.path)
        let registry = CodeHostProviderRegistry.live()
        do {
            let remotes = try await GitService().remotes(worktreePath: repoPath)
            guard let remote = CodeHostRemoteDetector.detect(
                from: remotes,
                supportedKinds: registry.supportedKinds,
                preferredRemoteName: CodeHostRemoteDetector.preferredRemoteName(
                    forBaseBranch: baseBranch,
                    remotes: remotes
                )
            ) else {
                return .failure(CodeHostProviderError.malformedOutput(
                    "no supported code host remote"
                ))
            }
            guard let provider = registry.provider(for: remote.kind) else {
                return .failure(CodeHostProviderError.unsupportedProvider(remote.kind))
            }
            // A fork's own pull/merge requests are almost never opened
            // against itself — the classic contribution workflow opens them
            // against the parent, and that's where a merge actually lands.
            // Query the parent when this remote is a fork; if that lookup
            // fails or the provider doesn't support it, fall back to the
            // originally detected remote rather than failing the scan.
            let queryRemote = (try? await provider.repositoryParent(remote: remote, cwd: repoPath)) ?? remote
            let refs = try await provider.mergedReviewRequests(
                remote: queryRemote,
                headBranches: branches,
                cwd: repoPath
            )
            return .success(WorktreeForgeMergeIndex(refs: refs))
        } catch {
            return .failure(error)
        }
    }

    /// Ask first, inspect later. The confirmation names the worktree and what
    /// deleting it costs; nothing about it depends on shelling out to git, so
    /// it goes up immediately instead of waiting on a preflight that walks
    /// submodules. Anything git genuinely needs force for surfaces
    /// afterwards as the force prompt.
    ///
    /// The worktree is still claimed via `.preparingDelete` before the
    /// dialog appears (hence the row's "Preparing deletion…" state for as
    /// long as it's up) — that claim is synchronous, not tied to any async
    /// preflight I/O. It exists because `NSAlert.runModal()` blocks this
    /// call stack but its nested run loop keeps pumping other main-actor
    /// work: a scheduled run or issue-triggered session could otherwise be
    /// admitted into this worktree while the user is still deciding, then
    /// keep writing straight through the confirmed delete's staging/audit
    /// window.
    private func beginDeleteWorktree(_ worktree: Worktree, keepBranch: Bool, acknowledgedDirtyTabs: [TabID: Int]) {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            showFileActionError(title: "Delete Failed", message: "Could not find the project for this worktree.")
            return
        }
        // Claimed as `.preparingDelete` while the confirmation is up: its run
        // loop could otherwise admit new work into the worktree.
        let claim: UUID
        do {
            claim = try host.worktrees.beginDelete(worktree, caller: .app)
        } catch {
            showFileActionError(title: "Delete Failed", message: error.localizedDescription)
            return
        }
        guard confirmDeleteWorktree(
            Self.deleteConfirmation(branch: worktree.branch, keepBranch: keepBranch)
        ) else {
            host.worktrees.releaseClaim(claim, for: worktree)
            return
        }
        let removedIndex = projectsManager.visibleWorktrees(projectId: worktree.projectId)
            .firstIndex(where: { $0.id == worktree.id }) ?? 0
        host.worktrees.confirmDelete(claim, for: worktree)
        Task { @MainActor in
            await performDeleteWorktree(
                worktree: worktree,
                claim: claim,
                repoPath: URL(fileURLWithPath: project.path),
                deleteBranchIfMerged: Self.resolveDeleteBranchIfMerged(
                    globalDeleteOnRemove: config.worktrees.deleteBranchOnRemove,
                    keepBranch: keepBranch
                ),
                force: false,
                removedIndex: removedIndex,
                acknowledgedDirtyTabs: acknowledgedDirtyTabs
            )
        }
    }

    @MainActor
    func cliDeleteWorktree(_ worktree: Worktree, force: Bool, keepBranch: Bool, caller: HostCaller = .cli) async -> AlasCLIResponse {
        // Matched on project as well as id: a worktree id is its path, so a
        // prompt opened for a same-path checkout under another project is a
        // different worktree's prompt and must not be discarded here. The
        // prompt's claim is given back with it; a `.preparingDelete` with no
        // matching prompt belongs to the live first confirmation dialog,
        // which the switch below refuses to race.
        if let pending = pendingForceDeleteWorktree,
           pending.id == worktree.id, pending.projectId == worktree.projectId {
            pendingForceDeleteWorktree = nil
            releaseClaim(of: pending)
        }
        switch projectsManager.operationState(for: worktree) {
        case .deleting:
            return .ok
        case .archiving:
            return .error("the worktree is being archived")
        case .preparingDelete:
            // A delete confirmation this call does not own is already on
            // screen for this worktree (`NSAlert.runModal()`'s nested run
            // loop is exactly how this CLI request is able to run at all
            // while that alert is still up). Let that decision resolve on
            // its own instead of racing session admission or the removal
            // itself against it.
            return .error("a delete confirmation is already pending for this worktree")
        default:
            break
        }
        let claim: UUID
        do {
            claim = try await host.worktrees.beginDelete(worktree, force: force, caller: caller)
        } catch {
            return .error(error.localizedDescription)
        }
        let dirty = dirtyTabGenerations(worktreeId: worktree.id)
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            host.worktrees.releaseClaim(claim, for: worktree)
            return .error("Could not find the project for this worktree.")
        }
        let preflight = await Self.performDeletePreflight(worktreePath: worktree.path)
        if !force, preflight.requiresForce {
            host.worktrees.releaseClaim(claim, for: worktree)
            if preflight.reasons.contains(.dirty) {
                return .error("worktree has local changes; rerun with --force to delete")
            }
            return .error("worktree requires force delete; rerun with --force to delete")
        }

        let removedIndex = projectsManager.visibleWorktrees(projectId: worktree.projectId)
            .firstIndex(where: { $0.id == worktree.id }) ?? 0
        host.worktrees.confirmDelete(claim, for: worktree)
        Task { @MainActor in
            await performDeleteWorktree(
                worktree: worktree,
                claim: claim,
                repoPath: URL(fileURLWithPath: project.path),
                deleteBranchIfMerged: Self.resolveDeleteBranchIfMerged(
                    globalDeleteOnRemove: config.worktrees.deleteBranchOnRemove,
                    keepBranch: keepBranch
                ),
                force: force,
                removedIndex: removedIndex,
                // `--force` discards the editors' unsaved changes as they are now.
                acknowledgedDirtyTabs: dirty
            )
            // The CLI cannot answer the force prompt; leave the refusal on the row.
            if let pending = pendingForceDeleteWorktree,
               pending.id == worktree.id, pending.projectId == worktree.projectId {
                pendingForceDeleteWorktree = nil
                host.worktrees.failClaim(pending.claim, for: worktree, message: "worktree requires force delete; rerun with --force to delete")
            }
        }
        return .ok
    }

    /// Opens the review `alas review <target>` names: the host resolves and
    /// saves it, and this shows its tab.
    func cliOpenReview(worktree: Worktree, target: String, caller: HostCaller) async -> AlasCLIResponse {
        switch await host.reviews.open(target, in: worktree, caller: caller) {
        case .failure(let failure):
            return .error(failure.message)
        case .success(let opened):
            _ = tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: opened.record)
            focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
            NSApp.activate(ignoringOtherApps: true)
            return .text([
                "Opened review for '\(opened.label)' in Alas.",
                ReviewsAPI.jsonLine(["session_id": opened.record.target.draftSessionID.rawValue]),
            ])
        }
    }

    /// Resolves the pre-rename `originalPath` for `relativePath` in the
    /// provider review identified by `sessionID`, by loading the review's
    /// diff (cached per session). Returns nil on any failure — a nil
    /// `originalPath` is exactly the prior behavior, so this never blocks or
    /// alters filing a comment.
    func reviewRequestOriginalPath(
        forDraftSessionID sessionID: ReviewDraftSessionID,
        relativePath: String
    ) async -> String? {
        if let cached = providerReviewFileSummaryCache[sessionID] {
            return ProviderReviewOriginalPathResolver.originalPath(forRelativePath: relativePath, in: cached)
        }
        do {
            // Find the persisted review session record for this draft session.
            // Scan all worktrees, not just visible ones: the CLI resolves its
            // origin worktree via `worktree(withId:)`, which includes hidden
            // worktrees, so a comment filed from a hidden worktree must still
            // find its session record here.
            let sessionStore = core.reviewSessions
            let allWorktrees = projects.flatMap { projectsManager.worktrees(projectId: $0.id) }
            var record: ReviewSessionRecord?
            for worktree in allWorktrees where sessionID.isFor(worktreeID: worktree.id) {
                record = try sessionStore.list(worktreeID: worktree.id)
                    .first(where: { $0.target.draftSessionID == sessionID })
                if record != nil { break }
            }
            guard let record,
                  case .reviewRequest(_, let host, let repositorySlug, let number, _) = record.target.payload,
                  let worktree = worktree(withId: record.target.worktreeID) else {
                return nil
            }

            let registry = CodeHostProviderRegistry.live()
            let supportedRemotes = try await core.supportedReviewRemotes(for: worktree, registry: registry)
            // Require the exact remote the session was opened against. Falling
            // back to a different remote would load that repository's PR/MR of
            // the same number and could stamp an `originalPath` from an
            // unrelated review; nil is the correct best-effort result instead.
            guard let remote = supportedRemotes.first(where: {
                $0.host == host && $0.repositorySlug.lowercased() == repositorySlug.lowercased()
            }), let provider = registry.provider(for: remote.kind) else { return nil }

            let request = try await provider.reviewRequest(remote: remote, number: number, cwd: worktree.path)
            let loaded = try await ReviewRequestDiffLoader(provider: provider)
                .load(remote: remote, request: request, cwd: worktree.path)
            let files = loaded.summary.files
            providerReviewFileSummaryCache[sessionID] = files
            return ProviderReviewOriginalPathResolver.originalPath(forRelativePath: relativePath, in: files)
        } catch {
            return nil
        }
    }

    /// Deletes a worktree claimed by `host.worktrees.beginDelete` through the host,
    /// then settles what only the app has: the force prompt (or, when
    /// `promptsForForce` is false, as in batches that must never pop a modal
    /// mid-run, the outcome instead), the persisted GG mode, and selection.
    /// `acknowledgedDirtyTabs` are the unsaved edits the user agreed to
    /// discard; anything else dirty refuses at quiesce.
    @discardableResult
    private func performDeleteWorktree(
        worktree: Worktree,
        claim: UUID,
        repoPath: URL,
        deleteBranchIfMerged: Bool,
        force: Bool,
        removedIndex: Int,
        refreshAfter: Bool = true,
        promptsForForce: Bool = true,
        isBatch: Bool = false,
        authorizedDeleteContentFingerprint: String? = nil,
        acknowledgedDirtyTabs: [TabID: Int] = [:],
        verifiedMergedBranchSHA: String? = nil
    ) async -> WorktreeBatchOutcome {
        var options = WorktreeDeleteOptions()
        options.force = force
        options.deleteBranchIfMerged = deleteBranchIfMerged
        options.verifiedMergedBranchSHA = verifiedMergedBranchSHA
        options.authorizedContentFingerprint = authorizedDeleteContentFingerprint
        options.keepsClaimForForcePrompt = promptsForForce
        // Batches report skips in their results and leave the row as it was.
        options.recordsSkips = !isBatch
        options.refreshesProject = refreshAfter
        if isBatch {
            // The scan's branch can be stale: a detached checkout's commits
            // are reachable only through its own HEAD.
            options.revalidate = {
                WorktreeService.localBranchName(forWorktreeAt: worktree.path) == worktree.branch
                    ? nil : WorktreeRemovalResult.changedSinceConfirmationMessage
            }
        }
        let outcome: WorktreeDeletionOutcome
        do {
            outcome = try await withAcknowledgedDirtyTabs(acknowledgedDirtyTabs, for: worktree) {
                await host.worktrees.delete(worktree, claim: claim, options: options)
            }
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        if case .deletedButNotSaved(let message) = outcome {
            persistenceErrorHandler("Projects Save Failed", message)
        }
        switch outcome {
        case .deleted, .deletedButNotSaved:
            removePersistedGGWorktreeMode(projectId: worktree.projectId, worktreeId: worktree.id)
            // Callers that skip the refresh (batches, which refresh once at the
            // end) reconcile the selection themselves afterwards.
            if refreshAfter, selectedWorktreeId == worktree.id {
                selectWorktree(id: selectionAfterRemoval(
                    removedFromProjectId: worktree.projectId,
                    removedAtIndex: removedIndex
                ))
            }
            return .deleted
        case .needsForce(let refusal):
            guard promptsForForce else { return .needsForce }
            if let pending = Self.pendingForceDelete(
                for: worktree,
                claim: claim,
                repoPath: repoPath,
                deleteBranchIfMerged: deleteBranchIfMerged,
                removedIndex: removedIndex,
                stderr: refusal,
                acknowledgedDirtyTabs: acknowledgedDirtyTabs
            ) {
                // The core kept the claim as `.preparingDelete` for this
                // SwiftUI alert, which yields to other main-actor work as
                // readily as `NSAlert.runModal()` does.
                pendingForceDeleteWorktree = pending
            } else {
                host.worktrees.failClaim(claim, for: worktree, message: refusal)
            }
            return .needsForce
        case .skipped(let reason):
            return .skipped(reason: reason)
        case .failed(let message):
            return .failed(message: message)
        }
    }

    /// Called from the SwiftUI alert when the user confirms force delete.
    func confirmForceDeletePendingWorktree() {
        guard let pending = pendingForceDeleteWorktree else { return }
        pendingForceDeleteWorktree = nil
        guard let worktree = projectsManager.worktrees(projectId: pending.projectId).first(where: { $0.id == pending.id })
        else { return }
        host.worktrees.confirmDelete(pending.claim, for: worktree)
        Task { @MainActor in
            await performDeleteWorktree(
                worktree: worktree,
                claim: pending.claim,
                repoPath: pending.repoPath,
                deleteBranchIfMerged: pending.deleteBranchIfMerged,
                force: true,
                removedIndex: pending.removedIndex,
                acknowledgedDirtyTabs: pending.acknowledgedDirtyTabs
            )
        }
    }

    /// Called from the SwiftUI alert when the user cancels force delete.
    func cancelForceDeletePendingWorktree() {
        if let pending = pendingForceDeleteWorktree {
            releaseClaim(of: pending)
        }
        pendingForceDeleteWorktree = nil
    }

    /// Gives back the claim a pending force prompt holds.
    private func releaseClaim(of pending: PendingForceDeleteWorktree) {
        if let worktree = projectsManager.worktrees(projectId: pending.projectId).first(where: { $0.id == pending.id }) {
            host.worktrees.releaseClaim(pending.claim, for: worktree)
        }
    }

    nonisolated private static func performDeletePreflight(worktreePath: URL) async -> WorktreeDeletePreflight {
        do {
            return try await Task.detached {
                try await WorktreeService().deletePreflight(worktreePath: worktreePath)
            }.value
        } catch {
            return WorktreeDeletePreflight(reasons: [])
        }
    }

    /// Resolve whether `git branch -d` should run after `git worktree remove`.
    /// `keepBranch == true` (a per-operation override) always wins — the local
    /// branch is preserved regardless of the global setting.
    nonisolated static func resolveDeleteBranchIfMerged(
        globalDeleteOnRemove: Bool,
        keepBranch: Bool
    ) -> Bool {
        globalDeleteOnRemove && !keepBranch
    }

    nonisolated static func deleteConfirmation(
        branch: String,
        keepBranch: Bool
    ) -> WorktreeDeleteConfirmation {
        WorktreeDeleteConfirmation(
            title: "Delete worktree '\(branch)'?",
            message: keepBranch
                ? "This removes its files from disk. The local branch will be kept."
                : "This removes its files from disk. The local branch will be deleted if merged."
        )
    }

    nonisolated static func worktreeDeleteContentFingerprint(worktreePath: URL) async throws -> String {
        try await WorktreeService.worktreeDeleteContentFingerprint(worktreePath: worktreePath)
    }

    nonisolated static func pendingForceDelete(
        for worktree: Worktree,
        claim: UUID,
        repoPath: URL,
        deleteBranchIfMerged: Bool,
        removedIndex: Int,
        stderr: String,
        acknowledgedDirtyTabs: [TabID: Int] = [:]
    ) -> PendingForceDeleteWorktree? {
        guard requiresForceRetry(forRemovalRefusal: stderr) else { return nil }
        return PendingForceDeleteWorktree(
            id: worktree.id,
            branch: worktree.branch,
            projectId: worktree.projectId,
            repoPath: repoPath,
            worktreePath: worktree.path,
            deleteBranchIfMerged: deleteBranchIfMerged,
            removedIndex: removedIndex,
            claim: claim,
            acknowledgedDirtyTabs: acknowledgedDirtyTabs
        )
    }

    nonisolated static func requiresForceRetry(forRemovalRefusal stderr: String) -> Bool {
        WorktreeService.requiresForceRetry(forRemovalRefusal: stderr)
    }

    func confirmDeleteWorktree(_ confirmation: WorktreeDeleteConfirmation) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        deleteButton.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private enum DirtyBufferChoice {
        case save
        case discard
        case cancel
    }

    private enum DirtyBufferBatchChoice {
        case discard
        case cancel
    }

    /// Two-choice variant of `promptForDirtyBuffers` for batch actions. The
    /// single-item flow can offer a truthful "Save & <action>" button because
    /// it saves that one worktree before proceeding; a batch has no such step
    /// wired in, so offering the same button and then neither saving nor
    /// acting on it would make the button lie about what it does. This asks
    /// the user to save manually and retry instead.
    private func promptForDirtyBuffersInBatch(
        action: String,
        worktreeCount: Int,
        dirtyCount: Int,
        onDiskDestructive: Bool
    ) -> DirtyBufferBatchChoice {
        let alert = NSAlert()
        alert.messageText = "\(action) \(worktreeCount) \(worktreeCount == 1 ? "worktree" : "worktrees")?"
        let countSentence = dirtyCount == 1
            ? "1 file has unsaved changes."
            : "\(dirtyCount) files have unsaved changes."
        let actionSentence = onDiskDestructive
            ? "Save it first, then retry — \(action.lowercased())ing will discard it along with the worktree's files."
            : "Save it first, then retry — the worktree stays on disk, but its open tabs will close."
        alert.informativeText = "\(countSentence) \(actionSentence)"
        alert.alertStyle = .warning
        let discardButton = alert.addButton(withTitle: "Discard & \(action)")
        alert.addButton(withTitle: "Cancel")
        discardButton.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn ? .discard : .cancel
    }

    /// Returns the editor tabs in this worktree whose buffers have unsaved
    /// changes — including tabs whose buffers are not yet instantiated but
    /// have a persisted hot-exit snapshot on disk.
    private func dirtyEditorTabIds(worktreeId: String) -> [TabID] {
        tabs.tabIdsWithUnsavedChanges(forWorktree: worktreeId)
    }

    /// Three-way prompt for actions (archive, delete) that would otherwise
    /// silently discard unsaved editor buffers. The default button (Enter)
    /// is "Save & <action>"; the destructive button is "Discard & <action>".
    /// `onDiskDestructive` true means `<action>` will also remove files from
    /// disk; the message text adjusts accordingly.
    private func promptForDirtyBuffers(
        action: String,
        branch: String,
        dirtyCount: Int,
        onDiskDestructive: Bool,
        keepBranch: Bool = false
    ) -> DirtyBufferChoice {
        let alert = NSAlert()
        alert.messageText = "\(action) worktree '\(branch)'?"
        let countSentence = dirtyCount == 1
            ? "1 file has unsaved changes."
            : "\(dirtyCount) files have unsaved changes."
        let actionSentence: String
        if onDiskDestructive {
            actionSentence = keepBranch
                ? "This removes its files from disk. The local branch will be kept."
                : "This removes its files from disk. The local branch will be deleted if merged."
        } else {
            actionSentence = "The worktree itself stays on disk."
        }
        alert.informativeText = "\(countSentence) Saving will write them to disk; discarding will lose them. \(actionSentence)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save & \(action)")
        let discardButton = alert.addButton(withTitle: "Discard & \(action)")
        alert.addButton(withTitle: "Cancel")
        discardButton.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func promptForDirtyBuffersOnRemoveProject(
        name: String,
        dirtyCount: Int
    ) -> DirtyBufferChoice {
        let alert = NSAlert()
        alert.messageText = "Remove project '\(name)'?"
        let countSentence = dirtyCount == 1
            ? "1 file has unsaved changes."
            : "\(dirtyCount) files have unsaved changes."
        alert.informativeText = "\(countSentence) Saving will write them to disk; discarding will lose them. Alas will stop tracking this project. No files will be deleted from disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save & Remove")
        let discardButton = alert.addButton(withTitle: "Discard & Remove")
        alert.addButton(withTitle: "Cancel")
        discardButton.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Save every dirty editor buffer in the given worktree — including tabs
    /// whose buffers are not yet instantiated but have a persisted hot-exit
    /// snapshot on disk. Returns true on full success; on partial failure
    /// surfaces an aggregate error and returns false so the caller can bail
    /// before the destructive cleanup.
    private func saveDirtyBuffers(in worktree: Worktree) async -> Bool {
        let errors = await tabs.saveAllUnsavedAwaitingRemote(forWorktree: worktree.id, root: worktree.path)
        if !errors.isEmpty {
            let count = errors.count
            showFileActionError(
                title: "Save Failed",
                message: "\(count) file\(count == 1 ? "" : "s") could not be saved. The worktree was not archived or deleted."
            )
            return false
        }
        return true
    }

    // MARK: - ACP

    /// ACP managers are keyed by their typed durable owner. Worktree keys stay
    /// source-compatible through the accessors below; checkout UUID/location
    /// pairs cannot collide with them or with each other.
    @ObservationIgnored
    private var acpManagers: [SessionOwnerID: ACPSessionManager] {
        get { core.sessionManagers }
        set { core.sessionManagers = newValue }
    }

    /// The owner whose manager holds live ACP session `id`.
    func acpOwner(forSession id: String) -> SessionOwnerID? {
        acpManagers.first { $0.value.liveSession(for: id) != nil }?.key
    }
    /// The project each worktree manager was built for, to notice a directory
    /// that later moved to another project.
    private var acpManagerProjectIds: [SessionOwnerID: String] = [:]

    @ObservationIgnored
    private var acpOrchestrationPersistence: ACPOrchestrationPersistence { core.orchestrationPersistence }

    /// Each delegated session's parent, as the core records it. The agent
    /// sidebar draws delegated children under their parent from it.
    var delegatedSessionParents: [String: String] { core.delegatedSessionParents }

    /// The parent that delegated `sessionId`, from memory or the persisted
    /// delegation record.
    func delegatedParentSessionID(for sessionId: String) async -> String? {
        await core.delegatedParentSessionID(for: sessionId)
    }

    func nextPromptHasDelegatedWork(parentID: String) -> Bool {
        acpManagers.values.contains { manager in
            manager.sessions.values.contains { child in
                delegatedSessionParents[child.id] == parentID &&
                (child.agentState == .spawning || child.transcript.streamingState != .idle ||
                 child.nextPromptWorkCount > 0 || child.hasPendingDelegatedMessages || !child.queue.isEmpty ||
                 child.pendingQueuePersistenceCount > 0 || child.subagents.values.contains { $0.isRunning })
            }
        }
    }

    /// Force-flush every per-session debounced composer-draft write across
    /// all live managers. Called from app-will-terminate so an in-flight
    /// typing burst doesn't lose its last ~300ms of input to the
    /// debounce window.
    func flushAllACPComposerDrafts() async {
        for manager in acpManagers.values {
            manager.flushPendingDraftWrites()
        }
        for manager in acpManagers.values {
            await manager.flushAllPersistence()
        }
    }

    /// Mirrors `ACPSession.streamingState` into `HarnessService.activityBySession`
    /// so the sidebar work badge surfaces ACP activity. Attached for every
    /// manager created via `acpManager(for:)`; detached from `disposeACPManager(for:)`.
    @ObservationIgnored
    private lazy var acpHarnessBridge = ACPHarnessBridge(
        harness: harness,
        acknowledgeSessionInteraction: { [weak self] owner, sessionID in
            self?.acknowledgeACPResponseInteraction(owner: owner, sessionID: sessionID)
        }
    )

    #if DEBUG
    @ObservationIgnored
    lazy var memoryDiagnostics: MemoryDiagnostics = {
        let d = MemoryDiagnostics()
        d.startTicker(interval: 30)
        return d
    }()
    #endif

    /// Returns `true` when the editor has a live, dirty (unsaved) buffer for
    /// the given absolute path within the given worktree.
    func editorHasDirtyBuffer(for absolutePath: String, worktreeId: String) -> Bool {
        guard let relativePath = relativePath(for: absolutePath, in: worktreeId) else { return false }
        return tabs.hasDirtyBuffer(worktreeId: worktreeId, relativePath: relativePath)
    }

    /// In-memory editor contents for `absolutePath` when a dirty buffer
    /// is open, otherwise `nil`. Used by the ACP read handler so agent
    /// reads include unsaved edits.
    func editorLiveBufferText(for absolutePath: String, worktreeId: String) -> String? {
        guard let relativePath = relativePath(for: absolutePath, in: worktreeId) else { return nil }
        return tabs.dirtyBufferText(worktreeId: worktreeId, relativePath: relativePath)
    }

    /// Read-only facts used by checkpoint preview and restore preflight. A
    /// Workspace checkout remains a shared session owner. Count checkout-owned
    /// writers for every checkout that contains this member worktree, even
    /// when the user has navigated away from that checkout.
    func checkpointCoordination(
        for worktree: Worktree,
        selectedPaths: Set<String>
    ) -> CheckpointCoordinationSnapshot {
        let lineageID = worktree.lineageID ?? WorktreeService.existingLocalLineageID(forWorktreeAt: worktree.path)
        var terminalCount = terminal.registry.sessions(forWorktree: worktree.id).count
        if let lineageID {
            terminalCount += checkpointWriterLeases.activeLeaseCount(lineageID: lineageID, excludingInstanceID: instanceId)
        }
        var acpCount = checkpointACPLeaseCount(owner: .worktree(worktree.id))
        var workspaceName: String?
        var repositoryName = projects.first(where: { $0.id == worktree.projectId })?.name ?? worktree.name

        let worktreePath = worktree.path.standardizedFileURL.path
        let matchingCheckouts = workspacesManager.checkouts.compactMap { checkout -> (WorkspaceCheckout, WorkspaceCheckoutMember)? in
            guard checkout.archivedAt == nil,
                  let member = checkout.members.first(where: {
                      $0.projectID == worktree.projectId &&
                          URL(fileURLWithPath: checkout.inAppWorktreePath($0.worktreePath)).standardizedFileURL.path == worktreePath
                  })
            else { return nil }
            return (checkout, member)
        }
        for (checkout, member) in matchingCheckouts {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            terminalCount += terminal.registry.sessions(forWorktree: owner.storageKey).count
            acpCount += checkpointACPLeaseCount(owner: owner)
            if checkout.id == selectedWorkspaceCheckout?.id {
                workspaceName = checkout.fallbackWorkspaceName
            }
            repositoryName = projects.first(where: { $0.id == member.projectID })?.name ?? member.fallbackProjectName
        }

        let pane = rightPaneStore.activeState(worktreeId: worktree.id)
        let dirtyEditorPaths = CheckpointCoordinationSnapshot.overlappingPaths(
            dirtyPaths: tabs.unsavedRelativePaths(forWorktree: worktree.id),
            selectedPaths: selectedPaths
        )
        return .init(
            dirtyEditorPaths: dirtyEditorPaths,
            activeTerminalCount: terminalCount,
            activeACPCount: acpCount,
            otherGitMutationActive: (pane?.hasOtherGitMutationInFlight ?? false) || hasCenterGitMutationInFlight(worktreeId: worktree.id),
            scopeDescription: CheckpointCoordinationSnapshot.scopeDescription(
                repositoryName: repositoryName,
                workspaceName: workspaceName
            )
        )
    }

    private func acquireCheckpointTerminalLease(for session: TerminalSession) {
        let lineageIDs = checkpointTerminalLeaseLineageIDs(for: session)
        checkpointWriterLeases.acquire(
            lineageIDs: lineageIDs,
            sessionID: session.id,
            instanceID: instanceId,
            zmxSessionName: session.zmxSessionName,
            remoteHost: session.remoteHost
        )
    }

    private func checkpointTerminalLeaseLineageIDs(for session: TerminalSession) -> Set<String> {
        switch session.owner {
        case .worktree(let worktreeID):
            return worktree(withId: worktreeID).flatMap(\.lineageID).map { [$0] } ?? []
        case .workspaceCheckout(let checkoutID, let location):
            guard let checkout = workspacesManager.checkout(id: checkoutID),
                  checkout.executionLocation.normalized == location.normalized
            else { return [] }
            return Set(checkout.members.compactMap { member in
                checkpointMemberWorktree(for: member, in: checkout)?.lineageID
            })
        }
    }

    private func checkpointACPLeaseCount(owner: SessionOwnerID) -> Int {
        do {
            return try ACPSessionStore(path: Paths.acpSessionsDB(for: owner).path).activeLeaseCount(
                now: Int64(Date().timeIntervalSince1970),
                staleAfter: ACPSessionManager.leaseStaleAfter
            )
        } catch {
            return acpManager(for: owner)?.hasActiveCheckpointWriter == true ? 1 : 0
        }
    }

    private func checkpointTerminalAdmissionDisabled(for checkout: WorkspaceCheckout) -> Bool {
        for member in checkout.members where member.availability == .available {
            guard let worktree = checkpointMemberWorktree(for: member, in: checkout) else { continue }
            if checkpointTerminalAdmissionDisabled(worktreeId: worktree.id) { return true }
        }
        return false
    }

    private func checkpointTerminalAdmissionDisabledAfterDiscovery(for checkout: WorkspaceCheckout) async -> Bool {
        for member in checkout.members where member.availability == .available {
            guard let worktree = checkpointMemberWorktree(for: member, in: checkout) else { continue }
            if await checkpointTerminalAdmissionDisabledAfterDiscovery(worktreeId: worktree.id) { return true }
        }
        return false
    }

    private func checkpointMemberWorktree(for member: WorkspaceCheckoutMember, in checkout: WorkspaceCheckout) -> Worktree? {
        let liveWorktrees = projectsManager.worktrees(projectId: member.projectID)
        let cachedWorktrees = projects.first(where: { $0.id == member.projectID })?.cachedWorktrees ?? []
        return (liveWorktrees + cachedWorktrees).first(where: {
                Self.canonicalWorktreePath($0.path.path)
                    == Self.canonicalWorktreePath(checkout.inAppWorktreePath(member.worktreePath))
        })
    }

    func checkpointTarget(for worktree: Worktree) -> CheckpointWorktreeTarget? {
        guard !worktree.path.isRemoteAlasPath,
              !isFolderWorktree(worktree),
              let lineageID = worktree.lineageID ?? WorktreeService.existingLocalLineageID(forWorktreeAt: worktree.path)
        else { return nil }
        let project = projects.first(where: { $0.id == worktree.projectId })
        let workspaceName: String?
        if workspaceNavigationState.repositoryFocusWorktreeID == worktree.id {
            workspaceName = selectedWorkspaceCheckout?.fallbackWorkspaceName
        } else {
            workspaceName = nil
        }
        return .init(
            worktreeID: worktree.id,
            projectID: worktree.projectId,
            path: worktree.path,
            lineageID: lineageID,
            branch: worktree.branch,
            repositoryName: project?.name ?? worktree.name,
            workspaceName: workspaceName
        )
    }

    private func relativePath(for absolutePath: String, in worktreeId: String) -> String? {
        guard let worktree = worktree(withId: worktreeId) else { return nil }
        let root = worktree.path.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let target = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// Returns the cached ACP session manager for a worktree id, if one exists.
    /// Does not create a new manager — use `acpManager(for:)` when lazy
    /// creation is acceptable.
    func acpManager(forWorktreeId id: String) -> ACPSessionManager? {
        acpManagers[.worktree(id)]
    }

    /// The manager owns persisted history; center tabs only supply terminal rows.
    func agentSidebarRollup(for worktree: Worktree) -> AgentSidebarRollup {
        let manager = acpManager(forWorktreeId: worktree.id)
        let terminalTabs = tabs.tabs(forWorktree: worktree.id).compactMap { tab -> TerminalTabState? in
            guard case .terminal(let terminal) = tab else { return nil }
            return terminal
        }
        let liveSessions = manager?.sessions.values.filter { session in
            manager?.sessionRows.first(where: { $0.id == session.id })?.archived != true
        } ?? []
        return AgentSidebarRollupBuilder.build(.init(
            worktreeID: worktree.id,
            persistedACP: manager?.sessionRows.filter { !$0.archived } ?? [],
            liveACP: liveSessions.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            },
            terminalTabs: terminalTabs,
            harnessActivity: harness.activityBySession,
            remoteHost: projectAndWorktree(withWorktreeId: worktree.id)?.project.host,
            delegatedParents: delegatedSessionParents
        ))
    }

    func focusAgentSidebarRow(_ rowID: AgentSidebarRowID, in worktree: Worktree) async {
        switch rowID {
        case .acp(let sessionID):
            guard let manager = acpManager(forWorktreeId: worktree.id),
                  manager.liveSession(for: sessionID) != nil
                    || manager.sessionRows.contains(where: { $0.id == sessionID && !$0.archived })
            else { return }
            selectWorktree(id: worktree.id)
            await openExistingACPSession(sessionId: sessionID, worktree: worktree)
        case .terminal(let tabID, let sessionID):
            let matchingLeafID = tabs.tabs(forWorktree: worktree.id).compactMap { tab -> String? in
                guard tab.id == tabID,
                      case .terminal(let terminal) = tab,
                      let leaf = terminal.root.leaves().first(where: { $0.sessionId == sessionID })
                else { return nil }
                return leaf.id
            }.first
            guard let matchingLeafID else { return }
            selectWorktree(id: worktree.id)
            _ = tabs.setFocusedLeaf(worktreeId: worktree.id, tabId: tabID, leafId: matchingLeafID)
            activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tabID)
        }
    }

    func sendAgentSidebarFollowUp(for sessionID: ACPSession.ID, worktreeID: String, text: String) {
        guard let complete = beginAgentSidebarFollowUp(for: sessionID, worktreeID: worktreeID, text: text) else { return }
        Task {
            await sendPrompt(for: sessionID, worktreeID: worktreeID, text: text, attachments: [], onResult: complete)
        }
    }

    /// Own completion in AppState so a hidden pane cannot lose a failed message.
    func beginAgentSidebarFollowUp(
        for sessionID: ACPSession.ID,
        worktreeID: String,
        text: String
    ) -> (@MainActor (Bool) -> Void)? {
        guard agentSidebarFollowUps[worktreeID]?[sessionID]?.delivery != .sending,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        agentSidebarFollowUps[worktreeID, default: [:]][sessionID] = .init(text: text, delivery: .sending)
        return { [weak self] succeeded in
            guard let self else { return }
            self.agentSidebarFollowUps[worktreeID, default: [:]][sessionID]?.delivery = succeeded ? .sent : .failed
            if succeeded, self.agentSidebarFollowUps[worktreeID]?[sessionID]?.text == text {
                self.agentSidebarFollowUps[worktreeID, default: [:]][sessionID]?.text = ""
            }
        }
    }

    func acpManager(for owner: SessionOwnerID) -> ACPSessionManager? {
        acpManagers[owner]
    }

    func acpManager(forOwnerKey key: String) -> ACPSessionManager? {
        if let worktree = worktree(withId: key) {
            return acpManager(for: worktree)
        }
        return acpManagers.first { $0.key.storageKey == key }?.value
    }

    func hydrateAndAttachACP(manager: ACPSessionManager, sessionId: ACPSession.ID) async {
        await manager.hydrateIfNeeded(id: sessionId)
        guard let session = manager.liveSession(for: sessionId) else { return }
        if case .failed = session.hydrationState { return }
        guard await !checkpointACPAdmissionDisabledAfterDiscovery(owner: manager.owner, fallbackWorktree: nil) else {
            session.lastError = Self.checkpointRecoveryBlocksACPMessage
            return
        }
        let freshlyCreated = manager.runners[sessionId] == nil
            && ACPSessionAttachFreshness.isFresh(
                restoredFromPersistence: session.restoredFromPersistence,
                remoteSessionId: session.remoteSessionId
            )
        await manager.attach(to: sessionId, freshlyCreated: freshlyCreated)
    }

    /// Brings an open chat tab's session up so a prompt can be handed to it.
    /// A restored tab that was never selected has no live session or writer
    /// lease until its view mounts, and a restored checkout tab may not have
    /// its manager yet. Attaching here coalesces with the attach the mounting
    /// tab starts, and never takes a lease another live instance holds, so
    /// the send that follows fails instead of taking over.
    func prepareACPSessionForPrompt(sessionId: ACPSession.ID, owner: SessionOwnerID) async {
        let manager: ACPSessionManager?
        switch owner {
        case .worktree(let worktreeId):
            manager = worktree(withId: worktreeId).flatMap { acpManager(for: $0) }
        case .workspaceCheckout:
            manager = await checkoutACPManagerForPrompt(owner: owner)
        }
        guard let manager, !manager.isWriter(for: sessionId) else { return }
        // A cold restored tab's row is not cached yet, and the synchronous
        // `placeholderSession` only starts loading it. Load it first.
        if manager.liveSession(for: sessionId) == nil {
            guard await manager.persistedSessionRow(id: sessionId) != nil else { return }
        }
        // Not retained: a release here would evict a session that failed to
        // attach before the send could report it. The activated tab retains it.
        guard manager.placeholderSession(id: sessionId) != nil else { return }
        await hydrateAndAttachACP(manager: manager, sessionId: sessionId)
    }

    /// The checkout's ACP manager, created when restoration has not made it
    /// yet (e.g. an SSH location still being validated). Mirrors
    /// `openWorkspaceCheckoutACPSession`: a checkout that stops being
    /// authoritative meanwhile gets its new manager disposed.
    private func checkoutACPManagerForPrompt(owner: SessionOwnerID) async -> ACPSessionManager? {
        if let existing = acpManager(for: owner) { return existing }
        guard let checkout = workspaceCheckout(for: owner),
              case .ready(let manager) = await workspaceACPManager(for: checkout)
        else { return nil }
        guard await authoritativeCheckoutForWorkspaceACPSessionCreation(checkout) != nil else {
            await disposeACPManagerAndWait(owner: owner)
            return nil
        }
        return manager
    }

    // MARK: Session references

    /// Sessions of `projectId` the composer can attach, most recent first.
    func acpSessionMentionCandidates(projectId: String, excluding sessionId: String?) async -> [ACPSessionMentionCandidate] {
        await core.acpSessionMentionCandidates(projectId: projectId, excluding: sessionId)
    }

    /// The attachable session `sessionId`.
    func acpSessionMentionCandidate(sessionId: String) async -> ACPSessionMentionCandidate? {
        await core.acpSessionMentionCandidate(sessionId: sessionId)
    }

    /// A session of `projectId`, live or stored, made live. With
    /// `loadingFullTranscript`, its whole transcript is loaded; otherwise
    /// only what hydration loads first, the latest messages. Nil when
    /// unknown or archived. Looked up in each of
    /// the project's worktree stores, opened or not, rather than the
    /// recent-row snapshot: an attachment can outlive both. Every lookup
    /// retains the session until the caller calls the location's `release`,
    /// so concurrent readers share it and the last one out lets an idle,
    /// otherwise unreferenced session be evicted again.
    func acpReferencedSessionLocation(
        _ sessionId: String, projectId: String, loadingFullTranscript: Bool
    ) async -> ACPSessionOrchestrationCoordinator.SessionLocation? {
        await core.acpReferencedSessionLocation(sessionId, projectID: projectId, loadingFullTranscript: loadingFullTranscript)
    }

    /// What a prompt in `projectId` carries in place of an attached session.
    /// Sessions of other projects are not resolved.
    func acpSessionReferenceContext(_ sessionId: String, projectId: String) async -> String? {
        // The inline context keeps only the latest entries, so it skips the
        // full-history backfill that `session_read` pages through.
        guard let location = await acpReferencedSessionLocation(
            sessionId, projectId: projectId, loadingFullTranscript: false
        ) else { return nil }
        defer { location.release?() }
        guard location.origin.projectId == projectId,
              let session = location.manager.liveSession(for: sessionId),
              let worktree = worktree(withId: location.origin.worktreeId)
        else { return nil }
        let target = ACPSessionReference.Target(
            sessionId: sessionId,
            title: session.title,
            agentName: agent(id: session.agentId)?.displayName ?? session.agentId,
            worktreeName: worktree.name
        )
        return ACPSessionReference.context(
            for: target, entries: ACPSessionTranscriptReader.entries(session.transcript.messages)
        )
    }

    /// Mounted tabs can outlive the project claim in their original worktree
    /// value. Checkout owners keep their independent manager boundary.
    func acpManagerForMountedTab(worktree: Worktree, owner: SessionOwnerID?) -> ACPSessionManager? {
        if let owner, owner != .worktree(worktree.id) {
            return acpManager(for: owner)
        }
        return acpManager(for: worktree)
    }

    /// Returns (or lazily creates) the ACP session manager for the given worktree.
    /// Store opening and migration happen lazily on the persistence actor.
    func acpManager(for worktree: Worktree) -> ACPSessionManager? {
        let worktree = self.worktree(withId: worktree.id) ?? worktree
        let owner = SessionOwnerID.worktree(worktree.id)
        var previousManagerDisposal: Task<Void, Never>?
        // A manager disposed by a delete in progress must not come back.
        guard acpManagers[owner] != nil || projectsManager.admitsNewWork(in: worktree) else { return nil }
        if let existing = acpManagers[owner] {
            // The manager's providers captured the project that owned the
            // directory when it was built. When ownership has moved, replace it
            // once all turns are idle, even if their runners stay connected.
            guard let builtFor = acpManagerProjectIds[owner], builtFor != worktree.projectId,
                  existing.isIdleForProjectRebinding
            else { return existing }
            previousManagerDisposal = disposeACPManager(owner: owner)
        }
        let dbURL = Paths.acpSessionsDB(forWorktreeId: worktree.id)
        let persistence = ACPSessionPersistence(path: dbURL.path)
        let mgr = ACPSessionManager(
            worktreeId: worktree.id,
            worktreePath: worktree.path.path,
            persistence: persistence,
            previousManagerDisposal: previousManagerDisposal,
            instanceId: instanceId,
            pid: Int64(ProcessInfo.processInfo.processIdentifier),
            hydratorPath: dbURL.path,
            onDirtyCheck: { [weak self] path in
                self?.editorHasDirtyBuffer(for: path, worktreeId: worktree.id) ?? false
            },
            onLiveBufferRead: { [weak self] path in
                self?.editorLiveBufferText(for: path, worktreeId: worktree.id)
            },
            onSessionTitleUpdated: { [weak self] sessionId, title in
                _ = self?.tabs.renameACPSessionTabs(
                    worktreeId: worktree.id,
                    sessionId: sessionId,
                    title: title
                )
            },
            onUserPromptRecorded: { [weak self] _, text in
                self?.autoNameBranchIfPending(worktreeId: worktree.id, prompt: text)
            },
            localTitlesEnabled: { [weak self] in
                self?.config.harness.acpLocalTitlesEnabled ?? false
            },
            autoResumeAfterUsageLimit: { [weak self] in
                self?.config.harness.acpAutoResumeAfterUsageLimit ?? true
            },
            continueInterruptedSessions: { [weak self] in
                self?.config.harness.acpContinueInterruptedSessions ?? false
            },
            qwenTitleFallback: makeQwenTitleFallback(),
            onInputAwaiting: { [weak self] session, request in
                guard let self,
                      self.config.harness.notifyOnAwaiting,
                      let resolved = self.projectAndWorktree(withWorktreeId: worktree.id)
                else { return }
                self.harness.notifications.notifyACPQuestion(
                    agent: ACPHarnessBridge.agentKind(for: session.agentId),
                    body: self.acpInputNotificationBody(from: request),
                    projectId: resolved.project.id,
                    worktreeId: resolved.worktree.id,
                    sessionId: session.id,
                    requestId: self.notificationRequestId(for: request)
                )
            },
            onPlanAwaiting: { [weak self] session, request in
                guard let self,
                      self.config.harness.notifyOnAwaiting,
                      let resolved = self.projectAndWorktree(withWorktreeId: worktree.id)
                else { return }
                self.harness.notifications.notifyACPQuestion(
                    agent: ACPHarnessBridge.agentKind(for: session.agentId),
                    body: self.acpPlanNotificationBody(from: request),
                    projectId: resolved.project.id,
                    worktreeId: resolved.worktree.id,
                    sessionId: session.id,
                    requestId: self.notificationRequestId(for: request.id)
                )
            },
            onDelegatedMessageAvailable: { [weak self] sessionId in
                guard let self, let manager = self.acpManagers[owner] else { return }
                self.core.delegatedMessageAvailable(sessionId, in: manager)
            },
            onSuccessfulTurn: { [weak self] turn in
                self?.nextPromptCompleted(turn, owner: owner)
            },
            onQueueChanged: { [weak self] sessionId, retainActivePrompt in
                self?.restartRetainedACPSessionCleanupIfNeeded(
                    owner: owner,
                    sessionId: sessionId,
                    retainActivePrompt: retainActivePrompt
                )
            },
            onTurnCompleted: { [weak self] completion in
                Task { @MainActor [weak self] in
                    self?.computerUse.turnEnded(sessionID: completion.sessionId)
                    self?.scheduledAgentTurns.deliver(completion)
                    self?.reviewShepherd.turnCompleted(sessionID: completion.sessionId)
                    self?.stackShepherd.turnCompleted(sessionID: completion.sessionId)
                    await self?.acpOrchestration.childTurnCompleted(completion)
                }
            },
            onTurnUsage: { [weak self] completion in
                self?.recordTurnUsage(completion, owner: owner)
            },
            onChildBlocked: { [weak self] blocker in
                self?.notifyACPPermissionBlocked(blocker)
                Task { @MainActor [weak self] in
                    await self?.acpOrchestration.childBlocked(blocker)
                }
            },
            onCheckpointCapture: { [weak self] prompt, hasAttachments in
                guard let self, let target = self.checkpointTarget(for: worktree) else { return nil }
                do {
                    let checkpoint = try await self.automaticCheckpointService.createAutomatic(
                        target: target,
                        label: AutomaticCheckpointLabel.make(
                            prompt: prompt,
                            hasAttachments: hasAttachments
                        )
                    )
                    await self.rightPaneStore.activeState(worktreeId: worktree.id)?.refreshCheckpoints()
                    return checkpoint.id
                } catch {
                    return nil
                }
            },
            pluginContext: { [weak self] sessionID in
                await self?.pluginPromptContext(session: sessionID, worktree: worktree) ?? []
            },
            sessionReferenceContext: { [weak self] referencedSessionID in
                await self?.acpSessionReferenceContext(referencedSessionID, projectId: worktree.projectId)
            },
            launchSpecTransformer: { [weak self] spec, allowsPermissionBypass in
                guard let self else { return spec }
                let project = self.projects.first(where: { $0.id == worktree.projectId })
                return self.workspaceACPLaunchSpec(
                    from: spec,
                    remoteHome: nil,
                    treatsHomeAsRemote: project?.host != nil,
                    useBypassPermissions: allowsPermissionBypass
                        && (project.map { self.agentBypassPermissionsEnabled(for: $0) } ?? false)
                )
            },
            brokerServiceFactory: {
                let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
                return try await LocalACPBrokerServicePool.shared.service(resourceURL: resourceURL)
            },
            isolatedBrokerServiceFactory: {
                let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
                return try LocalACPBrokerService(resourceURL: resourceURL)
            },
            delegatedSelectionHoldResolver: { [weak self] sessionId in
                guard let self else { return nil }
                do {
                    return ACPSessionOrchestrationPolicy.selectionHoldDecision(
                        target: try await self.acpOrchestrationPersistence.delegation(childSessionId: sessionId)
                    )
                } catch {
                    return nil
                }
            },
            mcpProjectContextProvider: { [weak self] in
                guard let project = self?.projects.first(where: { $0.id == worktree.projectId }) else {
                    return nil
                }
                // Repo config participates on live local paths only; remote
                // projects keep today's behavior (no SSH round-trip here).
                let repo: RepoConfig? = {
                    guard project.host == nil else { return nil }
                    return self?.repoConfig(worktreeRoot: worktree.path)
                }()
                return MCPProjectContext(
                    projectDirectory: project.path,
                    configuredServers: project.mcpServers,
                    repoServers: repo?.mcpServers ?? [],
                    disabledRepoServerNames: Set(project.disabledRepoMCPServers),
                    repoTrust: project.repoMCPTrust
                )
            },
            builtInMCPProvider: { [weak self] context in
                guard let self else { return .omitted }
                let worktreePath = context.worktreePath
                let sessionId = context.sessionId
                guard case .local(let adapterSupportsHTTP) = context.location else {
                    // Remote projects keep app-level servers only (repo config
                    // is a local-only layer in v1).
                    return await self.remoteVisualMCPAttachment(
                        context: context,
                        configuredServers: self.projects.first { $0.id == worktree.projectId }?.mcpServers ?? []
                    )
                }
                // installExecutables is idempotent (byte-compares before
                // writing); a nil binaryPath (no bundle, e.g. tests) means
                // no injection rather than a dead command for the agent.
                let binaryPath = (try? TerminalCLIInjection.installExecutables())?
                    .appendingPathComponent(TerminalCLIInjection.executableName).path
                let parentSessionId = await self.delegatedParentSessionID(for: sessionId)
                if let parentSessionId {
                    self.core.rememberDelegatedSessionParent(childID: sessionId, parentID: parentSessionId)
                }
                let configuredServers: [ProjectMCPServer] = {
                    guard let project = self.projects.first(where: { $0.id == worktree.projectId }) else {
                        return []
                    }
                    // Remote projects keep today's behavior: app-level servers
                    // only (repo config is a local-only layer in v1).
                    guard project.host == nil,
                          let repo = self.repoConfig(
                              worktreeRoot: URL(fileURLWithPath: worktreePath)
                          ) else {
                        return project.mcpServers
                    }
                    // An approved repo-defined server named like a built-in
                    // ("alas", "git-gud") suppresses the built-in the same
                    // way an app-level server would.
                    return RepoMCPResolver.merge(
                        appServers: project.mcpServers,
                        repoServers: repo.mcpServers,
                        disabledNames: Set(project.disabledRepoMCPServers),
                        trust: project.repoMCPTrust
                    ).active
                }()
                if self.config.harness.alasMCPTransport == .http,
                   adapterSupportsHTTP,
                   let binaryPath, let socketPath = self.acpSessionSocketPath(sessionId: sessionId),
                   BuiltInAlasMCP.shouldInject(
                       enabled: self.config.harness.exposeAlasMCP,
                       configuredServers: configuredServers,
                       binaryPath: binaryPath,
                       socketPath: socketPath
                   ) {
                    if let endpoint = await self.mcpHTTPSupervisor.endpoint(
                        binaryPath: binaryPath,
                        socketPath: socketPath,
                        worktreePath: worktreePath,
                        sessionId: sessionId,
                        parentSessionId: parentSessionId
                    ) {
                        return .local(BuiltInAlasMCP.injection(
                            enabled: self.config.harness.exposeAlasMCP,
                            configuredServers: configuredServers,
                            binaryPath: binaryPath,
                            socketPath: socketPath,
                            worktreePath: worktreePath,
                            sessionId: sessionId,
                            parentSessionId: parentSessionId,
                            httpEndpoint: endpoint,
                            cliBuild: TerminalCLIInjection.buildIdentity(ofBinaryAt: TerminalCLIInjection.bundledBinaryURL())
                        ))
                    }
                    // Supervisor couldn't get a port — fall through to stdio
                    // (better than no tools).
                }
                // Reaching the non-HTTP path means this attach is not using an
                // HTTP server (stdio preference, adapter without HTTP MCP
                // support, disabled, or user-overridden). Tear down any HTTP
                // process a previous attach of this session spawned so it does
                // not linger bound on localhost. No-op when none is running.
                self.mcpHTTPSupervisor.end(sessionId: sessionId)
                return .local(BuiltInAlasMCP.injection(
                    enabled: self.config.harness.exposeAlasMCP,
                    configuredServers: configuredServers,
                    binaryPath: binaryPath,
                    socketPath: self.acpSessionSocketPath(sessionId: sessionId),
                    worktreePath: worktreePath,
                    sessionId: sessionId,
                    parentSessionId: parentSessionId,
                    cliBuild: TerminalCLIInjection.buildIdentity(ofBinaryAt: TerminalCLIInjection.bundledBinaryURL())
                ))
            },
            builtInMCPHello: { [weak self] sessionId in
                self?.mcpRegistrationRegistry.record(sessionId: sessionId)
            },
            clearMCPRegistration: { [weak self] sessionId in
                self?.mcpRegistrationRegistry.clear(sessionId: sessionId)
            },
            onSessionEnded: { [weak self] sessionId in
                self?.mcpHTTPSupervisor.end(sessionId: sessionId)
            },
            builtInMCPSessionState: builtInMCPSessionState,
            onChipsObserved: { [weak self] agentId, host, chips in
                self?.recordObservedChips(agentId: agentId, host: host, chips: chips)
            },
            ggMCPProvider: { [weak self] worktreePath in
                guard let self,
                      let integration = self.ggACPWorktreeIntegration(worktreePath: worktreePath),
                      Self.shouldAttachGGMCP(context: integration.context)
                else { return nil }
                // A local project's approved repo-defined server named
                // "git-gud" suppresses the auto-attached one, mirroring an
                // app-level same-name override.
                let configuredServers: [ProjectMCPServer] = {
                    guard integration.project.host == nil,
                          let repo = self.repoConfig(
                              worktreeRoot: URL(fileURLWithPath: worktreePath)
                          )
                    else {
                        return integration.project.mcpServers
                    }
                    return RepoMCPResolver.merge(
                        appServers: integration.project.mcpServers,
                        repoServers: repo.mcpServers,
                        disabledNames: Set(integration.project.disabledRepoMCPServers),
                        trust: integration.project.repoMCPTrust
                    ).active
                }()
                return GGMCPInjection.injection(
                    gatePassed: true,
                    binaryPath: GGAvailability.shared.ggMCPBinaryPath,
                    configuredServers: configuredServers,
                    worktreePath: worktreePath
                )
            },
            ggPreambleProvider: { [weak self] worktreePath in
                guard let self,
                      let integration = self.ggACPWorktreeIntegration(worktreePath: worktreePath)
                else { return .none }
                return Self.ggPreambleSignal(
                    context: integration.context,
                    snapshot: self.rightPaneStore.ggStackSnapshotForWorktreePath(
                        integration.worktree.path.path,
                        effectiveContext: integration.context,
                        liveBranch: self.rightPaneStore.currentBranchForWorktreePath(
                            integration.worktree.path.path
                        ) ?? integration.worktree.branch
                    )
                )
            },
            issuePreambleProvider: { [weak self] worktreeID in
                guard let self,
                      let attachment = self.projectsManager.issueAttachment(
                          projectId: worktree.projectId,
                          worktreeId: worktreeID
                      )
                else { return nil }
                return IssuePreambleContext(
                    title: attachment.title,
                    url: attachment.canonicalURL,
                    providerLabel: attachment.providerLabel,
                    displayReference: attachment.displayReference
                )
            }
        )
        mgr.remoteServerIdProvider = { [weak self] in
            guard let self else { return nil }
            if self.config.remote.ensureServerId() { self.saveConfig() }
            return self.config.remote.serverId
        }
        mgr.alasCLIEnvProvider = { [weak self] worktreePath, sessionId in
            guard let self else { return nil }
            let binDirPath = (try? TerminalCLIInjection.installExecutables())?.path
            let parentSessionId = await self.delegatedParentSessionID(for: sessionId)
            return AlasCLIEnvInjection.environment(
                enabled: self.config.harness.exposeAlasMCP,
                binDirPath: binDirPath,
                socketPath: self.acpSessionSocketPath(sessionId: sessionId),
                worktreePath: worktreePath,
                sessionId: sessionId,
                parentSessionId: parentSessionId,
                basePATH: ACPProcessEnvironment.augmented()["PATH"]
            )
        }
        mgr.nativeSubagentsPreferenceProvider = { [weak self] agentId in
            self?.config.agents.nativeSubagentsDisabled(for: agentId) ?? false
        }
        mgr.sessionInstructionsProvider = { [weak self] agentId in
            self?.config.agents.sessionInstructions(for: agentId)
        }
        mgr.sessionHooksProvider = { [weak self] agentId in
            self?.config.agents.sessionHooks(for: agentId)
        }
        mgr.delegatedChildProvider = { [weak self] sessionId in
            await self?.delegatedParentSessionID(for: sessionId) != nil
        }
        mgr.externalMCPStatusProvider = { [weak self] worktreePath in
            guard let self else { return (.unknown, nil, [], [], []) }
            let worktreeURL = URL(fileURLWithPath: worktreePath)
            let adapterState = PiMCPAdapterInspector.state(worktreeURL: worktreeURL)
            let project = self.projects.first(where: { $0.id == worktree.projectId })
            // The external adapter gets the same merged list the ACP attach
            // path plans: approved repo-defined servers join (local projects
            // only), and unknown/declined/disabled ones stay off. Remote
            // projects keep today's behavior.
            let repo: RepoConfig? = {
                guard project?.host == nil else { return nil }
                return self.repoConfig(worktreeRoot: worktreeURL)
            }()
            let plan = MCPAttachmentPlanner.plan(.init(
                configuredServers: project?.mcpServers ?? [],
                projectDirectory: project?.path ?? worktreePath,
                worktreeDirectory: worktreePath,
                environment: ACPProcessEnvironment.sanitizedForACP(extra: [:]),
                capabilities: ACPMCPServerCapabilities(http: true, sse: true),
                repoServers: repo?.mcpServers ?? [],
                disabledRepoServerNames: Set(project?.disabledRepoMCPServers ?? []),
                repoTrust: project?.repoMCPTrust ?? [:]
            ))
            let userServerNames = plan.wireServers.map(\.name)
            let skippedServerStatuses = plan.statuses.filter {
                if case .skipped = $0.disposition { return true }
                return false
            }
            let requestedServerStatuses = plan.statuses.filter {
                if case .requested = $0.disposition { return true }
                return false
            }
            guard adapterState == .installed else {
                return (adapterState, nil, userServerNames, skippedServerStatuses, requestedServerStatuses)
            }
            let fingerprint = MCPAttachmentPlanner.resolvedConfigurationFingerprint(for: plan.wireServers)
            let configOutcome: PiMCPConfigWriter.Outcome
            do {
                configOutcome = try PiMCPConfigWriter.sync(
                    worktreeURL: worktreeURL,
                    servers: plan.wireServers,
                    fingerprint: fingerprint
                )
            } catch {
                configOutcome = .failed
            }
            if Self.shouldExcludePiDirectory(after: configOutcome) {
                await self.excludePiDirectoryFromGit(worktreeURL: worktreeURL)
            }
            return (adapterState, configOutcome, userServerNames, skippedServerStatuses, requestedServerStatuses)
        }
        if isFolderWorktree(worktree) {
            mgr.upstreamReferences.environment = .noRemotes
        }
        let worktreeId = worktree.id
        mgr.admitsNewWork = { [weak self] in self?.projectsManager.admitsNewWork(worktreeId: worktreeId) ?? false }
        mgr.onSessionRuntimeEnded = { [weak self] sessionID in
            self?.computerUse.sessionEnded(sessionID: sessionID)
        }
        acpManagers[owner] = mgr
        acpManagerProjectIds[owner] = worktree.projectId
        observeNextPromptSessions(mgr, owner: owner)
        installSessionRecapHandler(on: mgr)
        acpHarnessBridge.attach(manager: mgr)
        Task {
            await previousManagerDisposal?.value
            await mgr.purgeOrphanedEphemeralSessions()
            if previousManagerDisposal != nil, self.acpManagers[owner] === mgr {
                await self.bootstrapScheduledACPSessions(owner: owner, manager: mgr)
            }
        }
        #if DEBUG
        memoryDiagnostics.attach(manager: mgr)
        #endif
        return mgr
    }

    enum WorkspaceACPManagerResolution {
        case ready(ACPSessionManager)
        /// Keep persisted tabs/history intact and wait for an explicit later
        /// resume rather than constructing a session against a guessed root.
        case pendingRootOrLocation
    }

    /// Returns a checkout-owned ACP manager without consulting Repository
    /// Focus. A missing root/location is intentionally non-destructive: UI
    /// restoration can retain the tab as pending until the checkout returns.
    func workspaceACPManager(for checkout: WorkspaceCheckout) async -> WorkspaceACPManagerResolution {
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        if let existing = acpManagers[owner] { return .ready(existing) }
        let pinnedRemoteHost: String?
        switch checkout.executionLocation.normalized {
        case .local:
            pinnedRemoteHost = nil
            guard FileManager.default.fileExists(atPath: checkout.rootPath) else {
                return .pendingRootOrLocation
            }
        case .ssh(let destination):
            pinnedRemoteHost = destination
            guard !destination.isEmpty else { return .pendingRootOrLocation }
            guard let result = try? await workspaceRemoteTransport.run(
                host: destination,
                cwd: checkout.rootPath,
                command: "pwd"
            ), result.exitCode == 0 else {
                return .pendingRootOrLocation
            }
        }
        guard await workspaceCheckoutManifestMatches(checkout) else { return .pendingRootOrLocation }
        if let existing = acpManagers[owner] { return .ready(existing) }

        let launchSpecRemoteHome: String?
        if let pinnedRemoteHost {
            let configuredAgents = AgentConfiguredCatalog.enabled(
                builtinState: config.agents.builtinState,
                customs: config.agents.userAgents
            )
            let needsRemoteHome = configuredAgents.contains {
                $0.binaryOverride?.trimmingCharacters(in: .whitespaces).hasPrefix("~/") == true
            }
            if let remoteHome = try? await WorktreeLifecycle.remoteHomeDirectory(host: pinnedRemoteHost),
               remoteHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                launchSpecRemoteHome = remoteHome
            } else if needsRemoteHome {
                return .pendingRootOrLocation
            } else {
                launchSpecRemoteHome = nil
            }
        } else {
            launchSpecRemoteHome = nil
        }
        if let existing = acpManagers[owner] { return .ready(existing) }

        let dbURL = Paths.acpSessionsDB(for: owner)
        let checkoutMemberWorktreeID: (String) -> String? = { [weak self] absolutePath in
            guard let self else { return nil }
            let target = Self.canonicalWorktreePath(absolutePath)
            let current = self.workspacesManager.checkout(id: checkout.id) ?? checkout
            for member in current.members where member.availability == .available {
                guard Self.canonicalWorktreePath(member.worktreePath) == target
                    || target.hasPrefix(Self.canonicalWorktreePath(member.worktreePath) + "/")
                else { continue }
                guard let worktree = self.projectsManager.worktrees(projectId: member.projectID).first(where: {
                    Self.canonicalWorktreePath($0.path.path)
                        == Self.canonicalWorktreePath(current.inAppWorktreePath(member.worktreePath))
                }) else { return nil }
                return worktree.id
            }
            return nil
        }
        let manager = ACPSessionManager(
            worktreeId: owner.storageKey,
            worktreePath: checkout.rootPath,
            owner: owner,
            persistence: ACPSessionPersistence(path: dbURL.path),
            instanceId: instanceId,
            pid: Int64(ProcessInfo.processInfo.processIdentifier),
            hydratorPath: dbURL.path,
            remoteHost: pinnedRemoteHost,
            usesRemoteHostRegistry: checkout.executionLocation.normalized != .local,
            onDirtyCheck: { [weak self] path in
                guard let worktreeID = checkoutMemberWorktreeID(path) else { return false }
                return self?.editorHasDirtyBuffer(for: path, worktreeId: worktreeID) ?? false
            },
            onLiveBufferRead: { [weak self] path in
                guard let worktreeID = checkoutMemberWorktreeID(path) else { return nil }
                return self?.editorLiveBufferText(for: path, worktreeId: worktreeID)
            },
            onSessionTitleUpdated: { [weak self] sessionId, title in
                _ = self?.tabs.renameACPSessionTabs(
                    worktreeId: owner.storageKey,
                    sessionId: sessionId,
                    title: title
                )
            },
            localTitlesEnabled: { [weak self] in
                self?.config.harness.acpLocalTitlesEnabled ?? false
            },
            autoResumeAfterUsageLimit: { [weak self] in
                self?.config.harness.acpAutoResumeAfterUsageLimit ?? true
            },
            continueInterruptedSessions: { [weak self] in
                self?.config.harness.acpContinueInterruptedSessions ?? false
            },
            qwenTitleFallback: makeQwenTitleFallback(),
            onInputAwaiting: { [weak self] session, request in
                guard let self,
                      self.config.harness.notifyOnAwaiting
                else { return }
                self.harness.notifications.notifyACPQuestion(
                    agent: ACPHarnessBridge.agentKind(for: session.agentId),
                    body: self.acpInputNotificationBody(from: request),
                    projectId: checkout.id.uuidString,
                    worktreeId: owner.storageKey,
                    sessionId: session.id,
                    requestId: self.notificationRequestId(for: request),
                    owner: owner
                )
            },
            onPlanAwaiting: { [weak self] session, request in
                guard let self,
                      self.config.harness.notifyOnAwaiting
                else { return }
                self.harness.notifications.notifyACPQuestion(
                    agent: ACPHarnessBridge.agentKind(for: session.agentId),
                    body: self.acpPlanNotificationBody(from: request),
                    projectId: checkout.id.uuidString,
                    worktreeId: owner.storageKey,
                    sessionId: session.id,
                    requestId: self.notificationRequestId(for: request.id),
                    owner: owner
                )
            },
            onSuccessfulTurn: { [weak self] turn in
                self?.nextPromptCompleted(turn, owner: owner)
            },
            onQueueChanged: { [weak self] sessionId, retainActivePrompt in
                self?.restartRetainedACPSessionCleanupIfNeeded(
                    owner: owner,
                    sessionId: sessionId,
                    retainActivePrompt: retainActivePrompt
                )
            },
            onTurnCompleted: { [weak self] completion in
                Task { @MainActor [weak self] in
                    self?.computerUse.turnEnded(sessionID: completion.sessionId)
                    await self?.acpOrchestration.childTurnCompleted(completion)
                }
            },
            onTurnUsage: { [weak self] completion in
                self?.recordTurnUsage(completion, owner: owner)
            },
            onChildBlocked: { [weak self] blocker in
                self?.notifyACPPermissionBlocked(blocker)
                Task { @MainActor [weak self] in
                    await self?.acpOrchestration.childBlocked(blocker)
                }
            },
            launchSpecTransformer: { [weak self] spec, allowsPermissionBypass in
                guard let self else { return spec }
                return self.workspaceACPLaunchSpec(
                    from: spec,
                    remoteHome: launchSpecRemoteHome,
                    treatsHomeAsRemote: pinnedRemoteHost != nil,
                    useBypassPermissions: allowsPermissionBypass
                        && checkout.configurationSnapshot?.shared.creationLaunchPreference.useBypassPermissions == true
                )
            },
            brokerServiceFactory: {
                let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
                return try await LocalACPBrokerServicePool.shared.service(resourceURL: resourceURL)
            },
            isolatedBrokerServiceFactory: {
                let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
                return try LocalACPBrokerService(resourceURL: resourceURL)
            },
            builtInMCPProvider: { [weak self] context in
                guard let self else { return .omitted }
                let worktreePath = context.worktreePath
                let sessionId = context.sessionId
                let current = self.currentWorkspaceCheckoutSnapshot(checkout)
                let configuredServers = self.workspaceFrozenMCPServers(for: current)
                guard case .local(let adapterSupportsHTTP) = context.location else {
                    return await self.remoteVisualMCPAttachment(
                        context: context, configuredServers: configuredServers, allowsPRTools: false)
                }
                guard let binaryPath = (try? TerminalCLIInjection.installExecutables())?
                    .appendingPathComponent(TerminalCLIInjection.executableName).path
                else { return .omitted }
                let workspaceContext = BuiltInAlasMCP.WorkspaceContext(
                    checkoutID: current.id,
                    rootPath: current.rootPath,
                    members: current.members.map { .init(id: $0.id, availability: $0.availability) }
                )
                if self.config.harness.alasMCPTransport == .http,
                   adapterSupportsHTTP,
                   let socketPath = self.acpSessionSocketPath(sessionId: sessionId),
                   BuiltInAlasMCP.shouldInject(
                       enabled: self.config.harness.exposeAlasMCP,
                       configuredServers: configuredServers,
                       binaryPath: binaryPath,
                       socketPath: socketPath
                   ),
                   let endpoint = await self.mcpHTTPSupervisor.endpoint(
                       binaryPath: binaryPath,
                       socketPath: socketPath,
                       worktreePath: worktreePath,
                       sessionId: sessionId,
                       parentSessionId: nil,
                       workspaceOnly: true
                   ) {
                    return .local(BuiltInAlasMCP.injection(
                        enabled: self.config.harness.exposeAlasMCP,
                        configuredServers: configuredServers,
                        binaryPath: binaryPath,
                        socketPath: socketPath,
                        worktreePath: worktreePath,
                        sessionId: sessionId,
                        httpEndpoint: endpoint,
                        workspaceContext: workspaceContext,
                        cliBuild: TerminalCLIInjection.buildIdentity(ofBinaryAt: TerminalCLIInjection.bundledBinaryURL())
                    ))
                }
                self.mcpHTTPSupervisor.end(sessionId: sessionId)
                return .local(BuiltInAlasMCP.injection(
                    enabled: self.config.harness.exposeAlasMCP,
                    configuredServers: configuredServers,
                    binaryPath: binaryPath,
                    socketPath: self.acpSessionSocketPath(sessionId: sessionId),
                    worktreePath: worktreePath,
                    sessionId: sessionId,
                    workspaceContext: workspaceContext,
                    cliBuild: TerminalCLIInjection.buildIdentity(ofBinaryAt: TerminalCLIInjection.bundledBinaryURL())
                ))
            },
            frozenMCPAttachmentProvider: { [weak self] in
                guard let self else { return nil }
                return self.workspaceFrozenMCPAttachments(for: self.currentWorkspaceCheckoutSnapshot(checkout))
            },
            builtInMCPHello: { [weak self] sessionId in
                self?.mcpRegistrationRegistry.record(sessionId: sessionId)
            },
            clearMCPRegistration: { [weak self] sessionId in
                self?.mcpRegistrationRegistry.clear(sessionId: sessionId)
            },
            builtInMCPSessionState: builtInMCPSessionState,
            onChipsObserved: { [weak self] agentId, host, chips in
                self?.recordObservedChips(agentId: agentId, host: host, chips: chips)
            }
        )
        manager.remoteServerIdProvider = { [weak self] in
            guard let self else { return nil }
            if self.config.remote.ensureServerId() { self.saveConfig() }
            return self.config.remote.serverId
        }
        // The router refuses computer calls from checkout owners.
        manager.computerUseAvailable = false
        manager.alasCLIEnvProvider = { [weak self] worktreePath, sessionId -> [String: String]? in
            guard let self else { return nil }
            let binDirPath = (try? TerminalCLIInjection.installExecutables())?.path
            return AlasCLIEnvInjection.environment(
                enabled: self.config.harness.exposeAlasMCP,
                binDirPath: binDirPath,
                socketPath: self.acpSessionSocketPath(sessionId: sessionId),
                worktreePath: worktreePath,
                sessionId: sessionId,
                parentSessionId: nil,
                basePATH: ACPProcessEnvironment.augmented()["PATH"]
            )
        }
        manager.nativeSubagentsPreferenceProvider = { [weak self] agentId in
            self?.config.agents.nativeSubagentsDisabled(for: agentId) ?? false
        }
        manager.sessionInstructionsProvider = { [weak self] agentId in
            self?.config.agents.sessionInstructions(for: agentId)
        }
        manager.sessionHooksProvider = { [weak self] agentId in
            self?.config.agents.sessionHooks(for: agentId)
        }
        manager.externalMCPStatusProvider = { [weak self] worktreePath -> (
            adapterState: PiMCPAdapterInspector.State,
            configOutcome: PiMCPConfigWriter.Outcome?,
            userServerNames: [String],
            skippedServerStatuses: [MCPAttachmentServerStatus],
            requestedServerStatuses: [MCPAttachmentServerStatus]
        ) in
            guard let self else { return (.unknown, nil, [], [], []) }
            let current = self.currentWorkspaceCheckoutSnapshot(checkout)
            let attachments = self.workspaceFrozenMCPAttachments(for: current)
            let descriptors = attachments?.descriptors ?? []
            let plan = MCPAttachmentPlanner.plan(.init(
                configuredServers: [],
                projectDirectory: current.rootPath,
                worktreeDirectory: worktreePath,
                environment: ACPProcessEnvironment.sanitizedForACP(extra: [:]),
                capabilities: ACPMCPServerCapabilities(http: true, sse: true),
                frozenServerDescriptors: descriptors,
                unavailableFrozenDescriptorIDs: attachments?.unavailableDescriptorIDs ?? []
            ))
            let userServerNames = plan.wireServers.map(\.name)
            let skippedServerStatuses = plan.statuses.filter {
                if case .skipped = $0.disposition { return true }
                return false
            }
            let requestedServerStatuses = plan.statuses.filter {
                if case .requested = $0.disposition { return true }
                return false
            }
            let worktreeURL = URL(fileURLWithPath: worktreePath)
            let adapterState = PiMCPAdapterInspector.state(worktreeURL: worktreeURL)
            guard adapterState == .installed else {
                return (adapterState, nil, userServerNames, skippedServerStatuses, requestedServerStatuses)
            }
            let fingerprint = MCPAttachmentPlanner.resolvedConfigurationFingerprint(for: plan.wireServers)
            let configOutcome: PiMCPConfigWriter.Outcome
            do {
                configOutcome = try PiMCPConfigWriter.sync(
                    worktreeURL: worktreeURL,
                    servers: plan.wireServers,
                    fingerprint: fingerprint
                )
            } catch {
                configOutcome = .failed
            }
            if Self.shouldExcludePiDirectory(after: configOutcome) {
                await self.excludePiDirectoryFromGit(worktreeURL: worktreeURL)
            }
            return (adapterState, configOutcome, userServerNames, skippedServerStatuses, requestedServerStatuses)
        }
        manager.onSessionRuntimeEnded = { [weak self] sessionID in
            self?.computerUse.sessionEnded(sessionID: sessionID)
        }
        acpManagers[owner] = manager
        observeNextPromptSessions(manager, owner: owner)
        installSessionRecapHandler(on: manager)
        acpHarnessBridge.attach(manager: manager)
        Task { await manager.purgeOrphanedEphemeralSessions() }
        #if DEBUG
        memoryDiagnostics.attach(manager: manager)
        #endif
        return .ready(manager)
    }

    func workspaceACPLaunchSpec(
        from spec: ACPLaunchSpec,
        configuredAgents: [AgentDefinition]? = nil,
        remoteHome: String? = nil,
        treatsHomeAsRemote: Bool = false,
        useBypassPermissions: Bool
    ) -> ACPLaunchSpec {
        let agents = configuredAgents ?? AgentConfiguredCatalog.enabled(
            builtinState: config.agents.builtinState,
            customs: config.agents.userAgents
        )
        let configuredAgent = agents.first(where: { $0.id == spec.agentID })
        var launchSpec = spec
        if ACPManagedAdapterDescriptor.descriptor(for: spec.agentID) == nil,
           let binaryOverride = configuredAgent?.binaryOverride?.trimmingCharacters(in: .whitespaces),
           !binaryOverride.isEmpty,
           let command = ACPBinaryOverride.normalized(
            binaryOverride,
            remoteHome: remoteHome,
            treatsHomeAsRemote: treatsHomeAsRemote
           ),
           command != spec.command {
            launchSpec = launchSpec.overridingCommandAndSetupCheck(command)
        }
        if spec.agentID == "copilot",
           let extra = configuredAgent?.extraTerminalArgs, !extra.isEmpty {
            // Copilot 1.0.85 removed the `model`/`reasoning_effort` runtime
            // config options (github/copilot-cli#4880) — the only way left to
            // pick them is at spawn time. Reuses the existing per-agent
            // "extra args" field (already wired into the terminal-harness
            // launch path) instead of adding Copilot-specific persisted state.
            launchSpec = launchSpec.prependingArguments(extra)
        }
        if useBypassPermissions,
           let flag = configuredAgent?.bypassPermissionsFlag,
           launchSpec.arguments.contains(flag) == false {
            launchSpec = launchSpec.prependingArguments([flag])
        }
        return launchSpec
    }

    /// Adds `.pi/` to this worktree's `.git/info/exclude` after a managed
    /// `.pi/mcp.json` is written or confirmed unchanged, so the generated file
    /// never shows up as untracked/dirty in the changes list. `GitIgnoreService.appendIgnore`
    /// is idempotent (skips if the pattern already exists), so retrying this
    /// for managed configs is safe. Linked worktrees keep `info/exclude`
    /// outside the working tree, so the path is resolved via
    /// `git rev-parse --git-path` — same approach as
    /// `RightPaneState.ignore(path:isDirectory:destination:)`. Best-effort:
    /// failures are silently ignored (worst case `.pi/` shows as untracked).
    private func excludePiDirectoryFromGit(worktreeURL: URL) async {
        guard !isFolderPath(worktreeURL) else { return }
        do {
            let infoExcludeURL = try await resolveGitInfoExcludeURL(worktreeURL: worktreeURL)
            _ = try GitIgnoreService.appendIgnore(
                entryPath: Self.piMCPGeneratedConfigExcludePath,
                isDirectory: false,
                destination: .infoExclude,
                repoURL: worktreeURL,
                infoExcludeURL: infoExcludeURL
            )
        } catch {
            // Non-fatal: the managed mcp.json still works, it just may show
            // as untracked until the next successful attach retries this.
        }
    }

    static func shouldExcludePiDirectory(after outcome: PiMCPConfigWriter.Outcome) -> Bool {
        outcome == .wrote || outcome == .unchanged
    }

    private func resolveGitInfoExcludeURL(worktreeURL: URL) async throws -> URL {
        let result = try await Process.git(["rev-parse", "--git-path", "info/exclude"], cwd: worktreeURL)
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") {
            // A remote git prints a host path; keep it off a same-path local twin.
            return URL(fileURLWithPath: RemotePath.virtualizing(raw, like: worktreeURL.path))
        }
        return URL(fileURLWithPath: raw, relativeTo: worktreeURL).standardizedFileURL
    }

    /// Runs `pi install npm:pi-mcp-adapter` (pi resolves its own package
    /// management). Returns true when pi exits 0.
    func installPiMCPAdapter() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["pi", "install", "npm:pi-mcp-adapter"]
                process.environment = ACPProcessEnvironment.augmented()
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Release the ACP session manager for the given worktree id.
    /// Called from `cleanupWorktreeState` when a worktree is
    /// removed/archived. Stops every attached runner (which cancels
    /// its async tasks and shuts down the child agent process) before
    /// the manager is dropped — otherwise the runner's `for await`
    /// loops would keep the agent + permission / file handlers alive
    /// after the UI was torn down.
    func disposeACPManager(for worktreeId: String) {
        disposeACPManager(owner: .worktree(worktreeId))
    }

    @discardableResult
    private func disposeACPManager(owner: SessionOwnerID) -> Task<Void, Never>? {
        guard let manager = acpManagers.removeValue(forKey: owner) else { return nil }
        acpManagerProjectIds.removeValue(forKey: owner)
        prepareACPManagerForDisposal(manager, owner: owner)
        return Task { @MainActor in
            await self.finishDisposingACPManager(manager)
        }
    }

    private func disposeACPManagerAndWait(owner: SessionOwnerID) async {
        guard let manager = acpManagers.removeValue(forKey: owner) else { return }
        acpManagerProjectIds.removeValue(forKey: owner)
        prepareACPManagerForDisposal(manager, owner: owner)
        await finishDisposingACPManager(manager)
    }

    private func prepareACPManagerForDisposal(_ manager: ACPSessionManager, owner: SessionOwnerID) {
        cancelRetainedACPSessionCleanups(owner: owner)
        // Flush any pending debounced draft writes before tearing the
        // manager down — otherwise the last ~300ms of typing in any
        // composer for this worktree never reaches SQLite.
        manager.flushPendingDraftWrites()
        #if DEBUG
        memoryDiagnostics.detach(worktreeId: owner.storageKey)
        #endif
        acpHarnessBridge.detach(worktreeId: owner.storageKey)
        let sessionIds = Array(manager.runners.keys)
        // Synchronously cancel the runner's async loops so they stop
        // pumping the agent's stdout into our handlers immediately —
        // otherwise the loops hold `self` weakly but keep the
        // permission / file / update streams flowing until the
        // detach() task below schedules. The actual child-process
        // shutdown then happens asynchronously.
        for sid in sessionIds {
            manager.runners[sid]?.stop()
            scheduledAgentTurns.sessionClosed(sid)
        }
        // Mirrors have no runner, so stop their pollers and subscriptions now.
        // Writer leases must remain fresh while sequential teardown is pending.
        manager.prepareForDisposal()
        localTextObservers.managers[owner] = nil
    }

    private func finishDisposingACPManager(_ manager: ACPSessionManager) async {
        await AlasCoreContext.finishDisposing(manager)
    }

    /// Open a new ACP session tab for the given agent in the currently-selected worktree.
    func openNewACPSession(agentID: String, initialPrompt: String? = nil) {
        guard let worktreeId = selectedWorktreeId,
              let worktree = worktree(withId: worktreeId) else { return }
        guard let mgr = acpManager(for: worktree) else { return }
        openNewACPSession(
            agentID: agentID,
            owner: mgr.owner,
            projectId: worktree.projectId,
            initialPrompt: initialPrompt
        )
    }

    /// `projectId` is the project whose claim gates this creation. Callers that
    /// hold a worktree pass it: a worktree owner carries only the path-derived
    /// id, and re-resolving the project from that id here would read another
    /// project's same-path checkout instead — admitting the session while this
    /// project's checkout is being deleted, or blocking it while another
    /// project's is.
    @discardableResult
    func openNewACPSession(
        agentID: String,
        owner: SessionOwnerID,
        projectId: String? = nil,
        initialPrompt: String? = nil
    ) -> ACPSessionTabState? {
        if case .worktree(let worktreeID) = owner {
            let claimProjectId = projectId
                ?? projectAndWorktree(withWorktreeId: worktreeID)?.project.id
                ?? ""
            guard !Self.blocksWorktreeSessionAdmission(
                projectsManager.operationState(
                    forWorktreeId: worktreeID,
                    projectId: claimProjectId
                )
            ) else {
                return nil
            }
        }
        guard let mgr = acpManager(for: owner) else { return nil }
        let session = mgr.createSession(agentId: agentID, autoRunDefault: config.harness.acpAutoRunByDefault)
        if let initialPrompt, !initialPrompt.isEmpty {
            mgr.persistComposerDraft(
                ACPComposerDraft(segments: [.text(initialPrompt)]),
                for: session
            )
        }
        let state = ACPSessionTabState(sessionId: session.id, title: session.title)
        tabs.append(acpSession: state, to: owner)
        return state
    }

    /// Opens a checkout-owned shared ACP tab. This is intentionally separate
    /// from the selected-worktree entry point so Repository Focus cannot
    /// retarget the session or its persisted database.
    @discardableResult
    func openWorkspaceCheckoutACPSession(
        checkout: WorkspaceCheckout,
        agentID: String
    ) async -> ACPSessionTabState? {
        guard let checkout = await authoritativeCheckoutForWorkspaceACPSessionCreation(checkout) else { return nil }
        guard await !checkpointACPAdmissionDisabledAfterDiscovery(owner: .workspaceCheckout(checkout.id, checkout.executionLocation), fallbackWorktree: nil) else { return nil }
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        guard case let .ready(manager) = await workspaceACPManager(for: checkout) else { return nil }
        guard await authoritativeCheckoutForWorkspaceACPSessionCreation(checkout) != nil else {
            await disposeACPManagerAndWait(owner: owner)
            return nil
        }
        let session = manager.createSession(agentId: agentID, autoRunDefault: config.harness.acpAutoRunByDefault)
        let state = ACPSessionTabState(sessionId: session.id, title: session.title)
        tabs.append(acpSession: state, to: owner)
        return state
    }

    func authoritativeCheckoutForWorkspaceACPSessionCreation(_ checkout: WorkspaceCheckout) async -> WorkspaceCheckout? {
        guard workspacesManager.canMutate else { return nil }
        guard let authoritative = await workspaceStore.checkout(id: checkout.id) else { return nil }
        guard authoritative.executionLocation.normalized == checkout.executionLocation.normalized else { return nil }
        guard authoritative.archivedAt == nil, authoritative.operation == .idle else { return nil }
        guard await workspaceCheckoutManifestMatches(authoritative) else { return nil }
        return authoritative
    }

    /// Restores saved checkout-owned ACP tabs without creating a replacement
    /// session. If the checkout root or location is unavailable, the tabs stay
    /// persisted and visibly pending for a later explicit restore.
    @discardableResult
    func restoreWorkspaceCheckoutACPSessions(_ checkout: WorkspaceCheckout) async -> Bool {
        guard let checkout = await authoritativeCheckoutForWorkspaceACPSessionCreation(checkout) else { return false }
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        guard await !checkpointACPAdmissionDisabledAfterDiscovery(owner: owner, fallbackWorktree: nil) else { return false }
        tabs.load(owner: owner, restoringActiveTabs: true)
        guard case let .ready(manager) = await workspaceACPManager(for: checkout) else { return false }
        guard await authoritativeCheckoutForWorkspaceACPSessionCreation(checkout) != nil else {
            await disposeACPManagerAndWait(owner: owner)
            return false
        }
        for tab in tabs.tabs(for: owner) {
            guard case let .acpSession(state) = tab else { continue }
            guard manager.placeholderSession(id: state.sessionId) != nil else { continue }
            await manager.hydrateIfNeeded(id: state.sessionId)
        }
        await bootstrapScheduledACPSessions(owner: owner, manager: manager)
        return true
    }

    func startACPSession(
        worktree: Worktree,
        sessionID: ACPSession.ID,
        agentID: String,
        promptID: UUID,
        prompt: String?,
        promptCard: ACPPromptCard? = nil
    ) async throws -> ACPSession.ID {
        try await host.sessions.start(
            sessionID, agentID: agentID, in: worktree, promptID: promptID, prompt: prompt, promptCard: promptCard, caller: .app
        )
    }

    private func openPreparedWorktreeACPSession(
        worktree: Worktree,
        agentID: String,
        preparedPrompt: PreparedWorktreeACPPrompt
    ) async {
        await host.sessions.startPrepared(preparedPrompt, agentID: agentID, in: worktree, caller: .app) { session in
            let tab = tabs.append(acpSession: ACPSessionTabState(sessionId: session.id, title: session.title), to: worktree.id)
            if worktree.id == selectedWorktreeId {
                activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
            } else {
                // A background launch (scheduled run, plugin task) only picks the tab its worktree shows
                // when opened; the center-tab path would also clear what the user is looking at now.
                tabs.activate(worktreeId: worktree.id, tabId: tab.id)
            }
        }
    }

    func forkACPSession(
        worktree: Worktree,
        sourceSessionID: ACPSession.ID,
        boundary: ACPForkMessageBoundary,
        targetAgentID: String
    ) {
        guard let manager = acpManager(for: worktree) else { return }
        Task { @MainActor in
            do {
                guard await !self.checkpointACPAdmissionDisabledAfterDiscovery(worktreeId: worktree.id) else {
                    manager.liveSession(for: sourceSessionID)?.lastError = Self.checkpointRecoveryBlocksACPMessage
                    return
                }
                let target = try await manager.createFork(
                    sourceSessionID: sourceSessionID,
                    boundary: boundary,
                    targetAgentID: targetAgentID,
                    autoRunDefault: config.harness.acpAutoRunByDefault
                )
                guard !Self.blocksWorktreeSessionAdmission(
                    self.projectsManager.operationState(for: worktree)
                ) else { return }
                let tabState = ACPSessionTabState(sessionId: target.id, title: target.title)
                let tab = tabs.append(acpSession: tabState, to: worktree.id)
                activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
                await manager.attach(
                    to: target.id,
                    freshlyCreated: true
                )
            } catch {
                manager.liveSession(for: sourceSessionID)?.lastError =
                    "Could not create fork: \(error.localizedDescription)"
            }
        }
    }

    func forkACPSession(
        owner: SessionOwnerID,
        sourceSessionID: ACPSession.ID,
        boundary: ACPForkMessageBoundary,
        targetAgentID: String
    ) {
        guard let manager = acpManager(for: owner) else { return }
        Task { @MainActor in
            do {
                guard await !self.checkpointACPAdmissionDisabledAfterDiscovery(owner: owner, fallbackWorktree: nil) else {
                    manager.liveSession(for: sourceSessionID)?.lastError = Self.checkpointRecoveryBlocksACPMessage
                    return
                }
                let target = try await manager.createFork(
                    sourceSessionID: sourceSessionID,
                    boundary: boundary,
                    targetAgentID: targetAgentID,
                    autoRunDefault: config.harness.acpAutoRunByDefault
                )
                let tabState = ACPSessionTabState(sessionId: target.id, title: target.title)
                let tab = tabs.append(acpSession: tabState, to: owner)
                tabs.activate(owner: owner, tabId: tab.id)
                if let selectedWorktreeId {
                    tabs.clearActiveTab(worktreeId: selectedWorktreeId)
                }
                await manager.attach(
                    to: target.id,
                    freshlyCreated: true
                )
            } catch {
                manager.liveSession(for: sourceSessionID)?.lastError =
                    "Could not create fork: \(error.localizedDescription)"
            }
        }
    }

    func mergeACPForkBack(
        worktree: Worktree,
        owner: SessionOwnerID?,
        forkSessionID: ACPSession.ID,
        archive: Bool
    ) async throws {
        let resolvedManager: ACPSessionManager?
        if let owner { resolvedManager = acpManager(for: owner) }
        else { resolvedManager = acpManager(for: worktree) }
        guard let manager = resolvedManager else {
            throw ACPSessionForkMergeError.forkUnavailable
        }
        guard await !checkpointACPAdmissionDisabledAfterDiscovery(owner: owner, fallbackWorktree: worktree) else {
            throw ACPWorktreeSessionBootstrapError(message: Self.checkpointRecoveryBlocksACPMessage)
        }
        let sourceID = try await manager.mergeForkBack(id: forkSessionID, archive: archive)
        if archive {
            let forkTabs = owner.map { tabs.tabs(for: $0) } ?? tabs.tabs(forWorktree: worktree.id)
            for tab in forkTabs {
                guard case .acpSession(let tabState) = tab, tabState.sessionId == forkSessionID else { continue }
                if let owner { closeSharedSessionTab(owner: owner, tabID: tab.id) }
                else { closeTab(worktreeId: worktree.id, tabId: tab.id) }
            }
        }
        if let owner { await openExistingACPSession(sessionId: sourceID, owner: owner) }
        else { await openExistingACPSession(sessionId: sourceID, worktree: worktree) }
        if let source = manager.liveSession(for: sourceID), source.agentState != .ready, source.agentState != .spawning {
            await manager.attach(to: sourceID, freshlyCreated: false)
        }
    }

    /// Keeps a `/btw` side question as a regular forked session and opens it
    /// in a new tab next to its parent.
    func keepACPSideQuestion(worktree: Worktree, owner: SessionOwnerID?, parentID: ACPSession.ID) {
        guard let manager = owner.flatMap({ acpManager(for: $0) }) ?? acpManager(for: worktree) else { return }
        Task { @MainActor in
            do {
                guard let side = try await manager.promoteSideQuestion(parentID: parentID) else { return }
                let tabState = ACPSessionTabState(sessionId: side.id, title: side.title)
                if let owner {
                    let tab = tabs.append(acpSession: tabState, to: owner)
                    tabs.activate(owner: owner, tabId: tab.id)
                    if let selectedWorktreeId {
                        tabs.clearActiveTab(worktreeId: selectedWorktreeId)
                    }
                } else {
                    let tab = tabs.append(acpSession: tabState, to: worktree.id)
                    activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
                }
            } catch {
                manager.liveSession(for: parentID)?.lastError =
                    "Could not keep side question: \(error.localizedDescription)"
            }
        }
    }

    /// Route a prepared handoff into the active ACP tab when its composer is
    /// safely empty; otherwise preserve the current draft and open a new tab.
    func openACPHandoff(agentID: String, initialPrompt: String) {
        guard !initialPrompt.isEmpty else {
            openNewACPSession(agentID: agentID, initialPrompt: nil)
            return
        }
        guard let worktreeId = selectedWorktreeId,
              let worktree = worktree(withId: worktreeId),
              let manager = acpManager(for: worktree)
        else { return }

        if case .acpSession(let tabState) = tabs.activeTab(forWorktree: worktree.id),
           let session = manager.placeholderSession(id: tabState.sessionId),
           session.agentId == agentID,
           !manager.isMirror(sessionId: tabState.sessionId),
           session.hydrationState == .ready,
           session.transcript.messages.isEmpty,
           session.queue.isEmpty,
           session.composerDraft.isEmpty {
            manager.persistComposerDraft(
                ACPComposerDraft(segments: [.text(initialPrompt)]),
                for: session
            )
            activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tabState.id)
            return
        }

        openNewACPSession(agentID: agentID, initialPrompt: initialPrompt)
    }

    func openReviewLoopHandoff(from reviewLoop: ReviewLoopState, actionKind: ReviewReadinessActionKind) {
        guard let snapshot = reviewLoop.snapshot else { return }
        guard actionKind == .openAgentHandoff else { return }
        guard let worktreeId = selectedWorktreeId,
              let worktree = worktree(withId: worktreeId),
              let agent = availableAgentForHandoff(id: config.changes.aiToolId, worktree: worktree)
        else { return }
        let prompt = ReviewLoopHandoffBuilder.build(
            snapshot: snapshot,
            action: ReviewLoopAction(
                kind: Self.reviewLoopHandoffActionKind(for: snapshot.reviewRequest),
                title: "Open in Agent",
                detail: "Prepare a focused agent handoff."
            )
        )
        openACPHandoff(agentID: agent.id, initialPrompt: prompt)
    }

    func openReviewEvidenceHandoff(snapshot: ReviewLoopSnapshot, detail: ReviewEvidenceDetail) {
        guard let worktreeId = selectedWorktreeId,
              let worktree = worktree(withId: worktreeId),
              let agent = availableAgentForHandoff(id: config.changes.aiToolId, worktree: worktree)
        else { return }
        let prompt = ReviewLoopHandoffBuilder.buildSelectedEvidencePrompt(
            snapshot: snapshot,
            detail: detail
        )
        openACPHandoff(agentID: agent.id, initialPrompt: prompt)
    }

    @discardableResult
    func openReviewChangesTab(for worktree: Worktree) -> Tab {
        tabs.openOrFocusReviewChanges(worktreeId: worktree.id)
    }

    nonisolated static func reviewLoopHandoffActionKind(for request: ReviewRequest?) -> ReviewLoopActionKind {
        if request?.hasActionableFeedback == true {
            return .prepareReviewHandoff
        }
        if request?.worstCheckBucket == .fail {
            return .prepareCheckFailureHandoff
        }
        return .prepareCheckFailureHandoff
    }

    /// Reopen a persisted ACP session as a center-pane tab. If a tab
    /// for this session is already open in the current worktree we
    /// just focus it; otherwise we create one and let openSession()
    /// rehydrate the transcript from disk.
    func openExistingACPSession(sessionId: ACPSession.ID) async {
        guard let worktreeId = selectedWorktreeId,
              let worktree = worktree(withId: worktreeId) else { return }
        await openExistingACPSession(sessionId: sessionId, worktree: worktree)
    }

    /// Pins the owner before suspension, including when sidebar focus reopens history.
    /// `activate: false` (peer requests) neither focuses an existing tab nor
    /// activates a new one, so the host's visible tab never changes.
    /// `storedTitle` is a title the caller just read from SQLite, preferred
    /// over the manager's possibly stale cached row.
    func openExistingACPSession(
        sessionId: ACPSession.ID, worktree: Worktree, activate: Bool = true, storedTitle: String? = nil
    ) async {
        await awaitPendingACPDetach(owner: .worktree(worktree.id), sessionId: sessionId)
        guard let mgr = acpManager(for: worktree) else { return }
        cancelRetainedACPSessionCleanup(owner: .worktree(worktree.id), sessionId: sessionId)
        guard await !checkpointACPAdmissionDisabledAfterDiscovery(worktreeId: worktree.id) else { return }

        // Focus the tab if it's already there.
        let tabIdToFocus: TabID? = tabs.tabs(forWorktree: worktree.id).compactMap { tab -> TabID? in
            if case .acpSession(let s) = tab, s.sessionId == sessionId { return tab.id }
            return nil
        }.first
        if let id = tabIdToFocus {
            if activate { activateWorktreeCenterTab(worktreeId: worktree.id, tabId: id) }
            return
        }

        // Resolve an uncached row before creating the tab so hydration cannot
        // leave a generic title behind indefinitely.
        let title: String
        if let liveTitle = mgr.liveSession(for: sessionId)?.title {
            title = liveTitle
        } else if let storedTitle {
            title = storedTitle
        } else if let row = await mgr.persistedSessionRow(id: sessionId) {
            title = row.title
        } else {
            title = "ACP session"
        }
        _ = mgr.placeholderSession(id: sessionId)
        await mgr.hydrateIfNeeded(id: sessionId)
        await deliverPendingDelegatedMessages(to: sessionId, manager: mgr)
        guard !Self.blocksWorktreeSessionAdmission(
            projectsManager.operationState(for: worktree)
        ) else { return }
        // Another open may have added the tab, or the worktree may have been
        // removed or its manager torn down (Close All), while this one was suspended.
        guard self.worktree(withId: worktree.id) != nil,
              acpManagers[.worktree(worktree.id)] === mgr,
              sessionTabIndex(sessionId, owner: .worktree(worktree.id)) == nil else { return }
        let state = ACPSessionTabState(sessionId: sessionId, title: title)
        tabs.append(acpSession: state, to: worktree.id, activate: activate)
    }

    /// Reopen a persisted ACP session inside a typed session-owner bucket.
    /// Checkout-owned sessions must not fall back to Repository Focus because
    /// their database, tabs, and lifecycle are tied to the checkout owner.
    /// `activate: false` (peer requests) neither focuses an existing tab nor
    /// activates a new one.
    func openExistingACPSession(sessionId: ACPSession.ID, owner: SessionOwnerID, activate: Bool = true) async {
        await awaitPendingACPDetach(owner: owner, sessionId: sessionId)
        guard let mgr = acpManager(for: owner) else { return }
        cancelRetainedACPSessionCleanup(owner: owner, sessionId: sessionId)
        guard await !checkpointACPAdmissionDisabledAfterDiscovery(owner: owner, fallbackWorktree: nil) else { return }

        let tabIdToFocus: TabID? = tabs.tabs(for: owner).compactMap { tab -> TabID? in
            if case .acpSession(let state) = tab, state.sessionId == sessionId { return tab.id }
            return nil
        }.first
        if let id = tabIdToFocus {
            guard activate else { return }
            tabs.activate(owner: owner, tabId: id)
            if let selectedWorktreeId {
                tabs.clearActiveTab(worktreeId: selectedWorktreeId)
            }
            return
        }

        let title: String
        if let liveTitle = mgr.liveSession(for: sessionId)?.title {
            title = liveTitle
        } else if let row = await mgr.persistedSessionRow(id: sessionId) {
            title = row.title
        } else {
            title = "ACP session"
        }
        _ = mgr.placeholderSession(id: sessionId)
        await mgr.hydrateIfNeeded(id: sessionId)
        await deliverPendingDelegatedMessages(to: sessionId, manager: mgr)
        let state = ACPSessionTabState(sessionId: sessionId, title: title)
        let tab = tabs.append(acpSession: state, to: owner, activate: activate)
        guard activate else { return }
        tabs.activate(owner: owner, tabId: tab.id)
        if let selectedWorktreeId {
            tabs.clearActiveTab(worktreeId: selectedWorktreeId)
        }
    }

    private func deliverPendingDelegatedMessages(to sessionId: String, manager: ACPSessionManager) async {
        await core.deliverPendingDelegatedMessages(to: sessionId, manager: manager)
    }

    func delegatedSessionSummaries(for sessionId: String) async -> [ACPOrchestrationSessionSummary] {
        let parent = try? await acpOrchestrationPersistence.parent(childSessionId: sessionId)
        let children = (try? await acpOrchestrationPersistence.children(parentSessionId: sessionId)) ?? []
        var summaries: [ACPOrchestrationSessionSummary] = []
        for record in children {
            let manager = record.childWorktreeId
                .flatMap { worktree(withId: $0) }
                .flatMap { acpManager(for: $0) }
            let runtime = manager?.liveSession(for: record.childSessionId)
                .map { session -> ACPOrchestrationRuntimeState in
                    switch session.transcript.streamingState {
                    case .idle: return .idle
                    case .sending, .streaming: return .running
                    case .awaitingPermission, .awaitingInput: return .awaitingInput
                    }
                }
            let archived: Bool
            if let manager, let row = await manager.persistedSessionRow(id: record.childSessionId) {
                archived = row.archived
            } else if record.childWorktreeId != nil {
                archived = true
            } else {
                archived = false
            }
            summaries.append(ACPOrchestrationSessionSummary(
                sessionId: record.childSessionId,
                relationship: "child",
                agentId: record.agentId,
                worktreeId: record.childWorktreeId ?? "",
                state: ACPSessionOrchestrationPolicy.publicState(
                    phase: record.phase,
                    runtime: runtime,
                    archived: archived
                ).rawValue,
                failure: record.failureMessage,
                createdAt: record.createdAt,
                role: record.role
            ))
        }
        if let parent {
            summaries.append(.init(
                sessionId: parent.parentSessionId,
                relationship: "parent",
                agentId: "",
                worktreeId: parent.parentWorktreeId,
                state: "idle",
                failure: nil,
                createdAt: parent.createdAt
            ))
        }
        return ACPDelegatedSessionsPolicy.ordered(summaries)
    }

    func openDelegatedACPSession(_ summary: ACPOrchestrationSessionSummary) async {
        guard let worktree = worktree(withId: summary.worktreeId) else { return }
        focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        await openExistingACPSession(sessionId: summary.sessionId)
    }

    /// Maps the cwd of a session the agent lists to the worktree of
    /// `worktree`'s project whose path it is, with that worktree's session
    /// store. A session store is opened only when its file exists, so
    /// browsing never creates one.
    func acpSessionBrowserResolver(for worktree: Worktree) -> @MainActor (String) -> ACPSessionBrowserTarget? {
        let context = worktree.path.path
        func key(_ path: String) -> String { ACPSessionBrowserPaths.key(path, context: context) }
        var byPath: [String: String] = [:]
        for candidate in projectsManager.worktrees(projectId: worktree.projectId) where byPath[key(candidate.path.path)] == nil {
            byPath[key(candidate.path.path)] = candidate.id
        }
        var stores: [String: ACPSessionPersistence?] = [:]
        return { [weak self] cwd in
            guard let id = byPath[key(cwd)] else { return nil }
            if let cached = stores[id] { return .init(worktreeId: id, persistence: cached) }
            let store: ACPSessionPersistence?
            if let manager = self?.acpManagers[.worktree(id)] {
                store = manager.persistence
            } else {
                let url = Paths.acpSessionsDB(forWorktreeId: id)
                store = FileManager.default.fileExists(atPath: url.path) ? ACPSessionPersistence(path: url.path) : nil
            }
            stores[id] = store
            return .init(worktreeId: id, persistence: store)
        }
    }

    /// Shows an agent-side rename on the Alas copy of the session, and
    /// returns a closure that puts back its previous title and title source
    /// (a failed agent rename must not leave a provider title marked manual).
    func renameLocalACPSession(
        worktreeId: String,
        sessionId: ACPSession.ID,
        title: String
    ) async throws -> (@MainActor () async throws -> String)? {
        guard let worktree = worktree(withId: worktreeId), let manager = acpManager(for: worktree) else { return nil }
        // Read so a failure stops here: without the old title there would be
        // no way back if the agent rename then fails.
        let previous = try await manager.persistence.loadSession(id: sessionId)
        try await Self.storeACPSessionTitle(title, source: .manual, sessionId: sessionId, manager: manager)
        guard let previous else { return nil }
        // Returns the title stored afterwards. Only while the stored title
        // is still this rename's, in one conditional update: a newer rename
        // from elsewhere is not undone.
        return {
            let restored = try await manager.persistence.renameSession(
                id: sessionId, title: previous.title, titleSource: previous.titleSource,
                updatedAt: Int64(Date().timeIntervalSince1970), ifStillTitled: title, source: .manual
            )
            guard restored else {
                return try await manager.persistence.loadSession(id: sessionId)?.title ?? title
            }
            if manager.renameSessionCosmetic(id: sessionId, title: previous.title, source: previous.titleSource) {
                await manager.flushAllPersistence()
            }
            return previous.title
        }
    }

    /// Stored before returning: the session browser reads it for the next
    /// row.
    private static func storeACPSessionTitle(
        _ title: String,
        source: ACPSessionTitleSource,
        sessionId: ACPSession.ID,
        manager: ACPSessionManager
    ) async throws {
        // Written and awaited first, so a store error stops the agent rename;
        // then the manager's cached row and live session follow. An archived
        // Alas row is not updated, which counts as a failure too.
        guard try await manager.persistence.renameSession(
            id: sessionId, title: title, titleSource: source, updatedAt: Int64(Date().timeIntervalSince1970)
        ) else { throw ACPSessionTitleNotStored() }
        if manager.renameSessionCosmetic(id: sessionId, title: title, source: source) {
            await manager.flushAllPersistence()
        }
    }

    struct ACPSessionTitleNotStored: LocalizedError {
        var errorDescription: String? { "The Alas copy of this session could not be renamed." }
    }

    @discardableResult
    func openDiscoveredACPSession(
        _ discovered: ACPDiscoveredSession,
        capabilities: ACPSessionDiscoveryCapabilities
    ) async -> Bool {
        guard let worktreeId = discovered.worktreeId,
              let resolved = projectAndWorktree(withWorktreeId: worktreeId),
              let manager = acpManager(for: resolved.worktree)
        else { return false }

        focusGlobalWorktree(id: resolved.worktree.id, projectId: resolved.project.id)
        // Open in the session's own worktree, whatever the selection says by now.
        if let localSessionId = discovered.localSessionId {
            await openExistingACPSession(sessionId: localSessionId, worktree: resolved.worktree)
            return true
        }
        guard capabilities.canOpenRemoteSession,
              let row = await manager.materializeDiscoveredSession(
                discovered,
                autoRunDefault: config.harness.acpAutoRunByDefault
              )
        else { return false }

        await openExistingACPSession(sessionId: row.id, worktree: resolved.worktree)
        return true
    }

    @discardableResult
    func openDiscoveredACPSession(
        _ discovered: ACPDiscoveredSession,
        owner: SessionOwnerID,
        capabilities: ACPSessionDiscoveryCapabilities
    ) async -> Bool {
        // A session of a linked worktree opens in that worktree, never in
        // the directory the browser was opened from.
        if let target = discovered.worktreeId, owner.worktreeID != nil, target != owner.worktreeID {
            return await openDiscoveredACPSession(discovered, capabilities: capabilities)
        }
        guard let manager = acpManager(for: owner) else { return false }

        if let localSessionId = discovered.localSessionId {
            await openExistingACPSession(sessionId: localSessionId, owner: owner)
            return true
        }
        guard capabilities.canOpenRemoteSession,
              let row = await manager.materializeDiscoveredSession(
                  discovered,
                  autoRunDefault: config.harness.acpAutoRunByDefault
              )
        else { return false }

        await openExistingACPSession(sessionId: row.id, owner: owner)
        return true
    }

    /// Open a diff tab for the given worktree-relative path and comparison mode.
    /// Reuses an existing matching diff tab for the same path if one is already open.
    func openDiffTab(
        forFileInWorktree worktree: Worktree,
        relativePath: String,
        staged: Bool = false,
        originalPath: String? = nil,
        compareWithHEAD: Bool = false
    ) {
        let worktreeId = worktree.id
        let existing = tabs.tabs(forWorktree: worktreeId).first { tab in
            if case .diff(let s) = tab {
                return s.relativePath == relativePath
                    && s.staged == staged
                    && s.originalPath == originalPath
                    && s.compareWithHEAD == compareWithHEAD
            }
            return false
        }
        if let existing {
            activateWorktreeCenterTab(worktreeId: worktreeId, tabId: existing.id)
        } else {
            let basename = (relativePath as NSString).lastPathComponent
            let title: String
            if compareWithHEAD {
                title = "\(basename) vs HEAD"
            } else if staged {
                title = "\(basename) (staged)"
            } else {
                title = basename
            }
            let tab = tabs.appendDiff(
                worktreeId: worktreeId,
                title: title,
                relativePath: relativePath,
                staged: staged,
                originalPath: originalPath,
                compareWithHEAD: compareWithHEAD
            )
            activateWorktreeCenterTab(worktreeId: worktreeId, tabId: tab.id)
        }
    }

    func openStashDiffTab(worktree: Worktree, stash: GitStash, file: GitStashFile) {
        let worktreeId = worktree.id
        let existing = tabs.tabs(forWorktree: worktreeId).first { tab in
            if case .stashDiff(let state) = tab {
                return state.stash.ref == stash.ref
                    && state.stash.sha == stash.sha
                    && state.file.path == file.path
                    && state.file.isUntracked == file.isUntracked
            }
            return false
        }
        if let existing {
            activateWorktreeCenterTab(worktreeId: worktreeId, tabId: existing.id)
            return
        }
        let tab = tabs.appendStashDiff(worktreeId: worktreeId, stash: stash, file: file)
        activateWorktreeCenterTab(worktreeId: worktreeId, tabId: tab.id)
    }

    func openCheckpointDiffTab(
        worktree: Worktree,
        checkpointID: CheckpointID,
        groupID: UUID,
        primaryPath: String,
        memberPaths: [String]? = nil,
        checkpointLabel: String
    ) {
        let worktreeID = worktree.id
        let existing = tabs.tabs(forWorktree: worktreeID).first { tab in
            if case .checkpointDiff(let state) = tab {
                return state.worktreeID == worktreeID
                    && state.checkpointID == checkpointID
                    && state.groupID == groupID
            }
            return false
        }
        if let existing {
            activateWorktreeCenterTab(worktreeId: worktreeID, tabId: existing.id)
            return
        }
        let tab = tabs.appendCheckpointDiff(
            worktreeID: worktreeID,
            checkpointID: checkpointID,
            groupID: groupID,
            primaryPath: primaryPath,
            memberPaths: memberPaths,
            checkpointLabel: checkpointLabel
        )
        activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
    }

    func openCommitTab(worktreeId: String, commit: CommitInfo) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        if selectedWorktreeId != worktree.id {
            focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        }

        let existing = tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .commit(let state) = tab { return state.fixedSHA == commit.sha }
            return false
        }
        if let existing {
            activateWorktreeCenterTab(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let title = "\(commit.shortSha) \(commit.conventionalTag.map { "\($0): \(commit.subject)" } ?? commit.subject)"
            let tab = tabs.appendCommit(worktreeId: worktree.id, sha: commit.sha, title: title)
            activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
        }
    }

    func openFileSnapshotAtHEAD(relativePath: String, worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
        if selectedWorktreeId != worktree.id {
            focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        }
        let tab = tabs.openOrFocusFileSnapshot(worktreeId: worktree.id, relativePath: relativePath, ref: "HEAD")
        activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
    }

    func openFileHistory(relativePath: String, worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
        if selectedWorktreeId != worktree.id {
            focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        }
        let tab = tabs.openOrFocusFileHistory(worktreeId: worktree.id, relativePath: relativePath)
        activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
    }

    /// Project-scoped gg inbox capability. This intentionally does not use a
    /// hosting worktree's effective context because the inbox spans the repo.
    func ggInboxAvailable(projectId: String) -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        guard config.changes.stackedDiffsEnabled, GGAvailability.shared.isInstalled, project.host == nil else { return false }
        return Self.resolveGGInboxAvailable(
            masterEnabled: config.changes.stackedDiffsEnabled,
            ggInstalled: GGAvailability.shared.isInstalled,
            isRemoteProject: project.host != nil,
            projectMode: project.ggMode,
            repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path),
            worktreeOverrides: Array(project.ggWorktreeModes.values)
        )
    }

    /// Rendering uses the last background snapshot; actions still validate live state.
    func ggSidebarInboxAvailable(projectId: String) -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        return Self.resolveGGInboxAvailable(
            masterEnabled: config.changes.stackedDiffsEnabled,
            ggInstalled: GGAvailability.shared.isInstalled,
            isRemoteProject: project.host != nil || project.isFolder,
            projectMode: project.ggMode,
            repoHasGGConfig: ggSidebarSnapshots[project.path]?.hasConfig ?? false,
            worktreeOverrides: Array(project.ggWorktreeModes.values)
        )
    }

    nonisolated static func resolveGGInboxAvailable(
        masterEnabled: Bool,
        ggInstalled: Bool,
        isRemoteProject: Bool,
        projectMode: GGProjectMode,
        repoHasGGConfig: Bool,
        worktreeOverrides: [GGWorktreeMode]
    ) -> Bool {
        guard masterEnabled, ggInstalled, !isRemoteProject else { return false }
        return repoHasGGConfig
            || projectMode == .on
            || worktreeOverrides.contains(.on)
    }

    func ggWorktreeContext(
        project: ProjectConfig,
        worktree: Worktree,
        branch: String,
        ggInstalled: Bool = GGAvailability.shared.isInstalled
    ) -> GGWorktreeContext {
        guard config.changes.stackedDiffsEnabled else { return .inactive(reason: .masterDisabled) }
        guard ggInstalled else { return .inactive(reason: .cliMissing) }
        // Folders have no git, so gg is unavailable exactly as for remote projects.
        guard project.host == nil, !project.isFolder else { return .inactive(reason: .remoteProject) }
        return Self.resolveGGWorktreeContext(
            masterEnabled: config.changes.stackedDiffsEnabled,
            ggInstalled: ggInstalled,
            project: project,
            worktreeOverride: effectiveGGWorktreeMode(projectId: project.id, worktreeId: worktree.id),
            isMainWorktree: projectsManager.isMain(worktree, in: project),
            repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path),
            branchUsername: GGConfigReader.branchUsername(repoPath: project.path),
            branch: branch
        )
    }

    func ggWorktreeMenuModel(
        project: ProjectConfig,
        worktree: Worktree
    ) -> GGWorktreeMenuModel {
        let selectedMode = effectiveGGWorktreeMode(projectId: project.id, worktreeId: worktree.id)
        let snapshot = ggSidebarSnapshots[project.path] ?? .init()
        return GGWorktreeMenuModel(
            selectedMode: selectedMode,
            context: Self.resolveGGWorktreeContext(
                masterEnabled: config.changes.stackedDiffsEnabled,
                ggInstalled: GGAvailability.shared.isInstalled,
                project: project,
                worktreeOverride: selectedMode,
                isMainWorktree: projectsManager.isMain(worktree, in: project),
                repoHasGGConfig: snapshot.hasConfig,
                branchUsername: snapshot.branchUsername,
                branch: worktree.branch
            ),
            hasStackSummary: GGStackSummaryStore.shared.summary(forPath: worktree.path.path) != nil,
            isRemoteWorktree: project.host != nil || worktree.path.isRemoteAlasPath
        )
    }

    func setGGWorktreeMode(
        projectId: String,
        worktreeId: String,
        mode: GGWorktreeMode
    ) {
        projectsManager.setGGWorktreeMode(
            projectId: projectId,
            worktreeId: worktreeId,
            mode: mode
        )
        saveProjects()
        rightPaneStore.reevaluateGGGate(worktreeId: worktreeId)
        refreshGGSidebar()
    }

    private func discardUnpersistedGGWorktreeMode(
        projectId: String,
        worktreeId: String,
        mode: GGWorktreeMode
    ) {
        guard mode != .inherit else { return }
        removeUnpersistedGGWorktreeMode(projectId: projectId, worktreeId: worktreeId)
        rightPaneStore.reevaluateGGGate(worktreeId: worktreeId)
    }

    private func setUnpersistedGGWorktreeMode(
        projectId: String,
        worktreeId: String,
        mode: GGWorktreeMode
    ) {
        guard mode != .inherit else { return }
        var modes = unpersistedGGWorktreeModes[projectId] ?? [:]
        modes[worktreeId] = mode
        unpersistedGGWorktreeModes[projectId] = modes
    }

    private func removeUnpersistedGGWorktreeMode(projectId: String, worktreeId: String) {
        guard var modes = unpersistedGGWorktreeModes[projectId] else { return }
        modes.removeValue(forKey: worktreeId)
        if modes.isEmpty {
            unpersistedGGWorktreeModes.removeValue(forKey: projectId)
        } else {
            unpersistedGGWorktreeModes[projectId] = modes
        }
    }

    private func effectiveGGWorktreeMode(projectId: String, worktreeId: String) -> GGWorktreeMode {
        unpersistedGGWorktreeModes[projectId]?[worktreeId]
            ?? projectsManager.ggWorktreeMode(projectId: projectId, worktreeId: worktreeId)
    }

    func removePersistedGGWorktreeMode(projectId: String, worktreeId: String) {
        guard projectsManager.ggWorktreeMode(
            projectId: projectId,
            worktreeId: worktreeId
        ) != .inherit else { return }
        projectsManager.removeGGWorktreeMode(projectId: projectId, worktreeId: worktreeId)
        saveProjects()
    }

    nonisolated static func resolveGGWorktreeContext(
        masterEnabled: Bool,
        ggInstalled: Bool,
        project: ProjectConfig,
        worktreeOverride: GGWorktreeMode,
        isMainWorktree: Bool,
        repoHasGGConfig: Bool,
        branchUsername: String?,
        branch: String
    ) -> GGWorktreeContext {
        GGWorktreeContextResolver.resolve(
            masterEnabled: masterEnabled,
            ggInstalled: ggInstalled,
            isRemoteProject: project.host != nil || project.isFolder,
            projectMode: project.ggMode,
            worktreeOverride: worktreeOverride,
            isMainWorktree: isMainWorktree,
            repoHasGGConfig: repoHasGGConfig,
            branchUsername: branchUsername,
            branch: branch
        )
    }

    nonisolated static func shouldAttachGGMCP(context: GGWorktreeContext) -> Bool {
        context.isActive
    }

    nonisolated static func ggPreambleSignal(
        context: GGWorktreeContext,
        snapshot: RightPaneGGStackSnapshot?
    ) -> GGPreambleSignal {
        guard context.isActive else { return .none }
        guard let snapshot,
              snapshot.loadState == .loaded,
              let stack = snapshot.stack
        else { return .generic }
        return .stack(name: stack.name, entryCount: stack.totalCommits)
    }

    func ggACPWorktreeIntegration(
        worktreePath: String,
        ggInstalled: Bool = GGAvailability.shared.isInstalled
    ) -> (project: ProjectConfig, worktree: Worktree, context: GGWorktreeContext)? {
        let requestedPath = Self.canonicalWorktreePath(worktreePath)
        for project in projects {
            guard let worktree = projectsManager.worktrees(projectId: project.id).first(where: {
                Self.canonicalWorktreePath($0.path.path) == requestedPath
            }) else { continue }
            let branch = rightPaneStore.currentBranchForWorktreePath(worktree.path.path)
                ?? worktree.branch
            let branchContext = ggWorktreeContext(
                project: project,
                worktree: worktree,
                branch: branch,
                ggInstalled: ggInstalled
            )
            return (
                project,
                worktree,
                rightPaneStore.effectiveGGContextForWorktreePath(
                    worktree.path.path,
                    branchContext: branchContext,
                    liveBranch: branch
                )
            )
        }
        return nil
    }

    nonisolated private static func canonicalWorktreePath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    /// Chooses which of the target project's worktrees hosts its inbox tab:
    /// the currently-selected worktree when it belongs to the project,
    /// otherwise the project's first worktree. Nil when the project has none.
    nonisolated static func inboxHostWorktreeId(
        selectedWorktreeId: String?,
        projectWorktreeIds: [String]
    ) -> String? {
        if let selectedWorktreeId, projectWorktreeIds.contains(selectedWorktreeId) {
            return selectedWorktreeId
        }
        return projectWorktreeIds.first
    }

    nonisolated static func landingHostWorktreeId(
        sessionWorktreeId: String,
        selectedWorktreeId: String?,
        projectWorktreeIds: [String]
    ) -> String? {
        if projectWorktreeIds.contains(sessionWorktreeId) {
            return sessionWorktreeId
        }
        return inboxHostWorktreeId(
            selectedWorktreeId: selectedWorktreeId,
            projectWorktreeIds: projectWorktreeIds
        )
    }

    /// Opens (or focuses) the gg inbox tab for `projectId` in the currently
    /// selected worktree's tab strip, falling back to the project's first
    /// worktree when the current selection belongs to a different project.
    func openGGInbox(projectId: String) {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        let projectWorktreeIds = projectsManager.visibleWorktrees(projectId: projectId).map(\.id)
        guard let worktreeId = Self.inboxHostWorktreeId(
            selectedWorktreeId: selectedWorktreeId,
            projectWorktreeIds: projectWorktreeIds
        ) else { return }
        tabs.openOrFocusGGInbox(worktreeId: worktreeId, projectId: projectId, projectName: project.name)
        selectWorktree(id: worktreeId)
    }

    func openGGLanding(projectId: String) {
        migrateGGLanding(projectId: projectId, selectHost: true)
    }

    private func migrateGGLanding(projectId: String, selectHost: Bool) {
        guard let session = GGLandingStore.shared.sessions[projectId] else { return }
        let projectWorktreeIds = projectsManager.visibleWorktrees(projectId: projectId).map(\.id)
        guard let worktreeId = Self.landingHostWorktreeId(
            sessionWorktreeId: session.worktreeId,
            selectedWorktreeId: selectedWorktreeId,
            projectWorktreeIds: projectWorktreeIds
        ) else {
            GGLandingStore.shared.cancel(projectId: projectId)
            return
        }
        tabs.openOrFocusGGLanding(
            worktreeId: worktreeId, projectId: projectId, stackName: session.stack
        )
        if selectHost {
            selectWorktree(id: worktreeId)
        }
    }

    func cancelGGLanding(projectId: String) {
        GGLandingStore.shared.cancel(projectId: projectId)
    }

    func restartGGLanding(projectId: String) {
        guard let session = GGLandingStore.shared.sessions[projectId] else { return }
        let projectWorktreeIds = projectsManager.visibleWorktrees(projectId: projectId).map(\.id)
        guard let worktreeId = Self.landingHostWorktreeId(
            sessionWorktreeId: session.worktreeId,
            selectedWorktreeId: selectedWorktreeId,
            projectWorktreeIds: projectWorktreeIds
        ),
            let state = rightPaneStore.activeState(worktreeId: worktreeId)
        else { return }
        state.restartGGLand(target: session.target)
    }
}

/// Per-item outcome of a bulk worktree operation. The batch never aborts, so
/// each selected worktree always produces exactly one of these.
enum WorktreeBatchOutcome: Equatable, Sendable {
    case deleted
    case archived
    case failed(message: String)
    /// Git refused without `--force`. Batches never force implicitly; the user
    /// handles these individually through the existing single-item flow.
    case needsForce
    case skipped(reason: String)
}

struct WorktreeBatchResult: Identifiable, Equatable, Sendable {
    let worktreeId: String
    let branch: String
    let outcome: WorktreeBatchOutcome

    var id: String { worktreeId }
}

private extension WorkspaceCheckoutMember {
    var canUseSnapshotOnlyCheckoutDeletion: Bool {
        cleanup == nil
            && cleanupOwnership.worktreeCreated == false
            && (cleanupOwnership.branchOwnership != .created || plan != nil)
    }
}

// MARK: - RemoteSessionPresenter

/// What the Remote session list shows of a session owner beyond host events.
private struct RemoteSessionListInputs: Equatable {
    /// Each session tab by its position among all the owner's tabs, which is
    /// the `tabIndex` the list reports.
    var sessionTabs: [Int: ACPSession.ID]
    var status: WorktreeDirtyState
    var diff: WorktreeDiffStats?
}

/// Remote tab requests open and close tabs in this window, as the tab bar does.
extension AppState: RemoteSessionPresenter {
    var sessionListChanges: ChangeSignal<Void>? {
        if let remoteSessionListChanges { return remoteSessionListChanges }
        let signal = ChangeSignal<Void>()
        remoteSessionListChanges = signal
        followRemoteSessionListInputs()
        return signal
    }

    func sessionTabIndex(_ id: String, owner: SessionOwnerID) -> Int? {
        tabs.tabs(for: owner).firstIndex { tab in
            if case .acpSession(let state) = tab { return state.sessionId == id }
            return false
        }
    }

    /// Per owner with sessions: where its session tabs are, and its Git status.
    private func currentRemoteSessionListInputs() -> [SessionOwnerID: RemoteSessionListInputs] {
        let statuses = WorktreeStatusStore.shared
        return Dictionary(uniqueKeysWithValues: acpManagers.map { owner, manager in
            (owner, RemoteSessionListInputs(
                sessionTabs: tabs.tabs(for: owner).enumerated().reduce(into: [:]) { tabs, entry in
                    if case .acpSession(let state) = entry.element { tabs[entry.offset] = state.sessionId }
                },
                status: statuses.status(forPath: manager.worktreePath),
                diff: statuses.diffStats(forPath: manager.worktreePath)
            ))
        })
    }

    private func followRemoteSessionListInputs() {
        let inputs = withObservationTracking { currentRemoteSessionListInputs() } onChange: {
            Task { @MainActor [weak self] in self?.followRemoteSessionListInputs() }
        }
        // Editor tabs and other worktrees change what is tracked too.
        if inputs != remoteSessionListInputs {
            remoteSessionListInputs = inputs
            remoteSessionListChanges?.send()
        }
    }
}

extension AppState {
    private func recordObservedChips(agentId: String, host: String?, chips: ACPChipState) {
        acpModelCatalog.record(
            agentID: agentId,
            models: (chips.models?.options ?? []).map { ACPAgentModelCatalog.Model(id: $0.id, name: $0.name) },
            host: host
        )
        acpModelCatalog.recordEffort(agentID: agentId, thinking: chips.thinking)
    }

    func session(for id: String) -> ACPSession? {
        for mgr in acpManagers.values {
            if let s = mgr.liveSession(for: id) { return s }
        }
        return nil
    }

    /// A live ACP session that belongs to `owner` and that this process
    /// drives. Appending a transcript row needs no visible tab, so delegated
    /// children without one qualify.
    func isAuthorizedACPSessionWriter(sessionID: String, owner: SessionOwnerID) -> Bool {
        guard let session = session(for: sessionID) else { return false }
        return session.owner == owner && isWriter(for: sessionID)
    }

    /// The ACP half of CLI caller authorization: the session belongs to
    /// `owner`, this process drives it, and the owner still shows its ACP tab.
    func isAuthorizedACPWriter(sessionID: String, owner: SessionOwnerID) -> Bool {
        guard isAuthorizedACPSessionWriter(sessionID: sessionID, owner: owner) else { return false }
        return tabs.tabs(for: owner).contains {
            guard case .acpSession(let tab) = $0 else { return false }
            return tab.sessionId == sessionID
        }
    }

    func acpManager(forSession id: String) -> ACPSessionManager? {
        acpManagers.values.first { $0.liveSession(for: id) != nil }
    }

    func answerQuestion(
        for id: String,
        requestId: JSONRPCID,
        _ response: ACPQuestionResponse
    ) {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            mgr.answerQuestion(for: id, requestId: requestId, response)
            return
        }
    }

    func respondToPlan(
        for id: String,
        requestId: JSONRPCID,
        _ response: ACPCursorPlanResponse
    ) {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            mgr.respondToPlan(for: id, requestId: requestId, response)
            return
        }
    }

    func isWriter(for id: String) -> Bool {
        for mgr in acpManagers.values where mgr.isWriter(for: id) { return true }
        return false
    }

    func openSessionTab(for id: String) async -> RemoteSessionTabActionResult {
        await serializedSessionTabAction(for: id) { await self.openSessionTabNow(for: id) }
    }

    func closeSessionTab(for id: String) async -> RemoteSessionTabActionResult {
        await serializedSessionTabAction(for: id) { self.closeSessionTabNow(for: id) }
    }

    /// Runs remote tab actions for one session one at a time across every
    /// connection, so two opens cannot both append a tab and a close cannot
    /// report success while an earlier open is still about to add one.
    private func serializedSessionTabAction(
        for id: String,
        _ action: @escaping @MainActor () async -> RemoteSessionTabActionResult
    ) async -> RemoteSessionTabActionResult {
        let previous = remoteSessionTabActionTails[id]?.done
        let token = UUID()
        let run = Task { @MainActor in
            await previous?.value
            return await action()
        }
        remoteSessionTabActionTails[id] = (token, Task { _ = await run.value })
        let result = await run.value
        if remoteSessionTabActionTails[id]?.token == token { remoteSessionTabActionTails[id] = nil }
        return result
    }

    private func openSessionTabNow(for id: String) async -> RemoteSessionTabActionResult {
        let owner: SessionOwnerID
        switch remoteSessionTabOwner(for: id) {
        case .found(let found): owner = found
        case .failed(let message): return .failure(message)
        }
        // Already open is success, and must not focus the tab on the host.
        if sessionTabIndex(id, owner: owner) != nil { return .success }
        guard let manager = acpManager(for: owner) else {
            return .failure("Could not open this session.")
        }
        // `sessionRows` can predate an archive or delete made by another Alas
        // process, so only a fresh, unarchived stored row may be opened.
        // Queued writes (e.g. a new session's upsert) must land before the read.
        await manager.flushPersistence()
        let stored: ACPSessionRow?
        do {
            stored = try await manager.persistence.loadSession(id: id)
        } catch {
            return .failure("Could not read this session.")
        }
        guard let stored else { return .failure("This session is no longer available.") }
        if stored.archived { return .failure("This session is archived.") }
        // A peer's request must not switch the tab the host user is looking at.
        if let worktreeId = owner.worktreeID {
            guard let worktree = worktree(withId: worktreeId) else {
                return .failure("This session's worktree is no longer available.")
            }
            await openExistingACPSession(sessionId: id, worktree: worktree, activate: false, storedTitle: stored.title)
        } else {
            await openExistingACPSession(sessionId: id, owner: owner, activate: false)
        }
        guard sessionTabIndex(id, owner: owner) != nil else {
            return .failure("Could not open this session.")
        }
        // Opening hydrated the transcript, but a tab its owner is not showing
        // has no view to retain it. Balance that here so an idle session is
        // evicted; the tab re-hydrates when it is shown.
        manager.retainSession(id: id)
        manager.releaseSession(id: id)
        return .success
    }

    private func closeSessionTabNow(for id: String) -> RemoteSessionTabActionResult {
        let owner: SessionOwnerID
        switch remoteSessionTabOwner(for: id) {
        case .found(let found): owner = found
        case .failed(let message): return .failure(message)
        }
        let open = tabs.tabs(for: owner).first { tab in
            if case .acpSession(let state) = tab { return state.sessionId == id }
            return false
        }
        guard let open else { return .success }
        // No confirmation here: the requesting Mac already asked its user.
        if let worktreeId = owner.worktreeID {
            closeTabRecordingHistory(worktreeId: worktreeId, projectId: worktree(withId: worktreeId)?.projectId, tab: open)
        } else {
            closeSharedSessionTab(owner: owner, tabID: open.id)
        }
        return .success
    }

    private enum RemoteSessionTabOwner {
        case found(SessionOwnerID)
        case failed(String)
    }

    /// The owner whose manager has `id` as a live or unarchived recent session.
    private func remoteSessionTabOwner(for id: String) -> RemoteSessionTabOwner {
        for (owner, mgr) in acpManagers {
            let row = mgr.sessionRows.first { $0.id == id }
            guard row != nil || mgr.liveSession(for: id) != nil else { continue }
            if row?.archived == true { return .failed("This session is archived.") }
            if let worktreeId = owner.worktreeID, worktree(withId: worktreeId) == nil {
                return .failed("This session's worktree is no longer available.")
            }
            return .found(owner)
        }
        return .failed("This session is no longer available.")
    }

    func sendPrompt(
        for id: String, text: String, attachments: [ACPMessage.Attachment],
        delegatedSource: ACPDelegatedPromptSource? = nil, normalUserTurn: Bool,
        onAccepted: (@MainActor () -> Void)? = nil,
        onResult: @escaping @MainActor (Bool) -> Void
    ) async {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            await mgr.sendPrompt(for: id, text: text, attachments: attachments,
                                 delegatedSource: delegatedSource, normalUserTurn: normalUserTurn,
                                 onAccepted: onAccepted, onResult: onResult)
            return
        }
        onResult(false)
    }

    func sendPrompt(
        for id: String,
        worktreeID: String,
        text: String,
        attachments: [ACPMessage.Attachment],
        onResult: @escaping @MainActor (Bool) -> Void
    ) async {
        guard let manager = acpManager(forWorktreeId: worktreeID),
              manager.liveSession(for: id) != nil else {
            onResult(false)
            return
        }
        await manager.sendPrompt(for: id, text: text, attachments: attachments, onResult: onResult)
    }

    func stop(for id: String, worktreeID: String) async {
        guard let manager = acpManager(forWorktreeId: worktreeID) else { return }
        await manager.interrupt(for: id)
    }

    func sessionCreated(_ id: String, worktreeID: String) {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              let session = acpManagers.values.lazy.compactMap({ $0.liveSession(for: id) }).first
        else { return }
        focusGlobalWorktree(id: resolved.worktree.id, projectId: resolved.project.id)
        let tab = tabs.append(acpSession: ACPSessionTabState(sessionId: id, title: session.title), to: resolved.worktree.id)
        activateWorktreeCenterTab(worktreeId: resolved.worktree.id, tabId: tab.id)
    }

    func sessionRenamed(_ id: String, title: String) {
        for mgr in acpManagers.values
        where mgr.liveSession(for: id) != nil || mgr.sessionRows.contains(where: { $0.id == id }) {
            tabs.renameACPSessionTabs(worktreeId: mgr.worktreeId, sessionId: id, title: title)
            return
        }
    }
}

/// The app's side of the core's worktree and Workspace lifecycles: it kills
/// terminals and closes tabs before a worktree goes, asks about repository
/// hooks, and refreshes what the app shows. Not final, so tests can wrap a
/// step.
@MainActor
class AppHostEnvironment: AlasHostEnvironment {
    weak var app: AppState? {
        didSet { appRunLauncher.app = app }
    }
    let appRunLauncher = AppRunLauncher()
    var runLauncher: any RunLauncher { appRunLauncher }
    var modelCatalog: ACPAgentModelCatalog? { app?.acpModelCatalog }

    func configuration() -> AppConfig { app?.config ?? AppConfig.defaults }

    func enabledAgents() -> [AgentDefinition] { app?.agentRegistry.enabled() ?? [] }

    var fileIndex: FileIndex { app?.fileIndex ?? FileIndex() }

    func agent(id: String) -> AgentDefinition? { app?.agent(id: id) }

    func terminalSessionOwner(_ sessionID: String) -> SessionOwnerID? { app?.terminalSessionOwner(sessionID) }

    func workspaceCheckout(id: UUID) -> WorkspaceCheckout? { app?.workspacesManager.checkout(id: id) }

    var workspaceRemoteTransport: WorkspaceRemoteTransport { app?.workspaceRemoteTransport ?? WorkspaceRemoteTransport() }

    var instanceID: String { app?.instanceId ?? "" }

    func agentAvailability(in worktree: Worktree, core: AlasCoreContext) async -> AgentAvailabilityState {
        await app?.loadAgentAvailabilityForDelegation(worktree) ?? .available([])
    }

    func createDelegatedWorktree(
        projectID: String, branch: String, base: String?,
        recordDestination: @MainActor (URL) async throws -> Void, in core: AlasCoreContext
    ) async -> Result<Worktree, ACPSessionOrchestrationCoordinator.WorktreeCreationError> {
        guard let app else { return .failure(.init(message: "Alas is not available.")) }
        return await app.createDelegatedWorktree(projectId: projectID, branch: branch, base: base, recordDestination: recordDestination)
    }

    func delegatedSessionParentsChanged() {
        app?.nextPromptCoordinator.invalidateAll()
    }

    func workspaceDeletionRefusal(for worktree: Worktree) -> String? { app?.workspaceOwnershipDeletionRefusal(for: worktree) }

    func providerReviewOriginalPath(_ session: ReviewDraftSessionID, path: String) async -> String? {
        await app?.reviewRequestOriginalPath(forDraftSessionID: session, relativePath: path) ?? nil
    }

    func reviewReplyAdded(_ reply: ReviewCommentReply, to comment: ReviewDraftComment, in worktree: Worktree) {
        app?.observeReviewReplyAttention(worktree: worktree, comment: comment, reply: reply)
    }

    func runConsoleIsHidden(scriptKey: String, worktreeID: String) -> Bool? {
        app?.scriptTab(scriptKey: scriptKey, worktreeID: worktreeID).map(\.isHiddenRunTab)
    }

    func hasUnsavedEditorChanges(in worktree: Worktree) -> Bool {
        app.map { !$0.dirtyTabGenerations(worktreeId: worktree.id).isEmpty } ?? false
    }
    var repoHookLoader = RepoHookLoader()
    var repoHookPrompter: RepoHookPrompter = .skipping
    var worktreeCleanupLauncher: AppState.WorktreeCleanupLauncher = { try WorktreeTrashCleaner.launch($0) }

    init() {}

    func quiesceWorktree(_ worktree: Worktree, in core: AlasCoreContext) async throws {
        try await app?.quiesceWorktreeForRemoval(worktree)
    }

    /// With nothing acknowledged, any unsaved edit refuses as the editors close.
    func quiesceWorktree(_ worktree: Worktree, refusingUnsavedEdits: Bool, in core: AlasCoreContext) async throws {
        guard refusingUnsavedEdits, let app else { return try await quiesceWorktree(worktree, in: core) }
        try await app.withAcknowledgedDirtyTabs([:], for: worktree) {
            try await quiesceWorktree(worktree, in: core)
        }
    }

    func checkpointRecoveryBlocksRemoval(_ worktree: Worktree) async -> Bool {
        await app?.checkpointWorktreeRemovalDisabledAfterDiscovery(worktree) ?? true
    }

    func launchWorktreeCleanup(_ ticket: WorktreeTrashCleanupTicket) throws {
        try worktreeCleanupLauncher(ticket)
    }

    /// The app's refresh also reconciles what it shows, and saves by itself.
    func refreshProjectWorktrees(_ projectID: String, in core: AlasCoreContext) async throws -> Bool {
        _ = try await app?.refreshProjectWorktrees(projectId: projectID)
        return false
    }

    func globalTerminalConfig() -> AppConfig.Terminal {
        app?.config.terminal ?? AppConfig.defaults.terminal
    }

    func stopWorkspaceCheckoutSessions(_ checkout: WorkspaceCheckout, in core: AlasCoreContext) async throws {
        try await app?.stopWorkspaceCheckoutSessions(checkout)
    }

    /// The app's own manager, configured for its remote host, MCP servers and UI.
    func sessionManager(for worktree: Worktree, in core: AlasCoreContext) throws -> ACPSessionManager {
        guard core.projects.admitsNewWork(in: worktree) else {
            throw SessionRefusal.ownerUnavailable(reason: "Another operation holds the worktree.")
        }
        guard let manager = app?.acpManager(for: worktree) else {
            throw SessionRefusal.ownerUnavailable(reason: "The worktree cannot host sessions now.")
        }
        return manager
    }

    func resolveWorkspaceRepoHook(_ request: WorkspaceRepoHookRequest) async throws -> String? {
        try await app?.preparedWorkspaceRepoHook(request)
    }

    /// The app's own view of its checkouts and worktrees, kept on the main
    /// actor, so a lifecycle operation that started meanwhile refuses.
    func admitsSessionCreation(owner: SessionOwnerID, in core: AlasCoreContext) -> Bool {
        guard let app else { return false }
        switch owner {
        case .worktree(let worktreeID):
            return app.projectsManager.admitsNewWork(worktreeId: worktreeID)
        case .workspaceCheckout(let id, let location):
            guard let checkout = app.workspacesManager.checkout(id: id) else { return false }
            return checkout.executionLocation.normalized == location.normalized
                && checkout.operation == .idle && checkout.archivedAt == nil
        }
    }

    /// The app's own recovery checks, which also cover Workspace checkouts.
    func checkpointRecoveryBlocksSessions(owner: SessionOwnerID, in core: AlasCoreContext) async -> Bool {
        await app?.checkpointACPAdmissionDisabledAfterDiscovery(owner: owner, fallbackWorktree: nil) ?? true
    }

    /// The agents the app offers for new sessions: enabled ACP agents, and on
    /// a remote project only those that can run there.
    func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool {
        guard let app,
              ACPLaunchCatalog.specs.contains(where: { $0.agentID == agentID }),
              let agent = app.agentRegistry.enabled().first(where: { $0.id == agentID })
        else { return false }
        return remoteHost == nil || agent.canRunOnRemoteHost
    }

    /// The app's own checkout manager, which also resolves remote roots.
    func sessionManager(forCheckout checkout: WorkspaceCheckout, in core: AlasCoreContext) async throws -> ACPSessionManager {
        guard let app else { throw SessionRefusal.ownerUnavailable(reason: "The app is closing.") }
        let unreachable = SessionRefusal.ownerUnavailable(reason: "The Workspace checkout's folder is not reachable yet.")
        guard case .ready(let manager) = await app.workspaceACPManager(for: checkout) else { throw unreachable }
        // A cached manager skips the reachability checks; the app's own
        // creation path rechecks the checkout the same way.
        guard await app.authoritativeCheckoutForWorkspaceACPSessionCreation(checkout) != nil else { throw unreachable }
        return manager
    }
}
