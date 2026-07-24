import Foundation
import AppKit
import Observation
import os

@Observable
@MainActor
final class AppState {
    static let piMCPGeneratedConfigExcludePath = ".pi/mcp.json"

    /// Stable for this process; identifies this app instance to the ACP
    /// session-lease layer so two running Alas builds don't fight over a
    /// shared per-worktree database.
    let instanceId: String = UUID().uuidString
    var config: AppConfig
    var themeStore: ThemeStore
    var projectsManager: ProjectsManager
    private var unpersistedGGWorktreeModes: [String: [String: GGWorktreeMode]] = [:]
    var spacesManager: SpacesManager
    var selectedWorktreeId: String?
    var pendingSettingsSection: SettingsSection?
    @ObservationIgnored
    private var _tabs: TabsManager?
    var tabs: TabsManager {
        if let _tabs { return _tabs }
        let manager = TabsManager(lsp: lsp)
        _tabs = manager
        return manager
    }
    let terminal = TerminalService()
    @ObservationIgnored
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "AppState")
    struct OpenedTerminalSession {
        let id: String
        let foregroundPid: () -> pid_t?
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
    @ObservationIgnored
    private var acpAuthTerminalExitHandlers: [String: () -> Void] = [:]
    @ObservationIgnored
    private var attemptedRemoteHelperHosts: Set<String> = []
    @ObservationIgnored
    private var attemptedRemoteZmxHosts: Set<String> = []
    @ObservationIgnored
    private var remoteAccelerationProbeFailures: [String: Date] = [:]
    @ObservationIgnored
    private var remoteAccelerationTasks: [String: Task<Void, Never>] = [:]
    private let remoteAccelerationProbeRetryDelay: TimeInterval = 30
    /// Keys of in-flight run-script launches (`"<worktreeId>:<scriptKey>"`).
    /// `RunScript.launchScript` inserts synchronously before starting its
    /// async `Task` and removes on completion, closing the window where two
    /// rapid invocations (double-click, repeated Enter) would both see no
    /// registered tab yet and both launch — see `AppState+RunScripts.swift`.
    @ObservationIgnored
    var pendingScriptLaunches: Set<String> = []
    let rightPaneStore = RightPaneStore()
    let harness = HarnessService()
    let mcpRegistrationRegistry = MCPRegistrationRegistry()
    let mcpHTTPSupervisor = AlasMCPHTTPSupervisor()
    let acpAdapterUpdateStore = ACPAdapterUpdateStore()
    let acpAdapterInstallCoordinator = ACPAdapterInstallCoordinator()

    // MARK: Remote control
    /// Paired-device registry backed by an on-disk JSON store. Lazy so the
    /// file isn't touched unless the remote feature is actually exercised.
    @ObservationIgnored
    private(set) lazy var remotePairing = RemotePairingService(store: FileDeviceStore())
    /// The live server, or nil when remote control is disabled. Mutated only
    /// by `syncRemoteServer()`.
    @ObservationIgnored
    private(set) var remoteServer: RemoteServer?
    /// Last bind/start failure, surfaced by the Settings pane. Nil when the
    /// server is running or intentionally stopped. Observable so the pane
    /// reacts when a bind fails.
    private(set) var lastRemoteError: String?
    /// The server's bound port once the listener is ready, else nil. Observable
    /// so the pane reveals the address/QR as soon as the server comes up (the
    /// listener binds asynchronously, so the value arrives after `start`).
    private(set) var remotePort: UInt16?
    private(set) var remoteAdvertisedAddresses: [RemoteAdvertisedAddress] = []
    private(set) var remoteConnectedDeviceCountsSnapshot: [String: Int] = [:]
    @ObservationIgnored
    var remoteSessionAttachScheduler: (@MainActor (ACPSessionManager, ACPSession.ID) -> Void)?

    private func makeRemoteInterfaces() -> [RemoteNetworkInterface] {
        RemoteNetwork.interfaces()
    }

    private func makeRemoteAdvertisedAddresses(
        port: UInt16?,
        interfaces: [RemoteNetworkInterface]
    ) -> [RemoteAdvertisedAddress] {
        guard let port else { return [] }
        return RemoteNetwork.advertisedAddresses(
            port: port,
            interfaces: interfaces,
            allowedHosts: config.remote.allowedHosts,
            preferredHost: config.remote.preferredAdvertisedHost
        )
    }

    private func makeRemoteAdvertisedAddresses(port: UInt16?) -> [RemoteAdvertisedAddress] {
        makeRemoteAdvertisedAddresses(port: port, interfaces: makeRemoteInterfaces())
    }

    private func makeRemoteAccessPolicy(interfaces: [RemoteNetworkInterface]) -> RemoteAccessPolicy {
        let hosts = RemoteNetwork.allowedHostCandidates(
            interfaces: interfaces,
            allowedHosts: config.remote.allowedHosts
        )
        return RemoteAccessPolicy(allowedHosts: hosts)
    }

    private func makeRemoteAccessPolicy() -> RemoteAccessPolicy {
        makeRemoteAccessPolicy(interfaces: makeRemoteInterfaces())
    }

    func refreshRemoteAccessState() {
        let interfaces = makeRemoteInterfaces()
        remoteAdvertisedAddresses = makeRemoteAdvertisedAddresses(port: remotePort, interfaces: interfaces)
        remoteServer?.updateAccessPolicy(makeRemoteAccessPolicy(interfaces: interfaces))
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
        if config.remote.enabled {
            guard remoteServer == nil else {
                refreshRemoteAccessState()
                return
            }
            let root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("RemoteWeb")
            let assets = RemoteWebAssets(root: root)
            let server = RemoteServer(
                pairing: remotePairing,
                assets: assets,
                provider: self,
                accessPolicy: makeRemoteAccessPolicy(),
                diagnostics: { [weak self] port in
                    RemoteDiagnosticsSnapshot(
                        appName: "Alas",
                        port: port,
                        addresses: self?.remoteAdvertisedAddresses ?? [],
                        usesPlainHTTP: true,
                        pairedDeviceCount: self?.remotePairing.devices.count ?? 0
                    )
                }
            )
            server.onPortChange = { [weak self] p in
                self?.remotePort = p
                self?.refreshRemoteAccessState()
            }
            server.onConnectionDeviceCountsChange = { [weak self] counts in
                self?.remoteConnectedDeviceCountsSnapshot = counts
            }
            do {
                // Pin a stable default port so a paired phone's URL survives app
                // restarts (config 0 means "use the default", not OS-assigned).
                let boundPort: UInt16 = config.remote.port != 0 ? config.remote.port : 8765
                try server.start(port: boundPort)
                remoteServer = server
                lastRemoteError = nil
            } catch {
                remoteServer = nil
                remotePort = nil
                remoteAdvertisedAddresses = []
                remoteConnectedDeviceCountsSnapshot = [:]
                lastRemoteError = error.localizedDescription
            }
        } else {
            remoteServer?.stop()
            remoteServer = nil
            remotePort = nil
            remoteAdvertisedAddresses = []
            remoteConnectedDeviceCountsSnapshot = [:]
            lastRemoteError = nil
        }
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

    var isSearchOpen: Bool = false
    var isRepoSelectorOpen: Bool = false
    var isAgentLauncherOpen: Bool = false
    var isReviewPaletteOpen: Bool = false
    var isRunScriptPaletteOpen: Bool = false
    var pendingRunScriptCreation: RunScriptCreationPresentation?
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

    func openAgentLauncherOverlay(mode: AppConfig.LauncherMode? = nil) {
        reviewPalette.close()
        isReviewPaletteOpen = false
        search.close()
        isSearchOpen = false
        repoSelector.close()
        isRepoSelectorOpen = false
        runScriptPalette.reset()
        isRunScriptPaletteOpen = false
        agentLauncher.prepareForOpen(
            defaultMode: mode ?? config.agents.defaultLauncherMode
        )
        isAgentLauncherOpen = true
    }

    func toggleAgentLauncherOverlay(canOpen: Bool) {
        guard canOpen else { return }
        if isAgentLauncherOpen {
            agentLauncher.reset()
            isAgentLauncherOpen = false
        } else {
            openAgentLauncherOverlay(mode: nil)
        }
    }

    func openRunScriptPaletteOverlay() {
        guard !isRunScriptPaletteOpen else { return }
        reviewPalette.close()
        isReviewPaletteOpen = false
        search.close()
        isSearchOpen = false
        repoSelector.close()
        isRepoSelectorOpen = false
        agentLauncher.reset()
        isAgentLauncherOpen = false
        runScriptPalette.reset()
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

    /// Resolve a single agent by id (built-in id or custom UUID). Nil for
    /// unknown ids or "none".
    func agent(id: String?) -> AgentDefinition? {
        guard let id, id != "none" else { return nil }
        return agentRegistry.agents.first(where: { $0.id == id })
    }

    /// Recompute `agentRegistry` from `config.agents` + a fresh detection
    /// scan. Safe to call repeatedly.
    func rescanAgents() {
        let registry = composeRegistryWithoutDetection()
        Task { @MainActor in
            let installedIds = await AgentDetector.scanCurrentEnvironment(
                agents: registry.agents
            )
            self.agentRegistry = AgentRegistry(
                builtinState: self.config.agents.builtinState,
                customs: self.config.agents.custom,
                installedIds: installedIds
            )
            self.snapInvalidatedAgentSelections()
        }
    }

    /// Build a registry view without running detection — used as the input
    /// to detection (since the detector needs the merged agent list).
    private func composeRegistryWithoutDetection() -> AgentRegistry {
        AgentRegistry(
            builtinState: config.agents.builtinState,
            customs: config.agents.custom,
            installedIds: []
        )
    }

    /// When an enabled agent becomes disabled / uninstalled / deleted, snap
    /// any selector pointing at it to a safe default:
    ///   - `changes.aiToolId` → "none"
    ///   - `agents.worktreeAutoLaunch.agentId` → nil
    ///   - per-project `worktreeAgentMode` → `.useGlobal` if it referenced
    ///     a vanished agent
    private func snapInvalidatedAgentSelections() {
        let enabledIds = Set(agentRegistry.enabled().map(\.id))
        var changed = false
        let currentTool = config.changes.aiToolId
        if currentTool != "none", !enabledIds.contains(currentTool) {
            config.changes.aiToolId = "none"
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

    private(set) var installerHost: InstallerHost = .detect()

    /// Re-detect installers after an install completes so that, e.g., installing
    /// `cargo` and then a cargo-based LSP works without app restart.
    func refreshInstallerHost() {
        installerHost = .detect()
    }

    enum ForceDeleteReason: Equatable {
        case dirty
        case containsSubmodules

        var alertTitleSuffix: String {
            switch self {
            case .dirty:
                "has uncommitted changes."
            case .containsSubmodules:
                "contains submodules."
            }
        }

        var alertMessage: String {
            switch self {
            case .dirty:
                "Force delete? Any uncommitted work in this worktree will be lost."
            case .containsSubmodules:
                "Git requires force delete for worktrees containing initialized submodules. Any uncommitted work in this worktree will be lost."
            }
        }
    }

    /// Set when a worktree deletion fails because Git requires `--force`.
    /// The UI presents a confirmation dialog; confirming retries with force.
    struct PendingForceDeleteWorktree: Identifiable, Equatable {
        let id: String           // worktree id
        let branch: String
        let projectId: String
        let repoPath: URL        // git root (project.path)
        let worktreePath: URL    // actual worktree path
        let deleteBranchIfMerged: Bool
        let removedIndex: Int
        let reason: ForceDeleteReason
    }
    var pendingForceDeleteWorktree: PendingForceDeleteWorktree?

    struct WorktreeDeleteConfirmation: Equatable {
        let title: String
        let message: String
        let buttonTitle: String
        let force: Bool
    }

    struct WorktreeDeleteDecision: Equatable {
        let confirmation: WorktreeDeleteConfirmation
        let force: Bool
    }

    @ObservationIgnored
    lazy var search: SearchModel = SearchModel(environment: makeSearchEnvironment())
    @ObservationIgnored
    let fileIndex = FileIndex()
    @ObservationIgnored
    private let statusCache = GitStatusCache()

    var lsp: WorkspaceLSPManager {
        if let lspManager { return lspManager }
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: config.code.languageServers))
        lspManager = manager
        return manager
    }

    @ObservationIgnored
    private let store: any PersistenceStoreProtocol
    @ObservationIgnored
    private let persistenceErrorHandler: (String, String) -> Void
    @ObservationIgnored
    private let fileActionErrorHandler: (String, String) -> Void
    @ObservationIgnored
    private var scheduledSpacesSave: Task<Void, Never>?

    /// One FSEvents watcher per project, watching `<repo>/.git` to auto-refresh
    /// the sidebar when branches flip or worktrees appear/disappear externally.
    @ObservationIgnored
    private var projectGitWatchers: [String: ProjectGitWatcher] = [:]
    @ObservationIgnored
    private var remoteProjectWatchers: [String: RemoteProjectGitWatcher] = [:]
    @ObservationIgnored
    private let projectGitWatcherFactory: @MainActor (URL) -> ProjectGitWatcher

    init(
        store: any PersistenceStoreProtocol = PersistenceStore(),
        persistenceErrorHandler: ((String, String) -> Void)? = nil,
        fileActionErrorHandler: ((String, String) -> Void)? = nil,
        terminalSessionOpener: TerminalSessionOpener? = nil,
        projectGitWatcherFactory: @escaping @MainActor (URL) -> ProjectGitWatcher = { ProjectGitWatcher(repoPath: $0) }
    ) {
        self.store = store
        self.persistenceErrorHandler = persistenceErrorHandler ?? { title, message in
            AppState.showWarningAlert(title: title, message: message)
        }
        self.fileActionErrorHandler = fileActionErrorHandler ?? { title, message in
            AppState.showWarningAlert(title: title, message: message)
        }
        self.terminalSessionOpener = terminalSessionOpener
        self.projectGitWatcherFactory = projectGitWatcherFactory
        let config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? AppConfig.defaults
        let projectsFile = (try? store.readIfExists(ProjectsFile.self, from: Paths.projectsFile)) ?? ProjectsFile(projects: [])
        let spacesFile = try? store.readIfExists(SpacesFile.self, from: Paths.spacesFile)
        self.config = config
        self.languageServerConfigChangeTracker = LanguageServerConfigChangeTracker(
            initial: config.code.languageServers
        )
        // Publish the effective shortcut reservations so the terminal pane
        // can honor user overrides from the very first keystroke.
        ShortcutReservations.update(from: config)
        self.projectsManager = ProjectsManager(persistedProjects: projectsFile.projects)
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
        let themeStore = (try? ThemeStore(initialId: config.themeId)) ?? (try! ThemeStore())
        // Apply the persisted accent override so the picker's selection
        // survives relaunches; otherwise launches always show the theme's
        // built-in accent until the user re-clicks the picker.
        themeStore.setAccent(config.accent)
        // Same for "Match system" — the toggle's state needs to drive the
        // current theme on launch, not just on subsequent toggle events.
        if config.matchSystemTheme {
            themeStore.setMatchSystem(true)
        }
        self.themeStore = themeStore
        // All stored properties are initialized; we can safely capture `self`.
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
        AlasTerminationCoordinator.shared.flush = { [weak self] in
            await self?.flushAllACPComposerDrafts()
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

    /// All worktree IDs currently known to the projects manager (including
    /// hidden/archived ones).
    func allWorktreeIds() -> Set<String> {
        Set(projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        })
    }

    private func reconcileInterruptedDelegations() async {
        guard let records = try? await acpOrchestrationPersistence.incompleteDelegations() else { return }
        for record in records {
            let worktree = record.childWorktreeId.flatMap(worktree(withId:))
                ?? worktree(atPersistedDestinationPath: record.worktreeRequest.destinationPath)
            guard let worktree,
                  let manager = acpManager(for: worktree)
            else {
                try? await acpOrchestrationPersistence.updatePhase(
                    childSessionId: record.childSessionId,
                    phase: .failed,
                    failureMessage: "Alas stopped before delegated session setup completed.",
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
                continue
            }
            if record.childWorktreeId != worktree.id {
                try? await acpOrchestrationPersistence.updateChildWorktree(
                    childSessionId: record.childSessionId,
                    worktreeId: worktree.id,
                    phase: .starting,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
            }
            delegatedSessionParents[record.childSessionId] = record.parentSessionId
            let sessionAlreadyPersisted = await manager.persistedSessionRow(id: record.childSessionId) != nil
            if sessionAlreadyPersisted {
                _ = manager.placeholderSession(id: record.childSessionId)
                await manager.hydrateIfNeeded(id: record.childSessionId)
            } else {
                _ = manager.createSession(
                    id: record.childSessionId,
                    agentId: record.agentId,
                    autoRunDefault: config.harness.acpAutoRunByDefault
                )
            }
            let restoredPendingPrompt = record.pendingInitialPrompt != nil
            if let prompt = record.pendingInitialPrompt {
                let accepted = await manager.enqueueDelegatedPrompt(
                    text: prompt,
                    source: ACPDelegatedPromptSource(
                        sessionId: record.parentSessionId,
                        messageId: "initial-\(record.childSessionId)"
                    ),
                    into: record.childSessionId
                )
                guard accepted else {
                    try? await acpOrchestrationPersistence.updatePhase(
                        childSessionId: record.childSessionId,
                        phase: .failed,
                        failureMessage: "Could not restore delegated session prompt.",
                        updatedAt: Int64(Date().timeIntervalSince1970)
                    )
                    continue
                }
            } else if !sessionAlreadyPersisted {
                try? await acpOrchestrationPersistence.updatePhase(
                    childSessionId: record.childSessionId,
                    phase: .failed,
                    failureMessage: "Could not restore delegated session prompt.",
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
                continue
            }
            await manager.attach(to: record.childSessionId, freshlyCreated: !sessionAlreadyPersisted)
            guard let session = manager.liveSession(for: record.childSessionId),
                  session.agentState == .ready
            else {
                try? await acpOrchestrationPersistence.updatePhase(
                    childSessionId: record.childSessionId,
                    phase: .failed,
                    failureMessage: recoveredDelegatedSessionFailureMessage(manager.liveSession(for: record.childSessionId)),
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
                continue
            }
            if restoredPendingPrompt {
                try? await acpOrchestrationPersistence.clearPendingInitialPrompt(
                    childSessionId: record.childSessionId,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
            }
            try? await acpOrchestrationPersistence.updatePhase(
                childSessionId: record.childSessionId,
                phase: .ready,
                failureMessage: nil,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )
            await deliverPendingDelegatedMessages(to: record.childSessionId, manager: manager)
        }
        await drainRecoveredDelegatedMessageTargets()
    }

    private func recoveredDelegatedSessionFailureMessage(_ session: ACPSession?) -> String {
        guard let session else { return "Could not restore delegated ACP session." }
        switch session.setupState {
        case .needsSetup(let reason), .setupError(let reason):
            return reason
        case .needsAuth(_, let reason):
            return reason ?? "ACP session needs authentication."
        case .checking, .ready:
            break
        }
        if case .failed(let reason) = session.agentState {
            return reason
        }
        return "Could not restore delegated ACP session."
    }

    private func drainRecoveredDelegatedMessageTargets() async {
        guard let targetSessionIds = try? await acpOrchestrationPersistence.pendingMessageTargetSessionIds() else {
            return
        }
        for sessionId in targetSessionIds {
            let childRecord = try? await acpOrchestrationPersistence.parent(childSessionId: sessionId)
            if let childRecord {
                delegatedSessionParents[childRecord.childSessionId] = childRecord.parentSessionId
            }
            guard let manager = await acpManagerForPersistedSession(
                sessionId: sessionId,
                preferredWorktreeId: childRecord?.childWorktreeId ?? childRecord?.worktreeRequest.worktreeId
            ) else { continue }
            await deliverPendingDelegatedMessages(to: sessionId, manager: manager)
            await scheduleRecoveredDelegatedMessageRetry(to: sessionId, manager: manager)
        }
    }

    private func scheduleRecoveredDelegatedMessageRetry(to sessionId: String, manager: ACPSessionManager) async {
        guard let remaining = try? await acpOrchestrationPersistence.pendingMessages(targetSessionId: sessionId),
              !remaining.isEmpty
        else { return }
        Task { @MainActor [weak self, weak manager] in
            try? await Task.sleep(nanoseconds: 61_000_000_000)
            guard let self, let manager else { return }
            await self.deliverPendingDelegatedMessages(to: sessionId, manager: manager)
        }
    }

    private func acpManagerForPersistedSession(
        sessionId: String,
        preferredWorktreeId: String?
    ) async -> ACPSessionManager? {
        var worktreeIds: [String] = []
        if let preferredWorktreeId {
            worktreeIds.append(preferredWorktreeId)
        }
        worktreeIds.append(contentsOf: allWorktreeIds().filter { $0 != preferredWorktreeId }.sorted())
        for worktreeId in worktreeIds {
            guard let worktree = worktree(withId: worktreeId),
                  let manager = acpManager(for: worktree),
                  let row = await manager.persistedSessionRow(id: sessionId),
                  !row.archived
            else { continue }
            _ = manager.placeholderSession(id: sessionId)
            await manager.hydrateIfNeeded(id: sessionId)
            return manager
        }
        return nil
    }

    func toggleRightPaneVisibility() {
        config.rightPaneVisible.toggle()
        _ = saveConfig()
    }

    func toggleSidebarVisibility() {
        config.sidebarVisible.toggle()
        _ = saveConfig()
    }

    /// Tear down tabs, terminals, harness state, and editor buffers for any
    /// worktree IDs that existed in `beforeIds` but are absent after a refresh.
    /// Also re-points selection if the selected worktree was removed.
    func cleanupMissingWorktrees(beforeIds: Set<String>) {
        let afterIds = allWorktreeIds()
        let disappeared = beforeIds.subtracting(afterIds)
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
        GGInboxStore.shared.prune(keepingProjectIds: Set(projects.map(\.id)))
        if reconcileMissingSpaceProjects() {
            saveSpaces()
        }
        if let current = selectedWorktreeId, !afterIds.contains(current) {
            selectWorktree(id: resolvedSelectionForActiveSpace())
        }
    }

    /// Re-scan persisted tab JSONs for every currently-known worktree id. Call
    /// after `projectsManager.refreshAll()` so worktrees actually exist.
    func reloadTabs() {
        let allWorktreeIds = projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        }
        tabs.loadAll(worktreeIds: allWorktreeIds)
        // When cross-quit persistence is disabled, drop every persisted
        // terminal tab right after load — across all worktrees, before
        // any lazy-display path could observe them — so orphan zmx
        // daemon sessions get killed via `closeTab` and inactive /
        // other-worktree tabs don't linger waiting for someone to open
        // them (which is the only thing that drives the per-tab guard
        // in `restoreTerminalTabIfNeeded`).
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
        Task { [weak self] in
            await self?.reconcileInterruptedDelegations()
        }
    }

    /// Compute (knownWorktreeIds, knownLeafIds) from in-memory state and
    /// hand them to `TerminalService.sweepOrphans`. Run after `reloadTabs`
    /// so persisted leaves are visible; without this, sessions leaked by
    /// any prior bug (or quit race) would persist forever because nothing
    /// would ever try to kill them on subsequent launches.
    private func sweepOrphanZmxSessions(worktreeIds: [String]) {
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

    var projects: [ProjectConfig] { projectsManager.projects }

    var activeSpaceProjects: [ProjectConfig] {
        spacesManager.activeProjects(from: projects)
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
                // for them) but keep deleteFailed selectable so the user
                // can recover via keyboard nav, mirroring the sidebar.
                return self.projectsManager.visibleWorktrees(projectId: projectId).filter {
                    switch self.projectsManager.operationState(for: $0.id) {
                    case .creating, .deleting, .createFailed:
                        return false
                    case nil, .deleteFailed:
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
            currentWorktreeId: { [weak self] in self?.selectedWorktreeId }
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
            try store.write(ProjectsFile(projects: projectsManager.projects), to: Paths.projectsFile)
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
            try store.write(spacesManager.file, to: Paths.spacesFile)
            return true
        } catch {
            persistenceErrorHandler("Spaces Save Failed", error.localizedDescription)
            return false
        }
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

    func selectWorktree(id: String?) {
        guard selectedWorktreeId != id || spacesManager.activeSpace?.lastSelectedWorktreeId != id else { return }
        selectedWorktreeId = id
        spacesManager.setLastSelectedWorktree(id)
        scheduleSpacesSave()
        if let id,
           let resolved = projectAndWorktree(withWorktreeId: id),
           resolved.project.host != nil {
            Task { @MainActor [weak self] in
                await self?.prepareRemoteAccelerationIfNeeded(for: resolved.project)
            }
        }
    }

    @discardableResult
    func switchToSpace(id: String) -> Bool {
        let previousSpaceId = spacesManager.activeSpaceId
        spacesManager.switchToSpace(id: id)
        guard spacesManager.activeSpaceId != previousSpaceId else { return false }
        let selection = resolvedSelectionForActiveSpace()
        selectedWorktreeId = selection
        spacesManager.setLastSelectedWorktree(selection)
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
        switchToSpace(id: spaces[next].id)
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
            selectedWorktreeId = fallbackSelection
            spacesManager.setLastSelectedWorktree(fallbackSelection)
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
            let selection = resolvedSelectionForActiveSpace()
            selectedWorktreeId = selection
            spacesManager.setLastSelectedWorktree(selection)
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
        ggWorktreeMode: GGWorktreeMode = .inherit
    ) async -> String {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            // Should not happen if the dialog validated the project; fail silently.
            return ""
        }
        let repoPath = URL(fileURLWithPath: project.path)
        // Canonicalize once and use this URL everywhere downstream — both
        // the optimistic row and the eventual `WorktreeService.add` return
        // value derive their `id` from the path we hand in, so any
        // divergence here would make `selectedWorktreeId` and terminal
        // routing target a non-existent row after reconcile.
        //
        // resolvingSymlinksInPath only resolves links along path components
        // that exist on disk; the leaf doesn't exist yet, so resolve the
        // parent (which does) and reattach the leaf.
        let canonicalDestination: URL
        do {
            canonicalDestination = try await Self.preparedCreateWorktreeDestination(
                repoPath: repoPath,
                destination: destination
            )
        } catch {
            showFileActionError(title: "Create Worktree Failed", message: error.localizedDescription)
            return ""
        }
        let optimisticId = Worktree.makeId(path: canonicalDestination)
        if projectsManager.worktrees(projectId: projectId).contains(where: { $0.id == optimisticId }) {
            let isRetryingFailedCreate: Bool
            if case .createFailed = projectsManager.operationState(for: optimisticId) {
                isRetryingFailedCreate = true
            } else {
                isRetryingFailedCreate = false
            }
            if !isRetryingFailedCreate {
                return ""
            }
        }
        rightPaneStore.invalidateSnapshot(worktreeId: optimisticId)
        let optimistic = Worktree(
            id: optimisticId,
            projectId: projectId,
            name: branch,
            branch: branch,
            path: canonicalDestination,
            status: .clean,
            lastActivity: Date()
        )
        if launchSurface != .delegated,
           let containing = spacesManager.containingSpaceId(forProjectId: projectId),
           containing != spacesManager.activeSpaceId {
            _ = switchToSpace(id: containing)
        }
        projectsManager.insertOptimisticWorktree(optimistic)
        setUnpersistedGGWorktreeMode(
            projectId: projectId,
            worktreeId: optimistic.id,
            mode: ggWorktreeMode
        )
        projectsManager.setOperationState(id: optimistic.id, state: .creating)
        rightPaneStore.reevaluateGGGate(worktreeId: optimistic.id)
        if launchSurface != .delegated {
            selectWorktree(id: optimistic.id)
        }

        let startupScript = StartupScriptResolver.worktreeCreateScript(
            global: config.terminal,
            project: project
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            do {
                if self.config.worktrees.fetchRemoteBeforeCreate {
                    if let fetchInfo = try? await GitService().remoteForFetch(worktreePath: repoPath, ref: base) {
                        do {
                            _ = try await GitService().fetchRef(
                                worktreePath: repoPath,
                                remote: fetchInfo.remote,
                                branch: fetchInfo.branch
                            )
                        } catch {
                            Self.logger.error("Fetch failed before creating worktree: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
                let newWorktree = try await Self.performCreateWorktree(
                    repoPath: repoPath,
                    base: base, branch: branch, destination: canonicalDestination, projectId: projectId
                )
                guard projects.contains(where: { $0.id == projectId }) else { return }
                if runStartup && !startupScript.isEmpty {
                    if let host = project.host ?? RemoteHostRegistry.shared.host(forPath: newWorktree.path.path) {
                        _ = try? await RemoteExec.run(host: host, cwd: newWorktree.path.path, command: startupScript)
                    } else {
                        _ = try? await Process.run(
                            "/bin/zsh",
                            args: ["-c", startupScript],
                            cwd: newWorktree.path
                        )
                    }
                }
                guard projects.contains(where: { $0.id == projectId }) else { return }

                do {
                    let wasHidden = projectsManager.isWorktreeHidden(
                        projectId: project.id,
                        path: newWorktree.path
                    )
                    projectsManager.setWorktreeHidden(
                        projectId: project.id,
                        path: newWorktree.path,
                        hidden: false
                    )
                    _ = try await refreshProjectWorktrees(projectId: project.id)
                    guard projects.contains(where: { $0.id == projectId }) else { return }
                    removeUnpersistedGGWorktreeMode(projectId: project.id, worktreeId: newWorktree.id)
                    projectsManager.setGGWorktreeMode(
                        projectId: project.id,
                        worktreeId: newWorktree.id,
                        mode: ggWorktreeMode
                    )
                    if ggWorktreeMode != .inherit {
                        saveProjects()
                    }
                    rightPaneStore.reevaluateGGGate(worktreeId: newWorktree.id)
                    projectsManager.setOperationState(id: optimistic.id, state: nil)
                    if wasHidden {
                        saveProjects()
                    }

                    if launchSurface != .delegated {
                        selectWorktree(id: newWorktree.id)
                    }

                    switch launchSurface {
                    case .none:
                        break
                    case .terminal(let agentId):
                        let suffix: String? = {
                            guard let id = agentId,
                                  let agent = self.agentRegistry.enabled().first(where: { $0.id == id })
                            else { return nil }
                            return self.agentStartupCommand(for: agent, project: project)
                        }()
                        _ = try? await openTerminalTabPreparingRemoteZmxIfNeeded(
                            for: newWorktree,
                            startupScriptSuffix: suffix
                        )
                    case .acp(let agentId):
                        openNewACPSession(agentID: agentId)
                    case .delegated:
                        break
                    }
                } catch {
                    discardUnpersistedGGWorktreeMode(
                        projectId: projectId,
                        worktreeId: optimistic.id,
                        mode: ggWorktreeMode
                    )
                    projectsManager.setOperationState(
                        id: optimistic.id,
                        state: .createFailed(
                            projectId: projectId,
                            message: error.localizedDescription,
                            base: base,
                            ggWorktreeMode: ggWorktreeMode
                        )
                    )
                }
            } catch {
                let msg = error.localizedDescription
                discardUnpersistedGGWorktreeMode(
                    projectId: projectId,
                    worktreeId: optimistic.id,
                    mode: ggWorktreeMode
                )
                projectsManager.setOperationState(
                    id: optimistic.id,
                    state: .createFailed(
                        projectId: projectId,
                        message: msg,
                        base: base,
                        ggWorktreeMode: ggWorktreeMode
                    )
                )
            }
        }
        return optimistic.id
    }

    @MainActor
    func cliCreateWorktree(origin: Worktree, branch: String, base: String?) async -> AlasCLIResponse {
        guard let project = projects.first(where: { $0.id == origin.projectId }) else {
            return .error("The current worktree's project is no longer available.")
        }
        switch GitNameValidator.validateBranchName(branch) {
        case .valid:
            break
        case .invalid(let message):
            return .error("invalid branch name: \(message)")
        }

        let destination = WorktreePathTemplateRenderer.render(
            template: config.worktrees.pathTemplate,
            worktreeRoot: config.worktrees.rootPath,
            repoName: project.name,
            branch: branch
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return .error("A worktree already exists at this path.")
        }
        let resolvedBase: String
        if let base {
            resolvedBase = base
        } else {
            let availableBranches = (try? await GitService().branches(at: URL(fileURLWithPath: project.path))) ?? []
            resolvedBase = NewWorktreeDialog.preferredBaseBranch(
                availableBranches: availableBranches,
                configuredDefault: config.worktrees.baseBranch
            )
        }

        let id = await createWorktree(
            projectId: project.id,
            base: resolvedBase,
            branch: branch,
            destination: destination,
            runStartup: true,
            launchSurface: .none
        )
        guard !id.isEmpty else {
            return .error("A worktree already exists at this path.")
        }
        return .text(["creating \(branch) at \(destination.path)"])
    }

    /// Creates a worktree for delegated ACP work without changing the visible
    /// project/worktree selection. The existing creation path remains the
    /// single owner of validation, startup, refresh, and failure handling.
    private func createDelegatedWorktree(
        projectId: String,
        branch: String,
        base: String?
    ) async -> Result<Worktree, ACPSessionOrchestrationCoordinator.WorktreeCreationError> {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            return .failure(.init(message: "The project is no longer available."))
        }
        switch GitNameValidator.validateBranchName(branch) {
        case .valid:
            break
        case .invalid(let message):
            return .failure(.init(message: "invalid branch name: \(message)"))
        }
        let destination = WorktreePathTemplateRenderer.render(
            template: config.worktrees.pathTemplate,
            worktreeRoot: config.worktrees.rootPath,
            repoName: project.name,
            branch: branch
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return .failure(.init(message: "A worktree already exists at this path."))
        }
        let selectedBase: String
        if let base {
            selectedBase = base
        } else {
            let branches = (try? await GitService().branches(at: URL(fileURLWithPath: project.path))) ?? []
            selectedBase = NewWorktreeDialog.preferredBaseBranch(
                availableBranches: branches,
                configuredDefault: config.worktrees.baseBranch
            )
        }
        let id = await createWorktree(
            projectId: projectId,
            base: selectedBase,
            branch: branch,
            destination: destination,
            runStartup: true,
            launchSurface: .delegated
        )
        guard !id.isEmpty else { return .failure(.init(message: "Could not start worktree creation.")) }
        for _ in 0..<1_200 {
            switch projectsManager.operationState(for: id) {
            case .createFailed(_, let message, _, _):
                return .failure(.init(message: message))
            case .creating:
                try? await Task.sleep(for: .milliseconds(250))
            case .deleting, .deleteFailed:
                return .failure(.init(message: "Worktree creation was interrupted."))
            case nil:
                if let worktree = worktree(withId: id) {
                    return .success(worktree)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return .failure(.init(message: "Timed out waiting for worktree creation."))
    }

    func agentStartupCommand(for agent: AgentDefinition, project: ProjectConfig) -> String {
        let binary = project.host == nil
            ? agent.resolvedBinary
            : URL(fileURLWithPath: agent.resolvedBinary).lastPathComponent
        var argv = [binary]
        if let extra = agent.extraTerminalArgs, !extra.isEmpty {
            argv.append(contentsOf: extra)
        }
        if agentBypassPermissionsEnabled(for: project),
           let flag = agent.bypassPermissionsFlag {
            argv.append(flag)
        }
        return argv.map { Self.shellQuote($0) }.joined(separator: " ")
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

    enum ACPAuthTerminalLaunchError: LocalizedError, Equatable {
        case invalidEnvKey(String)

        var errorDescription: String? {
            switch self {
            case .invalidEnvKey(let key):
                return "Invalid auth environment variable name: \(key)"
            }
        }
    }

    @discardableResult
    func openAgentTerminalTab(for worktree: Worktree, agentId: String) throws -> Tab {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw AgentTerminalLaunchError.projectUnavailable
        }
        guard let agent = agentRegistry.enabled().first(where: { $0.id == agentId }) else {
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
        guard let agent = agentRegistry.enabled().first(where: { $0.id == agentId }) else {
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

    @discardableResult
    func openACPAuthTerminalTab(
        for worktree: Worktree,
        command: ACPAuthTerminalCommand,
        onExit: @escaping () -> Void
    ) throws -> Tab {
        let startupScriptSuffix = try Self.shellCommand(
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
            acpAuthTerminalExitHandlers[terminal.root.firstLeaf().sessionId] = onExit
        }
        return tab
    }

    @discardableResult
    func openACPAuthTerminalTabPreparingRemoteZmxIfNeeded(
        for worktree: Worktree,
        command: ACPAuthTerminalCommand,
        onExit: @escaping () -> Void
    ) async throws -> Tab {
        let startupScriptSuffix = try Self.shellCommand(
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
            acpAuthTerminalExitHandlers[terminal.root.firstLeaf().sessionId] = onExit
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

    nonisolated static func shellCommand(
        command: String,
        args: [String],
        env: [String: String],
        exitOnCompletion: Bool = false
    ) throws -> String {
        for key in env.keys where !isValidShellAssignmentName(key) {
            throw ACPAuthTerminalLaunchError.invalidEnvKey(key)
        }
        let envPrefix = env
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value))" }
        let commandLine = (envPrefix + [shellQuote(command)] + args.map(shellQuote)).joined(separator: " ")
        guard exitOnCompletion else { return commandLine }
        return "\(commandLine)\nstatus=$?\nexit \"$status\""
    }

    nonisolated private static func isValidShellAssignmentName(_ key: String) -> Bool {
        key.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        if s.range(of: "[^A-Za-z0-9_/.@%+=,:-]", options: .regularExpression) == nil {
            return s
        }
        // POSIX single-quote escape: end the quoted string, insert an
        // escaped quote, restart the quoted string.
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    nonisolated private static func performCreateWorktree(
        repoPath: URL,
        base: String,
        branch: String,
        destination: URL,
        projectId: String
    ) async throws -> Worktree {
        try await Task.detached {
            if !repoPath.isRemoteAlasPath {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            return try await WorktreeService().add(
                repoPath: repoPath,
                base: base,
                branch: branch,
                destination: destination,
                projectId: projectId
            )
        }.value
    }

    nonisolated static func preparedCreateWorktreeDestination(repoPath: URL, destination: URL) async throws -> URL {
        let isRemote = repoPath.isRemoteAlasPath
        let preparedDestination: URL
        if isRemote,
           let host = RemoteHostRegistry.shared.host(forPath: repoPath.path) {
            let remoteHome = try await Self.remoteHomeDirectory(host: host)
            preparedDestination = URL(fileURLWithPath: Self.destinationPathReplacingLocalHome(
                destination.path,
                remoteHome: remoteHome
            ))
        } else {
            preparedDestination = destination
        }
        if isRemote {
            return preparedDestination
        }
        return preparedDestination
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(preparedDestination.lastPathComponent)
    }

    nonisolated static func destinationPathReplacingLocalHome(
        _ path: String,
        localHome: String = NSHomeDirectory(),
        remoteHome: String
    ) -> String {
        let normalizedLocalHome = localHome.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let localHomePath = "/\(normalizedLocalHome)"
        guard path == localHomePath || path.hasPrefix("\(localHomePath)/") else { return path }
        let suffix = path.dropFirst(localHomePath.count)
        return remoteHome.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? path
            : "/\(remoteHome.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(suffix)"
    }

    nonisolated private static func remoteHomeDirectory(host: String) async throws -> String {
        let result = try await RemoteExec.run(
            host: host,
            cwd: nil,
            command: "printf '%s' \"$HOME\"",
            timeout: 10
        )
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !home.isEmpty else {
            throw NSError(
                domain: "RemoteHomeDirectory",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve remote home directory for \(host)."]
            )
        }
        return home
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
        id: String = UUID().uuidString
    ) async throws {
        let project = try await projectsManager.addProject(
            path: path,
            displayName: displayName,
            icon: icon,
            host: host,
            id: id
        )
        spacesManager.addProject(project.id, toSpace: spacesManager.activeSpaceId)
        saveProjects()
        saveSpaces()
        _ = await refreshAllProjectTopologies()
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
        let remoteRootsToUnregister: [String]
        if let project = projects.first(where: { $0.id == id }),
           project.host != nil {
            remoteRootsToUnregister = [project.path] + projectsManager.worktrees(projectId: id).map(\.path.path)
        } else {
            remoteRootsToUnregister = []
        }
        stopProjectGitWatcher(projectId: id)
        unpersistedGGWorktreeModes.removeValue(forKey: id)
        projectsManager.removeProject(id: id, unregisterRemoteRoots: remoteRootsToUnregister.isEmpty)
        spacesManager.removeProjectEverywhere(id)
        saveProjects()
        saveSpaces()
        let removedIds = beforeIds.subtracting(allWorktreeIds())
        cleanupMissingWorktrees(beforeIds: beforeIds)
        for root in remoteRootsToUnregister {
            RemoteHostRegistry.shared.unregister(root: root)
        }
        for worktreeId in removedIds {
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId))
            try? FileManager.default.removeItem(at: Paths.buffersDir(forWorktreeId: worktreeId))
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
                guard !FileManager.default.fileExists(atPath: project.path) else { continue }
                staleProjectIds.append(project.id)
                continue
            }

            if projectsManager.worktrees(projectId: project.id).isEmpty {
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
        if project.host != nil {
            let watcher = RemoteProjectGitWatcher(projectPath: URL(fileURLWithPath: project.path))
            watcher.onHeadChanged = { [weak self] updates in
                self?.handleProjectHeadUpdates(projectId: project.id, branchByWorktreePath: updates)
            }
            watcher.onTopologyChanged = { [weak self] in self?.handleProjectTopologyChange(projectId: project.id) }
            remoteProjectWatchers[project.id] = watcher
            watcher.start()
            return
        }
        let watcher = projectGitWatcherFactory(URL(fileURLWithPath: project.path))
        let projectId = project.id
        watcher.onHeadChanged = { [weak self] map in self?.handleProjectHeadUpdates(projectId: projectId, branchByWorktreePath: map) }
        watcher.onTopologyChanged = { [weak self] in self?.handleProjectTopologyChange(projectId: projectId) }
        watcher.start()
        projectGitWatchers[projectId] = watcher
    }

    func stopProjectGitWatcher(projectId: String) {
        projectGitWatchers.removeValue(forKey: projectId)?.stop()
        remoteProjectWatchers.removeValue(forKey: projectId)?.stop()
    }

    func startAllProjectGitWatchers() {
        for project in projectsManager.projects {
            startProjectGitWatcher(for: project)
        }
    }

    func stopAllProjectGitWatchers() {
        for (_, watcher) in projectGitWatchers { watcher.stop() }
        projectGitWatchers.removeAll()
        for (_, watcher) in remoteProjectWatchers { watcher.stop() }
        remoteProjectWatchers.removeAll()
    }

    func handleProjectHeadUpdates(projectId: String, branchByWorktreePath: [URL: String]) {
        let changedPaths = projectsManager.applyHeadUpdates(
            projectId: projectId,
            branchByWorktreePath: branchByWorktreePath
        )
        for path in changedPaths {
            GGStackSummaryStore.shared.summaries[path] = nil
        }
    }

    private func handleProjectTopologyChange(projectId: String) {
        Task { @MainActor in
            await refreshProjectTopology(projectId: projectId)
        }
    }

    @discardableResult
    private func refreshProjectWorktrees(projectId: String) async throws -> Bool {
        let previousPaths = Dictionary(uniqueKeysWithValues: projectsManager.projects
            .filter { $0.id == projectId }
            .map { ($0.id, $0.path) })
        let previousBranches = Dictionary(uniqueKeysWithValues: projectsManager
            .worktrees(projectId: projectId)
            .map { (Self.canonicalWorktreePath($0.path.path), (path: $0.path.path, branch: $0.branch)) })
        let changed = try await projectsManager.refreshWorktrees(projectId: projectId)
        for worktree in projectsManager.worktrees(projectId: projectId) {
            let canonicalPath = Self.canonicalWorktreePath(worktree.path.path)
            guard let previous = previousBranches[canonicalPath], previous.branch != worktree.branch else {
                continue
            }
            GGStackSummaryStore.shared.summaries[previous.path] = nil
            GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
        }
        if changed {
            saveProjects()
            rightPaneStore.reevaluateGGGates()
        }
        restartProjectGitWatchers(previousPaths: previousPaths)
        return changed
    }

    func refreshProjectTopology(projectId: String) async {
        let beforeIds = allWorktreeIds()
        _ = try? await refreshProjectWorktrees(projectId: projectId)
        let afterIds = allWorktreeIds()
        let addedIds = afterIds.subtracting(beforeIds)
        if !addedIds.isEmpty {
            tabs.loadAll(worktreeIds: Array(addedIds))
        }
        cleanupMissingWorktrees(beforeIds: beforeIds)
    }

    /// Refresh every project, persist any reconciled configuration, and move
    /// existing watchers when a deleted linked-worktree anchor is replaced.
    @discardableResult
    func refreshAllProjectTopologies() async -> Bool {
        let previousPaths = Dictionary(uniqueKeysWithValues: projectsManager.projects.map { ($0.id, $0.path) })
        let changed = await projectsManager.refreshAll()
        if changed {
            saveProjects()
            rightPaneStore.reevaluateGGGates()
        }
        restartProjectGitWatchers(previousPaths: previousPaths)
        return changed
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
        mcpServers: [ProjectMCPServer]
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        projectsManager.updateProject(
            id: id,
            update: ProjectUpdate(
                name: trimmedName,
                icon: icon,
                startupScripts: startupScripts,
                mcpServers: mcpServers
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

    func setWorktreeLaunchDefaults(projectId: String, openAfterCreate: Bool, launcherMode: AppConfig.LauncherMode) {
        projectsManager.setWorktreeLaunchDefaults(
            projectId: projectId,
            openAfterCreate: openAfterCreate,
            launcherMode: launcherMode
        )
        saveProjects()
    }

    /// Archive (hide) a worktree. Closes all tabs/terminals/harness state for
    /// it, marks the path hidden in `ProjectConfig`, and re-points selection if
    /// the archived worktree was selected. Does NOT touch git or disk.
    func archiveWorktree(_ worktree: Worktree) {
        let dirty = dirtyEditorTabIds(worktreeId: worktree.id)
        if !dirty.isEmpty {
            switch promptForDirtyBuffers(
                action: "Archive",
                branch: worktree.branch,
                dirtyCount: dirty.count,
                onDiskDestructive: false
            ) {
            case .save:
                Task { @MainActor in
                    guard await saveDirtyBuffers(in: worktree) else { return }
                    archiveWorktreeAfterSaving(worktree)
                }
                return
            case .discard:
                break
            case .cancel:
                return
            }
        }

        archiveWorktreeAfterSaving(worktree)
    }

    private func archiveWorktreeAfterSaving(_ worktree: Worktree) {
        // Snapshot index in the visible list BEFORE we mutate anything, so we
        // can pick a sensible follow-up selection.
        let siblingsBefore = projectsManager.visibleWorktrees(projectId: worktree.projectId)
        let removedIndex = siblingsBefore.firstIndex(where: { $0.id == worktree.id }) ?? 0
        let wasSelected = selectedWorktreeId == worktree.id

        cleanupWorktreeState(worktreeId: worktree.id)
        projectsManager.setOperationState(id: worktree.id, state: nil)
        projectsManager.setWorktreeHidden(
            projectId: worktree.projectId,
            path: worktree.path,
            hidden: true
        )
        saveProjects()

        if wasSelected {
            selectWorktree(id: selectionAfterRemoval(
                removedFromProjectId: worktree.projectId,
                removedAtIndex: removedIndex
            ))
        }
    }

    /// Restore an archived worktree. Tabs/terminals are NOT recreated — they
    /// were torn down at archive time and the user re-opens what they need.
    func unarchiveWorktree(projectId: String, path: URL) {
        projectsManager.setWorktreeHidden(projectId: projectId, path: path, hidden: false)
        saveProjects()
    }

    func startHarness() {
        LegacyHookSweep.sweepAll()
        harness.notifications.setEnabled(config.harness.notifyOnFinish)
        harness.start(
            stateLookup: { [weak self] sessionId in
                guard let self else { return nil }
                for s in self.terminal.registry.all where s.id == sessionId {
                    return (projectId: s.projectId, worktreeId: s.worktreeId)
                }
                // Registry miss can happen for zmx-persisted leaves the
                // user hasn't displayed yet (restoreTerminalTabIfNeeded
                // is driven by TerminalTabView.task). Fall back to a
                // persisted-tab scan so background agents still get
                // notifications routed to the right worktree.
                return self.persistedLeafLocation(leafId: sessionId)
            },
            shouldNotifyOnAwaiting: { [weak self] in
                self?.config.harness.notifyOnAwaiting ?? true
            }
        )
        // Per-leaf symlink: stays valid across Alas restarts (the next
        // launch's `linkSession` repoints the same `/tmp/alas-<uid>/sock-
        // <leafId>` path), and per-leaf scoping avoids collisions between
        // concurrent Alas processes.
        terminal.socketPathProvider = { [weak self] leafId in
            self?.harness.socketServer.linkSession(leafId: leafId)
        }
        terminal.socketReleaseHandler = { [weak self] leafId in
            self?.harness.socketServer.unlinkSession(leafId: leafId)
        }
        terminal.onSessionProcessExited = { [weak self] leafId, worktreeId, processAlive in
            self?.handleTerminalProcessExited(
                worktreeId: worktreeId,
                leafId: leafId,
                processAlive: processAlive
            )
        }
        harness.socketServer.onCLIRequest = { [weak self] request in
            guard let self else { return .error("Alas is not available.") }
            return await self.handleCLIRequest(request)
        }
        // The socket server dispatches this on the main queue, so the closure
        // is already main-actor context.
        harness.socketServer.onMCPHello = { [weak self] hello in
            guard let self else { return }
            self.mcpRegistrationRegistry.recordHello(
                sessionId: hello.sessionId, transport: hello.transport
            )
            // Heal immediately if a slow/lazy harness registered after the
            // grace check already flipped the row to notRegistered.
            for manager in self.acpManagers.values {
                if let session = manager.liveSession(for: hello.sessionId) {
                    session.builtInMCPRegistration = .registered
                    break
                }
            }
        }
        harness.onClickThrough = { [weak self] projectId, worktreeId, sessionId in
            self?.activateHarnessSession(
                projectId: projectId, worktreeId: worktreeId, sessionId: sessionId
            )
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
    private func handleCLIRequest(_ request: AlasCLIRequest) async -> AlasCLIResponse {
        let router = makeCLICommandRouter { [weak self] sessionId in
            if let s = self?.terminal.registry.session(for: sessionId) {
                return s.worktreeId
            }
            // Fall back to persisted-tab scan so `alas open` etc.
            // still resolve a worktree for zmx-persisted leaves
            // whose `TerminalSession` hasn't been restored yet.
            if let worktreeId = self?.persistedLeafLocation(leafId: sessionId)?.worktreeId {
                return worktreeId
            }
            return self?.worktreeIdForLiveACPSession(sessionId)
        }
        return await router.handle(request)
    }

    private func worktreeIdForLiveACPSession(_ sessionId: String) -> String? {
        acpManagers.first { _, manager in
            manager.liveSession(for: sessionId) != nil
        }?.key
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
        return nil
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
    }

    /// Caches the loaded file summaries of a provider review, keyed by its
    /// draft session id, so repeated `review_comment_add` calls in the same
    /// review share one `gh`/`glab diff` fetch. Best-effort and never
    /// invalidated: rename mappings rarely change mid-review, and a miss
    /// simply falls back to nil (today's behavior).
    private var providerReviewFileSummaryCache: [ReviewDraftSessionID: [DiffReviewFileSummary]] = [:]

    func makeCLICommandRouter(
        sessionWorktreeLookup: @escaping (String) -> String?
    ) -> AlasCLICommandRouter {
        let orchestration = ACPSessionOrchestrationCoordinator(
            environment: .init(
                persistence: acpOrchestrationPersistence,
                instanceId: instanceId,
                now: { Int64(Date().timeIntervalSince1970) },
                makeID: { UUID().uuidString },
                worktree: { [weak self] id in self?.worktree(withId: id) },
                existingWorktree: { [weak self] projectId, worktreeId in
                    guard let self else { return nil }
                    let worktrees = self.projectsManager.visibleWorktrees(projectId: projectId)
                    if let exactID = worktrees.first(where: { $0.id == worktreeId }) {
                        return exactID
                    }
                    if case .matched(let worktree) = AlasCLIWorktreeResolver.resolve(
                        target: worktreeId,
                        worktrees: worktrees
                    ) {
                        return worktree
                    }
                    return nil
                },
                availableAgents: { [weak self] in
                    guard let self else { return [] }
                    let acpIDs = Set(ACPLaunchCatalog.specs.map(\.agentID))
                    return self.agentRegistry.enabled().map {
                        ACPOrchestrationAgent(id: $0.id, isEnabled: true, isACPCapable: acpIDs.contains($0.id))
                    }
                },
                sessionLocation: { [weak self] sessionId in
                    guard let self,
                          let (worktreeId, manager) = self.acpManagers.first(where: { _, manager in
                              manager.liveSession(for: sessionId) != nil
                          }),
                          let worktree = self.worktree(withId: worktreeId)
                    else { return nil }
                    return .init(
                        origin: ACPOrchestrationSessionOrigin(
                            sessionId: sessionId,
                            projectId: worktree.projectId,
                            worktreeId: worktree.id
                        ),
                        manager: manager
                    )
                },
                manager: { [weak self] worktree in self?.acpManager(for: worktree) },
                newWorktreeDestination: { [weak self] projectId, branch in
                    guard let self,
                          let project = self.projects.first(where: { $0.id == projectId })
                    else { return nil }
                    let destination = WorktreePathTemplateRenderer.render(
                        template: self.config.worktrees.pathTemplate,
                        worktreeRoot: self.config.worktrees.rootPath,
                        repoName: project.name,
                        branch: branch
                    )
                    guard !URL(fileURLWithPath: project.path).isRemoteAlasPath else { return destination }
                    return destination
                        .deletingLastPathComponent()
                        .resolvingSymlinksInPath()
                        .appendingPathComponent(destination.lastPathComponent)
                },
                createWorktree: { [weak self] projectId, branch, base in
                    guard let self else {
                        return .failure(.init(message: "Alas is not available."))
                    }
                    return await self.createDelegatedWorktree(projectId: projectId, branch: branch, base: base)
                },
                rememberParent: { [weak self] childID, parentID in
                    self?.delegatedSessionParents[childID] = parentID
                },
                autoRunDefault: { [weak self] in
                    self?.config.harness.acpAutoRunByDefault ?? false
                },
                notifyChanged: { }
            )
        )
        return AlasCLICommandRouter(
            sessionWorktreeId: sessionWorktreeLookup,
            resolveACPSessionOrigin: { [weak self] sessionId in
                guard let self,
                      let (worktreeId, manager) = self.acpManagers.first(where: { _, manager in
                          manager.liveSession(for: sessionId) != nil
                      }),
                      let worktree = self.worktree(withId: worktreeId)
                else { return nil }
                return ACPOrchestrationSessionOrigin(
                    sessionId: sessionId,
                    projectId: worktree.projectId,
                    worktreeId: worktree.id
                )
            },
            originatingWorktree: { [weak self] worktreeId in
                self?.worktree(withId: worktreeId)
            },
            visibleWorktrees: { [weak self] in
                guard let self else { return [] }
                return self.projects.flatMap { project in
                    self.projectsManager.visibleWorktrees(projectId: project.id)
                }
            },
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
            createWorktree: { [weak self] origin, branch, base in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliCreateWorktree(origin: origin, branch: branch, base: base)
            },
            deleteWorktree: { [weak self] worktree, force, keepBranch in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliDeleteWorktree(worktree, force: force, keepBranch: keepBranch)
            },
            openReviewChanges: { [weak self] worktree in
                guard let self else { return }
                self.focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
                _ = self.openReviewChangesTab(for: worktree)
            },
            openReview: { [weak self] worktree, target in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliOpenReview(worktree: worktree, target: target)
            },
            providerReviewOriginalPath: { [weak self] sessionID, relativePath in
                await self?.reviewRequestOriginalPath(forDraftSessionID: sessionID, relativePath: relativePath) ?? nil
            },
            notifySession: { [weak self] sessionId, origin, body, title, level in
                guard let self else { return .error("Alas is not available.") }
                return self.cliNotify(
                    sessionId: sessionId,
                    origin: origin,
                    body: body,
                    title: title,
                    level: level
                )
            },
            listDelegatedSessions: { origin in
                await orchestration.list(origin: origin)
            },
            createDelegatedSession: { origin, request in
                await orchestration.create(origin: origin, request: request)
            },
            sendDelegatedSessionMessage: { origin, request in
                await orchestration.send(origin: origin, request: request)
            },
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }

    private func cliNotify(
        sessionId: String?,
        origin: Worktree,
        body: String,
        title: String?,
        level: AlasCLINotifyLevel
    ) -> AlasCLIResponse {
        guard let resolved = projectAndWorktree(withWorktreeId: origin.id) else {
            return .error("Unknown worktree.")
        }
        let notificationSessionId = sessionId ?? origin.id
        let agent = agentKindForNotifySession(sessionId) ?? .codex
        harness.notifications.notifyAlas(
            body: body,
            title: title,
            agent: agent,
            projectId: resolved.project.id,
            worktreeId: resolved.worktree.id,
            sessionId: notificationSessionId
        )
        if level == .attention, let sessionId {
            harness.setExternalActivity(sessionId: sessionId, agent: agent, state: .awaitingInput)
        }
        return .ok
    }

    private func agentKindForNotifySession(_ sessionId: String?) -> AgentKind? {
        guard let sessionId else { return nil }
        if let activity = harness.activityBySession[sessionId] {
            return activity.agent
        }
        if let harnessKind = harness.activeHarnessBySession[sessionId] ?? harness.harnessBySession[sessionId] {
            return harnessKind.asAgentKind
        }
        for manager in acpManagers.values {
            if let session = manager.liveSession(for: sessionId) {
                return ACPHarnessBridge.agentKind(for: session.agentId)
            }
        }
        return nil
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
            tabs.activate(worktreeId: worktreeId, tabId: tabId)
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
        runScriptKey: String? = nil
    ) async throws -> Tab {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw NSError(domain: "AppState", code: 2)
        }
        await prepareRemoteAccelerationIfNeeded(for: project)
        return try openTerminalTab(
            for: worktree,
            startupScriptSuffix: startupScriptSuffix,
            includeUserStartupScript: includeUserStartupScript,
            forceInheritParentEnv: forceInheritParentEnv,
            environmentOverrides: environmentOverrides,
            environmentRemovals: environmentRemovals,
            titleOverride: titleOverride,
            runScriptKey: runScriptKey
        )
    }

    @discardableResult
    func openTerminalTab(
        for worktree: Worktree,
        startupScriptSuffix: String? = nil,
        includeUserStartupScript: Bool = true,
        forceInheritParentEnv: Bool = false,
        environmentOverrides: [String: String] = [:],
        environmentRemovals: Set<String> = [],
        titleOverride: String? = nil,
        runScriptKey: String? = nil
    ) throws -> Tab {
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
        return tabs.appendTerminal(worktreeId: worktree.id, title: title, sessionId: opened.id, runScriptKey: runScriptKey)
    }

    private func prepareRemoteAccelerationIfNeeded(for project: ProjectConfig) async {
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

        let defaults = UserDefaults.standard
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
            // Single identity for the new pane: used with the worktree id to
            // derive the zmx session name, plus the SessionRegistry key, leaf
            // id, persisted sessionId, and ALAS_SESSION_ID.
            // Generated here so the registry key `terminal.openSession`
            // registers under matches the `newLeafId` the split tree stores.
            let newLeafId = UUID().uuidString
            let session = try terminal.openSession(
                worktree: worktree, project: project,
                cfg: config.terminal, theme: themeStore.current,
                forcedCwd: cwd,
                leafId: newLeafId
            )
            harness.detector.register(sessionId: session.id) { [weak session] in
                session?.surface.foregroundPid
            }
            _ = tabs.splitFocusedLeaf(
                worktreeId: worktreeId, tabId: activeId, axis: axis,
                newLeafId: newLeafId, newSessionId: newLeafId
            )
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
    func handleTerminalProcessExited(worktreeId: String, leafId: String, processAlive: Bool) {
        guard !processAlive else { return }
        let authExitHandler = acpAuthTerminalExitHandlers.removeValue(forKey: leafId)
        closePaneForProcessExit(worktreeId: worktreeId, leafId: leafId)
        authExitHandler?()
    }

    func closePaneForProcessExit(worktreeId: String, leafId: String) {
        let owningTabId = tabs.tabs(forWorktree: worktreeId).first { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.root.find(leafId: leafId) != nil
        }?.id
        guard let tabId = owningTabId else { return }
        guard let outcome = tabs.removeLeaf(
            worktreeId: worktreeId, tabId: tabId, leafId: leafId
        ) else { return }
        switch outcome {
        case .tabRemoved:
            closeTab(worktreeId: worktreeId, tabId: tabId)
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
    func closeFocusedPane(worktreeId: String) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal = tab else { return }
        guard let outcome = tabs.removeFocusedLeaf(worktreeId: worktreeId, tabId: activeId) else { return }
        if case .tabRemoved = outcome {
            requestCloseTab(worktreeId: worktreeId, tabId: activeId)
        } else {
            let closedLeafId = outcome.closedLeafId
            closeTerminalSession(
                id: closedLeafId,
                worktreeId: worktreeId,
                projectPath: projectPath(forWorktreeId: worktreeId)
            )
        }
    }

    /// "Terminate All Terminal Sessions" menu action. Confirms with the user,
    /// then closes every terminal tab across every worktree (which kills
    /// the underlying zmx session) and sweeps any persisted-but-not-yet-
    /// restored leaves this instance owns.
    @discardableResult
    func terminateAllTerminalSessions() -> Bool {
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
        let persistedSessions = allPersistedTerminalSessions()
        // Count individual leaves, not tabs — a single tab with split panes
        // contains multiple leaves and `terminateAll` kills every one. Union
        // with the live registry catches any session not yet flushed to disk.
        let sessionCount = Set(persistedSessions)
            .union(terminal.registry.all.map {
                TerminalSessionIdentity(worktreeId: $0.worktreeId, leafId: $0.id)
            })
            .count

        let alert = NSAlert()
        alert.messageText = "Terminate All Terminal Sessions"
        alert.informativeText = "Terminate \(sessionCount) terminal session(s)? This will kill any agent or process currently running in them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        for (worktreeId, tabId) in terminalTabs {
            closeTab(worktreeId: worktreeId, tabId: tabId)
        }
        // Also kill persisted leaves whose tab the user never displayed
        // this run — closeTab only handles registered sessions, but we
        // own those persisted leaves too. Scoped to OUR instance's known
        // leaves so we don't trample sessions owned by a concurrently-
        // running Alas process under the same ZMX_DIR.
        terminal.terminateAll(additionalSessions: persistedSessions)
        return true
    }

    /// All terminal sessions persisted under this Alas instance's projects.
    private func allPersistedTerminalSessions() -> [TerminalSessionIdentity] {
        projects.flatMap { project in
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

    /// ⌘W router: if the active tab is a multi-pane terminal, close the focused
    /// pane; otherwise fall through to the existing tab-close behavior.
    func handleCloseShortcut(worktreeId: String) {
        if let activeId = tabs.activeTabId(forWorktree: worktreeId),
           let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
           case .terminal(let state) = tab,
           case .split = state.root {
            closeFocusedPane(worktreeId: worktreeId)
            return
        }
        if let activeId = tabs.activeTabId(forWorktree: worktreeId) {
            requestCloseTab(worktreeId: worktreeId, tabId: activeId)
        }
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
    func restoreTerminalTabIfNeeded(worktreeId: String, tabId: TabID) throws -> Tab? {
        try restoreTerminalTabIfNeeded(
            worktreeId: worktreeId,
            tabId: tabId,
            legacySessionInfos: nil
        )
    }

    @discardableResult
    func restoreTerminalTabIfNeededAsync(worktreeId: String, tabId: TabID) async throws -> Tab? {
        let legacySessionInfos = await legacySessionInfosForTerminalRestore(
            worktreeId: worktreeId,
            tabId: tabId
        )
        return try restoreTerminalTabIfNeeded(
            worktreeId: worktreeId,
            tabId: tabId,
            legacySessionInfos: legacySessionInfos
        )
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
    ) throws -> Tab? {
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

        for leaf in state.root.leaves() {
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
            if state.runScriptLeafId == leaf.id {
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
                leafId: leaf.id,
                allowLegacyAttach: allowLegacyAttach,
                preResolvedZmxSessionName: preResolvedZmxSessionName
            )
            harness.detector.register(sessionId: session.id) { [weak session] in
                session?.surface.foregroundPid
            }
        }
        return tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId })
    }

    func saveActiveTab(worktreeId: String) {
        Task {
            _ = await tabs.saveActiveAsync(worktreeId: worktreeId, config: config.code)
        }
    }

    func saveAllTabs() {
        Task { @MainActor in
            var roots: [String: URL] = [:]
            for project in projects {
                for worktree in projectsManager.worktrees(projectId: project.id) {
                    roots[worktree.id] = roots[worktree.id] ?? worktree.path
                }
            }
            let errors = await tabs.saveAllAwaitingRemote(worktreeRoots: roots)
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
                do {
                    try await Self.createRemoteEmptyFile(host: host, worktreeRoot: worktree.path, relativePath: relativePath)
                    self?.openFile(relativePath: relativePath, worktreeId: worktreeId)
                } catch {
                    self?.showFileActionError(title: "New File Failed", message: error.localizedDescription)
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

        do {
            let relativePath = try relativePath(for: url, in: worktree.path)
            if FileManager.default.fileExists(atPath: url.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
            openFile(relativePath: relativePath, worktreeId: worktreeId)
        } catch {
            showFileActionError(title: "New File Failed", message: error.localizedDescription)
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

    func saveActiveTabAs(worktreeId: String) {
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
                    try await context.buffer.saveAsRemote(relativePath: relativePath)
                    _ = self?.tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
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

        do {
            let relativePath = try relativePath(for: url, in: worktree.path)
            guard !tabs.hasEditor(worktreeId: worktreeId, relativePath: relativePath, excluding: context.tab.id) else {
                showFileActionError(title: "Save As Failed", message: "That file is already open in another editor tab.")
                return
            }
            try context.buffer.saveAs(relativePath: relativePath)
            _ = tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
        } catch {
            showFileActionError(title: "Save As Failed", message: error.localizedDescription)
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
                do {
                    try await context.buffer.moveToRemote(relativePath: relativePath)
                    _ = self?.tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
                } catch {
                    self?.showFileActionError(title: "Rename File Failed", message: error.localizedDescription)
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

        do {
            let relativePath = try relativePath(for: url, in: worktree.path)
            guard relativePath != context.tab.relativePath else { return }
            try context.buffer.moveTo(relativePath: relativePath)
            _ = tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
        } catch {
            showFileActionError(title: "Rename File Failed", message: error.localizedDescription)
        }
    }

    func renameTerminalTab(worktreeId: String, tabId: TabID) {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Terminal"
        alert.informativeText = "Choose a stable name for this terminal tab."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = state.title
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = tabs.renameTerminal(worktreeId: worktreeId, tabId: tabId, title: field.stringValue)
        tabs.clearTerminalRuntimeTitles(forLeavesInTabId: tabId)
    }

    func renameACPSessionTab(worktreeId: String, tabId: TabID) {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .acpSession(let state) = tab,
              let worktree = worktree(withId: worktreeId),
              let mgr = acpManager(for: worktree) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Choose a name for this ACP session."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = state.title
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }
        mgr.renameSession(id: state.sessionId, title: newTitle, source: .manual)
        _ = tabs.renameACPSession(worktreeId: worktreeId, tabId: tabId, title: newTitle)
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

    /// Save the active ACP session's conversation to a `.md` file via a
    /// save panel. Cancel is a no-op; write failures surface through the
    /// shared file-action error handler.
    func exportACPSessionMarkdown(worktreeId: String, tabId: TabID) {
        Task { @MainActor in
            await withHydratedACPSession(worktreeId: worktreeId, tabId: tabId) { session in
                let markdown = ACPTranscriptMarkdown.document(
                    title: session.title,
                    agentName: agent(id: session.agentId)?.displayName,
                    messages: session.transcript.messages
                )
                let panel = NSSavePanel()
                panel.title = "Save Session as Markdown"
                panel.message = "Choose where to save this conversation."
                panel.nameFieldStringValue = ACPTranscriptMarkdown.sanitizedFilename(title: session.title)
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    showFileActionError(title: "Export Failed", message: error.localizedDescription)
                }
            }
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

    func closeTab(worktreeId: String, tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let projectPath = projectPath(forWorktreeId: worktreeId)
        if let tab = allTabs.first(where: { $0.id == tabId }) {
            if case .terminal(let s) = tab {
                for leaf in s.root.leaves() {
                    closeTerminalSession(id: leaf.id, worktreeId: worktreeId, projectPath: projectPath)
                }
            }
            if case .editor = tab {
                tabs.discardBuffer(worktreeId: worktreeId, tabId: tabId)
            }
            if case .acpSession(let s) = tab {
                cleanupACPSession(worktreeId: worktreeId, sessionId: s.sessionId)
            }
        }
        tabs.close(worktreeId: worktreeId, tabId: tabId)
    }

    func requestCloseTab(worktreeId: String, tabId: TabID) {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }) else { return }
        if let prompt = CloseTabConfirmationPolicy.prompt(for: tab, config: config),
           !confirmCloseTab(prompt) {
            return
        }
        closeTab(worktreeId: worktreeId, tabId: tabId)
    }

    private func confirmCloseTab(_ prompt: CloseTabConfirmationPolicy.Prompt) -> Bool {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
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
                    closeTerminalSession(id: leaf.id, worktreeId: worktreeId, projectPath: projectPath)
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

    /// Detach a single ACP session's runner and remove it from the
    /// worktree's manager. Different from `disposeACPManager`, which
    /// tears down the whole worktree's manager — this leaves the
    /// manager (and any sibling sessions) running.
    private func cleanupACPSession(worktreeId: String, sessionId: String) {
        guard let manager = acpManagers[worktreeId] else { return }
        // Flush any in-flight debounced draft write for this session
        // before the tab goes away. The manager itself stays alive
        // (other tabs may share it), so the global flush from
        // disposeACPManager wouldn't fire here.
        manager.flushPendingDraftWrite(forSession: sessionId)
        // Call detach unconditionally — a session can hold a writer lease
        // + heartbeat + writer-watch before its runner is registered (the
        // "attach window"). If we returned early when no runner was present,
        // closing the tab during that window would leak all of those
        // resources. detach is idempotent: releaseWriterLease is owner-
        // scoped, and endMirroring / stopHeartbeat / stopWriterWatch are
        // all no-ops when not active.
        if let runner = manager.runners[sessionId] {
            runner.stop()
        }
        Task { @MainActor in
            await manager.detach(sessionId: sessionId)
        }
    }

    func closeOtherTabs(worktreeId: String, keeping tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeOthers(worktreeId: worktreeId, keeping: tabId)
        cleanupTerminals(worktreeId: worktreeId, allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        cleanupACPSessions(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    /// Tear down every tab/terminal/harness reference for a worktree id without
    /// touching git or persistence. Shared between Close-All, archive, and
    /// delete so the bookkeeping stays in one place.
    private func cleanupWorktreeState(worktreeId: String) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeAll(worktreeId: worktreeId)
        cleanupTerminals(worktreeId: worktreeId, allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        disposeACPManager(for: worktreeId)
    }

    func closeAllTabs(worktreeId: String) {
        cleanupWorktreeState(worktreeId: worktreeId)
    }

    func closeTabsToLeft(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToLeft(worktreeId: worktreeId, of: tabId)
        cleanupTerminals(worktreeId: worktreeId, allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        cleanupACPSessions(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    func closeTabsToRight(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToRight(worktreeId: worktreeId, of: tabId)
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

    func worktree(withId id: String) -> Worktree? {
        for project in projects {
            if let worktree = projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return worktree
            }
        }
        return nil
    }

    private func worktree(atPersistedDestinationPath path: String?) -> Worktree? {
        guard let path, !path.isEmpty else { return nil }
        let targetPath = URL(fileURLWithPath: path).standardizedFileURL.path
        for project in projects {
            if let worktree = projectsManager.worktrees(projectId: project.id).first(where: {
                $0.path.standardizedFileURL.path == targetPath
            }) {
                return worktree
            }
        }
        return nil
    }

    private func projectAndWorktree(withWorktreeId id: String) -> (project: ProjectConfig, worktree: Worktree)? {
        for project in projects {
            if let worktree = projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return (project, worktree)
            }
        }
        return nil
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

    private func acpInputNotificationBody(from request: ACPUserInputRequest) -> String? {
        switch request.source {
        case .cursor(_, let params):
            return acpQuestionNotificationBody(from: params)
        case .elicitation:
            let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { return title }
            let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }
    }

    private func notificationRequestId(for request: ACPUserInputRequest) -> String {
        switch request.source {
        case .cursor(let id, _), .elicitation(let id, _):
            return notificationRequestId(for: id)
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
        return !MarkdownFileType.isMarkdown(relativePath: path)
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
                                displayName: wt.branch,
                                absolutePath: wt.path
                            ))
                        }
                    }
                    return out
                }
            },
            entries: { [fileIndex] wt in
                try await fileIndex.entries(forWorktreePath: wt.absolutePath)
            },
            statuses: { [statusCache] wt in
                try await statusCache.statuses(forWorktreePath: wt.absolutePath)
            },
            fileSearch: { query, wt in
                try await fileSearchBackend.search(query: query, worktree: wt, limit: 50)
            },
            rankFiles: { query, sources in
                try await fileSearchRanker.rank(query: query, sources: sources)
            },
            contentSearch: { [contentSearcher = ContentSearcher()] query, options, targets in
                contentSearcher.search(query: query, options: options, worktrees: targets)
            }
        )
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

    func revealInFiles(worktreeId: String, path: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        config.rightPaneVisible = true
        _ = saveConfig()
        let rps = rightPaneStore.state(
            for: worktree,
            baseBranch: config.worktrees.baseBranch,
            comparisonMode: config.changes.comparisonMode
        )
        rps.reveal(path: path)
    }

    /// Open a markdown relative-link target as a new editor tab in the same worktree.
    /// Delegates to `openFile` which handles find-or-create, activate, and
    /// worktree-switch if necessary.
    func openMarkdownLink(worktreeId: String, worktreeRoot: URL, relativePath: String) {
        openFile(relativePath: relativePath, worktreeId: worktreeId)
    }

    /// Route a clicked markdown link from an ACP transcript. Local file links
    /// inside the session worktree open in Alas editor tabs; everything else
    /// returns false so SwiftUI can continue with the default URL action.
    func routeTranscriptOpenURL(_ url: URL, worktreeId: String) -> Bool {
        guard let worktree = worktree(withId: worktreeId) else { return false }

        let rawPath: String
        if url.isFileURL {
            rawPath = url.path
        } else if url.scheme == nil {
            rawPath = url.path.removingPercentEncoding ?? url.path
        } else if !url.absoluteString.contains("://") {
            rawPath = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        } else {
            return false
        }
        guard !rawPath.isEmpty else { return false }

        if attemptOpenLocalFilePath(rawPath, worktree: worktree, baseDirectory: worktree.path) {
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        // Trailing-period fallback: transcript prose can include sentence
        // punctuation in a markdown link destination.
        if rawPath.hasSuffix(".") {
            let trimmed = String(rawPath.dropLast())
            if !trimmed.isEmpty,
               attemptOpenLocalFilePath(trimmed, worktree: worktree, baseDirectory: worktree.path) {
                NSApp.activate(ignoringOtherApps: true)
                return true
            }
        }

        return false
    }

    /// Route a cmd-clicked URL from a Ghostty terminal surface. Mirrors `alas
    /// open` for files inside the session's worktree (resolving relatives
    /// against the shell cwd first, then falling back to the worktree root),
    /// and returns false for anything else so the caller can fall back to
    /// `NSWorkspace.shared.open`.
    func routeTerminalOpenURL(rawURL: String, sessionId: String) -> Bool {
        guard let session = terminal.registry.session(for: sessionId),
              let worktree = worktree(withId: session.worktreeId) else { return false }

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
        let target: LocalFileOpenTarget
        let resolved = resolveLocalFilePath(candidatePath, worktree: worktree, baseDirectory: baseDirectory)
        if FileManager.default.fileExists(atPath: resolved.path) {
            target = LocalFileOpenTarget(url: resolved, revealLine: nil, revealCharacter: nil)
        } else if let parsed = Self.parseLocalPathPosition(candidatePath) {
            let resolvedParsed = resolveLocalFilePath(parsed.path, worktree: worktree, baseDirectory: baseDirectory)
            target = LocalFileOpenTarget(
                url: resolvedParsed,
                revealLine: parsed.line - 1,
                revealCharacter: (parsed.column ?? 1) - 1
            )
        } else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }

        // Resolve symlinks on both sides before the containment check so that
        // an in-tree symlink pointing outside the worktree (e.g.
        // `worktree/escape -> /elsewhere`) doesn't get routed to the editor.
        let resolvedTarget = target.url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = worktree.path.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = resolvedRoot.pathComponents
        let targetComponents = resolvedTarget.pathComponents
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            return false
        }
        let relativePath = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        guard !relativePath.isEmpty else { return false }

        openFile(
            relativePath: relativePath,
            worktreeId: worktree.id,
            revealLine: target.revealLine,
            revealCharacter: target.revealCharacter
        )
        return true
    }

    private func resolveLocalFilePath(
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

    private static func showWarningAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Delete a worktree from disk. Shows a confirm dialog; on dirty-tree
    /// failure sets `pendingForceDeleteWorktree` so SwiftUI can present a
    /// state-driven confirmation. Cleans up in-app state on success.
    func deleteWorktree(_ worktree: Worktree, keepBranch: Bool = false) {
        let dirty = dirtyEditorTabIds(worktreeId: worktree.id)
        let saveBuffersFirst: Bool
        if dirty.isEmpty {
            saveBuffersFirst = false
        } else {
            switch promptForDirtyBuffers(
                action: "Delete",
                branch: worktree.branch,
                dirtyCount: dirty.count,
                onDiskDestructive: true,
                keepBranch: keepBranch
            ) {
            case .save: saveBuffersFirst = true
            case .discard: saveBuffersFirst = false
            case .cancel: return
            }
        }
        if saveBuffersFirst {
            Task { @MainActor in
                guard await saveDirtyBuffers(in: worktree) else { return }
                beginDeleteWorktree(worktree, keepBranch: keepBranch)
            }
            return
        }
        beginDeleteWorktree(worktree, keepBranch: keepBranch)
    }

    private func beginDeleteWorktree(_ worktree: Worktree, keepBranch: Bool) {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            showFileActionError(title: "Delete Failed", message: "Could not find the project for this worktree.")
            return
        }
        let repoPath = URL(fileURLWithPath: project.path)
        let deleteBranch = Self.resolveDeleteBranchIfMerged(
            globalDeleteOnRemove: config.worktrees.deleteBranchOnRemove,
            keepBranch: keepBranch
        )

        let siblingsBefore = projectsManager.visibleWorktrees(projectId: worktree.projectId)
        let removedIndex = siblingsBefore.firstIndex(where: { $0.id == worktree.id }) ?? 0

        Task { @MainActor in
            let preflight = await Self.performDeletePreflight(worktreePath: worktree.path)
            let confirmation = Self.deleteConfirmation(
                branch: worktree.branch,
                keepBranch: keepBranch,
                preflight: preflight
            )
            guard let decision = Self.resolveDeleteDecision(
                branch: worktree.branch,
                keepBranch: keepBranch,
                preflight: preflight,
                userConfirmed: confirmDeleteWorktree(confirmation)
            ) else { return }

            projectsManager.setOperationState(id: worktree.id, state: .deleting)
            await performDeleteWorktree(
                worktree: worktree,
                repoPath: repoPath,
                deleteBranchIfMerged: deleteBranch,
                force: decision.force,
                removedIndex: removedIndex
            )
        }
    }

    @MainActor
    func cliDeleteWorktree(_ worktree: Worktree, force: Bool, keepBranch: Bool) async -> AlasCLIResponse {
        if pendingForceDeleteWorktree?.id == worktree.id {
            pendingForceDeleteWorktree = nil
        }
        if projectsManager.operationState(for: worktree.id) == .deleting {
            return .ok
        }
        let dirty = dirtyEditorTabIds(worktreeId: worktree.id)
        if !dirty.isEmpty && !force {
            return .error("worktree has unsaved editor changes; save them or rerun with --force to delete")
        }
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            return .error("Could not find the project for this worktree.")
        }
        if !force {
            let preflight = await Self.performDeletePreflight(worktreePath: worktree.path)
            if preflight.requiresForce {
                if preflight.reasons.contains(.dirty) {
                    return .error("worktree has local changes; rerun with --force to delete")
                }
                if preflight.reasons.contains(.containsInitializedSubmodules) {
                    return .error("worktree contains initialized submodules; rerun with --force to delete")
                }
                return .error("worktree requires force delete; rerun with --force to delete")
            }
        }

        let repoPath = URL(fileURLWithPath: project.path)
        let deleteBranch = Self.resolveDeleteBranchIfMerged(
            globalDeleteOnRemove: config.worktrees.deleteBranchOnRemove,
            keepBranch: keepBranch
        )
        let siblingsBefore = projectsManager.visibleWorktrees(projectId: worktree.projectId)
        let removedIndex = siblingsBefore.firstIndex(where: { $0.id == worktree.id }) ?? 0
        projectsManager.setOperationState(id: worktree.id, state: .deleting)
        Task { @MainActor in
            await performDeleteWorktree(
                worktree: worktree,
                repoPath: repoPath,
                deleteBranchIfMerged: deleteBranch,
                force: force,
                removedIndex: removedIndex
            )
            if pendingForceDeleteWorktree?.id == worktree.id {
                pendingForceDeleteWorktree = nil
                projectsManager.setOperationState(
                    id: worktree.id,
                    state: .deleteFailed(message: "worktree requires force delete; rerun with --force to delete")
                )
            }
        }
        return .ok
    }

    @MainActor
    func cliOpenProviderReview(worktree: Worktree, target: String) async -> AlasCLIResponse {
        guard let parsed = AlasCLIReviewTargetResolver.parse(target) else {
            return .error("unsupported review URL")
        }

        do {
            let providerRegistry = CodeHostProviderRegistry.live()
            let supportedRemotes = try await cliSupportedRemotes(for: worktree, registry: providerRegistry)
            guard !supportedRemotes.isEmpty else {
                return .error("no code host remote found for this worktree")
            }

            let remote: CodeHostRemote
            let number: Int
            switch parsed {
            case .number(let value):
                remote = supportedRemotes[0]
                number = value
            case .url(let host, let repositorySlug, let value):
                guard let matchingRemote = supportedRemotes.first(where: {
                    $0.host == host && $0.repositorySlug.lowercased() == repositorySlug.lowercased()
                }) else {
                    return .error("review URL does not match this worktree's remote")
                }
                remote = matchingRemote
                number = value
            case .range, .revision:
                // Commit ranges and bare revisions are not routed through the
                // provider path; wiring lands in a follow-up task.
                return .error("commit ranges and revisions are not supported yet")
            }

            guard let provider = providerRegistry.provider(for: remote.kind) else {
                return .error("\(remote.kind.displayName) is not supported yet.")
            }
            let request = try await provider.reviewRequest(remote: remote, number: number, cwd: worktree.path)
            let reviewTarget = ReviewSessionTarget.reviewRequest(
                worktreeID: worktree.id,
                repositoryPath: worktree.path,
                provider: request.provider,
                host: request.remote.host,
                repositorySlug: request.remote.repositorySlug,
                number: request.number,
                url: request.url,
                title: request.title,
                headSHA: request.headSHA
            )
            return openCLIReviewSession(worktree: worktree, target: reviewTarget, label: target)
        } catch {
            return .error(Self.describeCLIError(error))
        }
    }

    @MainActor
    func cliOpenReview(worktree: Worktree, target: String) async -> AlasCLIResponse {
        guard let parsed = AlasCLIReviewTargetResolver.parse(target) else {
            return .error(
                "unsupported review target '\(target)' — expected a PR/MR number or URL, "
                    + "a commit range (base..head or base...head), a branch, or a revision"
            )
        }
        switch parsed {
        case .number, .url:
            return await cliOpenProviderReview(worktree: worktree, target: target)
        case .range(let base, let head, let threeDot):
            return await cliOpenRangeReview(worktree: worktree, base: base, head: head, threeDot: threeDot)
        case .revision(let ref):
            return await cliOpenRevisionReview(worktree: worktree, ref: ref)
        }
    }

    @MainActor
    private func cliOpenRangeReview(
        worktree: Worktree,
        base: String,
        head: String,
        threeDot: Bool
    ) async -> AlasCLIResponse {
        let git = GitService()
        let baseSHA: String
        let headSHA: String
        do {
            // Three-dot ranges compute a real merge base downstream and have
            // no root-commit special case; two-dot ranges reuse the same
            // empty-tree fallback the range diff loaders already rely on
            // (`resolveTwoDotLeftTree`), so a root commit's "HEAD^..HEAD"
            // resolves instead of failing before the review ever opens.
            baseSHA = threeDot
                ? try await git.resolveRevision(at: worktree.path, ref: base)
                : try await git.resolveTwoDotLeftTree(worktreePath: worktree.path, base: base)
        } catch {
            return .error("could not resolve '\(base)' in worktree '\(worktree.branch)'")
        }
        do {
            headSHA = try await git.resolveRevision(at: worktree.path, ref: head)
        } catch {
            return .error("could not resolve '\(head)' in worktree '\(worktree.branch)'")
        }
        let title = "Review \(base)\(threeDot ? "..." : "..")\(head)"
        // Three-dot ranges diff from the merge base — exactly what the
        // `.branch` target's loader does; two-dot ranges are plain range
        // diffs via `.commitRange`.
        let reviewTarget: ReviewSessionTarget = threeDot
            ? .branch(worktreeID: worktree.id, repositoryPath: worktree.path, base: baseSHA, head: headSHA, title: title)
            : .commitRange(worktreeID: worktree.id, repositoryPath: worktree.path, base: baseSHA, head: headSHA, title: title)
        return openCLIReviewSession(worktree: worktree, target: reviewTarget, label: title)
    }

    @MainActor
    private func cliOpenRevisionReview(worktree: Worktree, ref: String) async -> AlasCLIResponse {
        let git = GitService()
        let localBranches = (try? await git.localBranches(at: worktree.path)) ?? []
        if localBranches.contains(ref) {
            // The named branch is the HEAD; the repository's configured base
            // branch is the BASE — this reviews "`ref`'s changes vs the
            // base". The palette's branch picker (ReviewScopeSelection
            // .target(for: .branch)) reviews the opposite direction ("my
            // current HEAD vs the picked branch"). Both are intentional for
            // their own entry point; do not "fix" one to match the other
            // without an explicit design decision — see
            // docs/superpowers/specs/2026-07-16-review-target-palette-design.md.
            //
            // Pinned to SHAs so the stored session survives branch movement.
            let baseName = config.worktrees.baseBranch
            do {
                let headSHA = try await git.resolveRevision(at: worktree.path, ref: ref)
                let baseSHA: String
                if let originSHA = try? await git.resolveRevision(at: worktree.path, ref: "origin/\(baseName)") {
                    baseSHA = originSHA
                } else {
                    baseSHA = try await git.resolveRevision(at: worktree.path, ref: baseName)
                }
                let title = "Review \(ref) against \(baseName)"
                let reviewTarget = ReviewSessionTarget.branch(
                    worktreeID: worktree.id,
                    repositoryPath: worktree.path,
                    base: baseSHA,
                    head: headSHA,
                    title: title
                )
                return openCLIReviewSession(worktree: worktree, target: reviewTarget, label: title)
            } catch {
                return .error("could not resolve base '\(baseName)' for branch '\(ref)'")
            }
        }
        guard let sha = try? await git.resolveRevision(at: worktree.path, ref: ref) else {
            return .error(
                "could not resolve review target '\(ref)' in worktree '\(worktree.branch)' "
                    + "(not a PR number/URL, local branch, or revision)"
            )
        }
        let short = String(sha.prefix(7))
        let reviewTarget = ReviewSessionTarget.commit(
            worktreeID: worktree.id,
            repositoryPath: worktree.path,
            sha: sha,
            title: "Review commit \(short)"
        )
        return openCLIReviewSession(worktree: worktree, target: reviewTarget, label: "commit \(short)")
    }

    @MainActor
    private func openCLIReviewSession(
        worktree: Worktree,
        target: ReviewSessionTarget,
        label: String
    ) -> AlasCLIResponse {
        let store = ReviewSessionStore()
        let opened = ReviewSessionLauncher.openOrFocus(
            target: target,
            findActive: { try store.findActive(targetID: $0) },
            save: { try store.save($0) },
            open: { [weak self] record in
                _ = self?.tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: record)
            }
        )
        guard opened else {
            return .error("could not open review session")
        }
        focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        NSApp.activate(ignoringOtherApps: true)
        return .text([
            "Opened review for '\(label)' in Alas.",
            AlasActionService.jsonLine(["session_id": target.draftSessionID.rawValue]),
        ])
    }

    /// Supported code-host remotes for `worktree`, ordered with the preferred
    /// remote (derived from the base branch) first. Shared by
    /// `cliOpenProviderReview` and the review-comment original-path resolver.
    private func cliSupportedRemotes(
        for worktree: Worktree,
        registry: CodeHostProviderRegistry
    ) async throws -> [CodeHostRemote] {
        let remotes = try await GitService().remotes(worktreePath: worktree.path)
        let baseBranch = rightPaneStore.state(
            for: worktree,
            baseBranch: config.worktrees.baseBranch,
            comparisonMode: config.changes.comparisonMode
        ).baseBranch
        let preferredRemoteName = CodeHostRemoteDetector.preferredRemoteName(
            forBaseBranch: baseBranch,
            remotes: remotes
        )
        return CodeHostRemoteDetector.detectAll(
            from: remotes,
            supportedKinds: registry.supportedKinds,
            preferredRemoteName: preferredRemoteName
        )
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
            let sessionStore = ReviewSessionStore()
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
            let supportedRemotes = try await cliSupportedRemotes(for: worktree, registry: registry)
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

    nonisolated private static func describeCLIError(_ error: any Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }

    /// Runs the git removal off the main actor, then resumes on MainActor
    /// for state cleanup. On dirty-worktree failure publishes
    /// `pendingForceDeleteWorktree` instead of showing a blocking modal.
    private func performDeleteWorktree(
        worktree: Worktree,
        repoPath: URL,
        deleteBranchIfMerged: Bool,
        force: Bool,
        removedIndex: Int
    ) async {
        do {
            try await Self.performRemoveWorktree(
                repoPath: repoPath,
                worktree: worktree,
                deleteBranchIfMerged: deleteBranchIfMerged,
                force: force
            )
        } catch let WorktreeService.WorktreeError.gitFailed(stderr) {
            if !force,
               let pending = Self.pendingForceDelete(
                    for: worktree,
                    repoPath: repoPath,
                    deleteBranchIfMerged: deleteBranchIfMerged,
                    removedIndex: removedIndex,
                    stderr: stderr
               ) {
                // Clear deleting so the user can see the row again while deciding.
                projectsManager.setOperationState(id: worktree.id, state: nil)
                pendingForceDeleteWorktree = pending
                return
            } else {
                projectsManager.setOperationState(
                    id: worktree.id,
                    state: .deleteFailed(message: stderr)
                )
                return
            }
        } catch {
            projectsManager.setOperationState(
                id: worktree.id,
                state: .deleteFailed(message: "\(error)")
            )
            return
        }

        cleanupWorktreeState(worktreeId: worktree.id)
        // Always clear the deleting state after a successful remove,
        // even if the subsequent refresh fails.
        projectsManager.setOperationState(id: worktree.id, state: nil)
        removePersistedGGWorktreeMode(
            projectId: worktree.projectId,
            worktreeId: worktree.id
        )
        _ = try? await refreshProjectWorktrees(projectId: worktree.projectId)
        if selectedWorktreeId == worktree.id {
            selectWorktree(id: selectionAfterRemoval(
                removedFromProjectId: worktree.projectId,
                removedAtIndex: removedIndex
            ))
        }
    }

    /// Called from the SwiftUI alert when the user confirms force delete.
    func confirmForceDeletePendingWorktree() {
        guard let pending = pendingForceDeleteWorktree else { return }
        pendingForceDeleteWorktree = nil

        guard let project = projects.first(where: { $0.id == pending.projectId }),
              projectsManager.worktrees(projectId: pending.projectId).contains(where: { $0.id == pending.id })
        else { return }

        let worktree = Worktree(
            id: pending.id,
            projectId: pending.projectId,
            name: pending.branch,
            branch: pending.branch,
            path: pending.worktreePath,
            status: .clean,
            lastActivity: Date()
        )

        projectsManager.setOperationState(id: pending.id, state: .deleting)

        Task { @MainActor in
            await performDeleteWorktree(
                worktree: worktree,
                repoPath: pending.repoPath,
                deleteBranchIfMerged: pending.deleteBranchIfMerged,
                force: true,
                removedIndex: pending.removedIndex
            )
        }
    }

    /// Called from the SwiftUI alert when the user cancels force delete.
    func cancelForceDeletePendingWorktree() {
        pendingForceDeleteWorktree = nil
    }

    nonisolated private static func performRemoveWorktree(
        repoPath: URL,
        worktree: Worktree,
        deleteBranchIfMerged: Bool,
        force: Bool
    ) async throws {
        try await Task.detached {
            try await WorktreeService().remove(
                repoPath: repoPath,
                worktree: worktree,
                deleteBranchIfMerged: deleteBranchIfMerged,
                force: force
            )
        }.value
    }

    nonisolated private static func performDeletePreflight(worktreePath: URL) async -> WorktreeDeletePreflight {
        do {
            return try await Task.detached {
                try await WorktreeService().deletePreflight(worktreePath: worktreePath)
            }.value
        } catch {
            return WorktreeDeletePreflight(reasons: [], submoduleLocalState: .unknown)
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
        keepBranch: Bool,
        preflight: WorktreeDeletePreflight
    ) -> WorktreeDeleteConfirmation {
        var messageParts = [
            keepBranch
                ? "This removes its files from disk. The local branch will be kept."
                : "This removes its files from disk. The local branch will be deleted if merged."
        ]

        if preflight.reasons.contains(.dirty) {
            messageParts.append("This worktree has modified or untracked files. Force delete will permanently remove them from disk.")
        }
        let containsInitializedSubmodules = preflight.reasons.contains(.containsInitializedSubmodules)
        if containsInitializedSubmodules {
            messageParts.append("This worktree contains initialized submodules. Git requires force delete to remove it.")
        }

        if containsInitializedSubmodules {
            switch preflight.submoduleLocalState {
            case .none:
                break
            case .present:
                messageParts.append("Preflight found local-only submodule state that may only exist inside this worktree.")
            case .unknown:
                messageParts.append("Alas could not verify whether the initialized submodules contain local-only state.")
            }
        }

        return WorktreeDeleteConfirmation(
            title: "Delete worktree '\(branch)'?",
            message: messageParts.joined(separator: " "),
            buttonTitle: preflight.requiresForce ? "Force Delete" : "Delete",
            force: preflight.requiresForce
        )
    }

    nonisolated static func resolveDeleteDecision(
        branch: String,
        keepBranch: Bool,
        preflight: WorktreeDeletePreflight,
        userConfirmed: Bool
    ) -> WorktreeDeleteDecision? {
        guard userConfirmed else { return nil }
        let confirmation = deleteConfirmation(
            branch: branch,
            keepBranch: keepBranch,
            preflight: preflight
        )
        return WorktreeDeleteDecision(
            confirmation: confirmation,
            force: confirmation.force
        )
    }

    nonisolated static func pendingForceDelete(
        for worktree: Worktree,
        repoPath: URL,
        deleteBranchIfMerged: Bool,
        removedIndex: Int,
        stderr: String
    ) -> PendingForceDeleteWorktree? {
        guard let reason = forceDeleteReason(for: stderr) else { return nil }
        return PendingForceDeleteWorktree(
            id: worktree.id,
            branch: worktree.branch,
            projectId: worktree.projectId,
            repoPath: repoPath,
            worktreePath: worktree.path,
            deleteBranchIfMerged: deleteBranchIfMerged,
            removedIndex: removedIndex,
            reason: reason
        )
    }

    /// Permissive substring check: git's exact wording around dirty/submodule
    /// worktrees varies by version. If the match misses, the caller surfaces
    /// the raw stderr instead, which is acceptable degradation.
    nonisolated static func forceDeleteReason(for stderr: String) -> ForceDeleteReason? {
        let s = stderr.lowercased()
        if s.contains("working trees containing submodules")
            || (s.contains("containing submodules") && s.contains("cannot be moved or removed")) {
            return .containsSubmodules
        }

        if s.contains("is dirty")
            || s.contains("dirty worktree")
            || s.contains("contains modified or untracked files")
            || s.contains("modified or untracked") {
            return .dirty
        }

        return nil
    }

    private func confirmDeleteWorktree(_ confirmation: WorktreeDeleteConfirmation) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: confirmation.buttonTitle)
        alert.addButton(withTitle: "Cancel")
        deleteButton.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private enum DirtyBufferChoice {
        case save
        case discard
        case cancel
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

    /// Per-worktree ACP session managers, lazily created on first access.
    @ObservationIgnored
    private var acpManagers: [String: ACPSessionManager] = [:]

    @ObservationIgnored
    private let acpOrchestrationPersistence = ACPOrchestrationPersistence()

    @ObservationIgnored
    private var delegatedSessionParents: [String: String] = [:]

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
    private lazy var acpHarnessBridge = ACPHarnessBridge(harness: harness)

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
        acpManagers[id]
    }

    /// Returns (or lazily creates) the ACP session manager for the given worktree.
    /// Store opening and migration happen lazily on the persistence actor.
    func acpManager(for worktree: Worktree) -> ACPSessionManager? {
        if let existing = acpManagers[worktree.id] { return existing }
        let dbURL = Paths.acpSessionsDB(forWorktreeId: worktree.id)
        let persistence = ACPSessionPersistence(path: dbURL.path)
        let mgr = ACPSessionManager(
            worktreeId: worktree.id,
            worktreePath: worktree.path.path,
            persistence: persistence,
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
            onDelegatedMessageAvailable: { [weak self] sessionId in
                Task { @MainActor [weak self] in
                    guard let self, let manager = self.acpManagers[worktree.id] else { return }
                    await self.deliverPendingDelegatedMessages(to: sessionId, manager: manager)
                }
            },
            brokerServiceFactory: {
                let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
                return try await LocalACPBrokerServicePool.shared.service(resourceURL: resourceURL)
            },
            mcpProjectContextProvider: { [weak self] in
                guard let project = self?.projects.first(where: { $0.id == worktree.projectId }) else {
                    return nil
                }
                return MCPProjectContext(
                    projectDirectory: project.path,
                    configuredServers: project.mcpServers
                )
            },
            builtInMCPProvider: { [weak self] worktreePath, sessionId, adapterSupportsHTTP in
                guard let self else { return nil }
                // installExecutables is idempotent (byte-compares before
                // writing); a nil binaryPath (no bundle, e.g. tests) means
                // no injection rather than a dead command for the agent.
                let binaryPath = (try? TerminalCLIInjection.installExecutables())?
                    .appendingPathComponent(TerminalCLIInjection.executableName).path
                let persistedParent = try? await self.acpOrchestrationPersistence.parent(
                    childSessionId: sessionId
                )
                let parentSessionId = self.delegatedSessionParents[sessionId]
                    ?? persistedParent?.parentSessionId
                if let parentSessionId {
                    self.delegatedSessionParents[sessionId] = parentSessionId
                }
                let configuredServers = self.projects.first(where: { $0.id == worktree.projectId })?.mcpServers ?? []
                if self.config.harness.alasMCPTransport == .http,
                   adapterSupportsHTTP,
                   let binaryPath, let socketPath = self.harness.socketServer.socketPath,
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
                        return BuiltInAlasMCP.injection(
                            enabled: self.config.harness.exposeAlasMCP,
                            configuredServers: configuredServers,
                            binaryPath: binaryPath,
                            socketPath: self.harness.socketServer.socketPath,
                            worktreePath: worktreePath,
                            sessionId: sessionId,
                            parentSessionId: parentSessionId,
                            httpEndpoint: endpoint
                        )
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
                return BuiltInAlasMCP.injection(
                    enabled: self.config.harness.exposeAlasMCP,
                    configuredServers: configuredServers,
                    binaryPath: binaryPath,
                    socketPath: self.harness.socketServer.socketPath,
                    worktreePath: worktreePath,
                    sessionId: sessionId,
                    parentSessionId: parentSessionId
                )
            },
            isBuiltInMCPRegistered: { [weak self] sessionId in
                self?.mcpRegistrationRegistry.isRegistered(sessionId: sessionId) ?? false
            },
            clearMCPRegistration: { [weak self] sessionId in
                self?.mcpRegistrationRegistry.clear(sessionId: sessionId)
            },
            onSessionEnded: { [weak self] sessionId in
                self?.mcpHTTPSupervisor.end(sessionId: sessionId)
            },
            ggMCPProvider: { [weak self] worktreePath in
                guard let self,
                      let integration = self.ggACPWorktreeIntegration(worktreePath: worktreePath),
                      Self.shouldAttachGGMCP(context: integration.context)
                else { return nil }
                return GGMCPInjection.injection(
                    gatePassed: true,
                    binaryPath: GGAvailability.shared.ggMCPBinaryPath,
                    configuredServers: integration.project.mcpServers,
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
                        effectiveContext: integration.context
                    )
                )
            }
        )
        mgr.alasCLIEnvProvider = { [weak self] worktreePath, sessionId in
            guard let self else { return nil }
            let binDirPath = (try? TerminalCLIInjection.installExecutables())?.path
            let persistedParent = try? await self.acpOrchestrationPersistence.parent(
                childSessionId: sessionId
            )
            let parentSessionId = self.delegatedSessionParents[sessionId]
                ?? persistedParent?.parentSessionId
            return AlasCLIEnvInjection.environment(
                enabled: self.config.harness.exposeAlasMCP,
                binDirPath: binDirPath,
                socketPath: self.harness.socketServer.socketPath,
                worktreePath: worktreePath,
                sessionId: sessionId,
                parentSessionId: parentSessionId,
                basePATH: ACPProcessEnvironment.augmented()["PATH"]
            )
        }
        mgr.externalMCPStatusProvider = { [weak self] worktreePath in
            guard let self else { return (.unknown, nil, [], []) }
            let worktreeURL = URL(fileURLWithPath: worktreePath)
            let adapterState = PiMCPAdapterInspector.state(worktreeURL: worktreeURL)
            let project = self.projects.first(where: { $0.id == worktree.projectId })
            let servers = project?.mcpServers ?? []
            // Resolved unconditionally — even when the adapter is not
            // (yet) installed — so the preamble can name the project's
            // servers regardless of adapter state ("not installed" wording
            // still lists them). pi-mcp-adapter reads the resolved wire
            // config, not the raw project definitions, so
            // ${WORKTREE_DIR}/${PROJECT_DIR} templates are interpolated
            // exactly as the normal ACP session/new attach path does.
            // Unlike that path, http/sse are force-enabled here:
            // pi-mcp-adapter supports them even though pi-acp's own ACP
            // layer reports them unsupported, so this must not drop those
            // servers.
            let plan = MCPAttachmentPlanner.plan(.init(
                configuredServers: servers,
                projectDirectory: project?.path ?? worktreePath,
                worktreeDirectory: worktreePath,
                environment: ACPProcessEnvironment.sanitizedForACP(extra: [:]),
                capabilities: ACPMCPServerCapabilities(http: true, sse: true)
            ))
            let userServerNames = plan.wireServers.map(\.name)
            let skippedServerStatuses = plan.statuses.filter {
                if case .skipped = $0.disposition { return true }
                return false
            }
            guard adapterState == .installed else {
                return (adapterState, nil, userServerNames, skippedServerStatuses)
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
            return (adapterState, configOutcome, userServerNames, skippedServerStatuses)
        }
        acpManagers[worktree.id] = mgr
        acpHarnessBridge.attach(manager: mgr)
        #if DEBUG
        memoryDiagnostics.attach(manager: mgr)
        #endif
        return mgr
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
            return URL(fileURLWithPath: raw)
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
        guard let manager = acpManagers.removeValue(forKey: worktreeId) else { return }
        // Flush any pending debounced draft writes before tearing the
        // manager down — otherwise the last ~300ms of typing in any
        // composer for this worktree never reaches SQLite.
        manager.flushPendingDraftWrites()
        #if DEBUG
        memoryDiagnostics.detach(worktreeId: worktreeId)
        #endif
        acpHarnessBridge.detach(worktreeId: worktreeId)
        let sessionIds = Array(manager.runners.keys)
        // Synchronously cancel the runner's async loops so they stop
        // pumping the agent's stdout into our handlers immediately —
        // otherwise the loops hold `self` weakly but keep the
        // permission / file / update streams flowing until the
        // detach() task below schedules. The actual child-process
        // shutdown then happens asynchronously.
        for sid in sessionIds { manager.runners[sid]?.stop() }
        // Cancel mirror pollers and heartbeats — mirror sessions have no
        // runner and are never reached by the detach loop above, so they
        // must be torn down explicitly to stop the 2.5s backstop polls and
        // notifier subscriptions from outliving the manager.
        manager.shutdownBackgroundTasks()
        Task { @MainActor in
            await manager.flushAllPersistence()
            for sid in sessionIds { await manager.detach(sessionId: sid) }
            // Release any leases this manager still owns AFTER all runner
            // connections are shut down (detach above). A freed lease must
            // not be claimable while an old agent process is still alive.
            // `detach` already released runner-session leases; this mops up
            // any remaining pre-runner owned leases (e.g. sessions acquired
            // a lease but didn't register a runner yet).
            await manager.releaseAllOwnedLeases()
        }
    }

    /// Open a new ACP session tab for the given agent in the currently-selected worktree.
    func openNewACPSession(agentID: String, initialPrompt: String? = nil) {
        guard let worktreeId = selectedWorktreeId,
              let worktree = worktree(withId: worktreeId) else { return }
        guard let mgr = acpManager(for: worktree) else { return }
        let session = mgr.createSession(agentId: agentID, autoRunDefault: config.harness.acpAutoRunByDefault)
        if let initialPrompt, !initialPrompt.isEmpty {
            mgr.persistComposerDraft(
                ACPComposerDraft(segments: [.text(initialPrompt)]),
                for: session
            )
        }
        let state = ACPSessionTabState(sessionId: session.id, title: session.title)
        tabs.append(acpSession: state, to: worktree.id)
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
            tabs.activate(worktreeId: worktree.id, tabId: tabState.id)
            return
        }

        openNewACPSession(agentID: agentID, initialPrompt: initialPrompt)
    }

    func openReviewLoopHandoff(from reviewLoop: ReviewLoopState, actionKind: ReviewReadinessActionKind) {
        guard let snapshot = reviewLoop.snapshot else { return }
        guard actionKind == .openAgentHandoff else { return }
        let agentID = config.changes.aiToolId
        guard agentID != "none", agent(id: agentID) != nil else { return }
        let prompt = ReviewLoopHandoffBuilder.build(
            snapshot: snapshot,
            action: ReviewLoopAction(
                kind: Self.reviewLoopHandoffActionKind(for: snapshot.reviewRequest),
                title: "Open in Agent",
                detail: "Prepare a focused agent handoff."
            )
        )
        openACPHandoff(agentID: agentID, initialPrompt: prompt)
    }

    func openReviewEvidenceHandoff(snapshot: ReviewLoopSnapshot, detail: ReviewEvidenceDetail) {
        let agentID = config.changes.aiToolId
        guard agentID != "none", agent(id: agentID) != nil else { return }
        let prompt = ReviewLoopHandoffBuilder.buildSelectedEvidencePrompt(
            snapshot: snapshot,
            detail: detail
        )
        openACPHandoff(agentID: agentID, initialPrompt: prompt)
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
        guard let mgr = acpManager(for: worktree) else { return }

        // Focus the tab if it's already there.
        let tabIdToFocus: TabID? = tabs.tabs(forWorktree: worktree.id).compactMap { tab -> TabID? in
            if case .acpSession(let s) = tab, s.sessionId == sessionId { return tab.id }
            return nil
        }.first
        if let id = tabIdToFocus {
            tabs.activate(worktreeId: worktree.id, tabId: id)
            return
        }

        // Resolve an uncached row before creating the tab so hydration cannot
        // leave a generic title behind indefinitely.
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
        tabs.append(acpSession: state, to: worktree.id)
    }

    private func deliverPendingDelegatedMessages(to sessionId: String, manager: ACPSessionManager) async {
        guard let messages = try? await acpOrchestrationPersistence.pendingMessages(targetSessionId: sessionId) else {
            return
        }
        await manager.attach(to: sessionId, freshlyCreated: false)
        guard manager.isWriter(for: sessionId) else {
            manager.notifyDelegatedMessagesAvailable()
            return
        }
        for message in messages {
            guard let claimed = try? await acpOrchestrationPersistence.claimMessage(
                id: message.id,
                instanceId: instanceId,
                token: UUID().uuidString,
                now: Int64(Date().timeIntervalSince1970),
                staleAfter: 60
            ) else { continue }
            let accepted = await manager.enqueueDelegatedPrompt(
                text: claimed.message.prompt,
                source: ACPDelegatedPromptSource(
                    sessionId: claimed.message.sourceSessionId,
                    messageId: claimed.message.id
                ),
                into: sessionId
            )
            if accepted {
                try? await acpOrchestrationPersistence.removeDeliveredMessage(
                    id: claimed.message.id,
                    claim: claimed.claim
                )
            } else {
                try? await acpOrchestrationPersistence.releaseMessageClaim(
                    id: claimed.message.id,
                    claim: claimed.claim
                )
                manager.notifyDelegatedMessagesAvailable()
            }
        }
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
                createdAt: record.createdAt
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

    @discardableResult
    func openDiscoveredACPSession(
        _ discovered: ACPDiscoveredSession,
        capabilities: ACPSessionDiscoveryCapabilities
    ) async -> Bool {
        guard let resolved = projectAndWorktree(withWorktreeId: discovered.worktreeId),
              let manager = acpManager(for: resolved.worktree)
        else { return false }

        focusGlobalWorktree(id: resolved.worktree.id, projectId: resolved.project.id)
        if let localSessionId = discovered.localSessionId {
            await openExistingACPSession(sessionId: localSessionId)
            return true
        }
        guard capabilities.canOpenRemoteSession,
              let row = await manager.materializeDiscoveredSession(
                discovered,
                autoRunDefault: config.harness.acpAutoRunByDefault
              )
        else { return false }

        await openExistingACPSession(sessionId: row.id)
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
            tabs.activate(worktreeId: worktreeId, tabId: existing.id)
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
            tabs.activate(worktreeId: worktreeId, tabId: tab.id)
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
            tabs.activate(worktreeId: worktreeId, tabId: existing.id)
            return
        }
        let tab = tabs.appendStashDiff(worktreeId: worktreeId, stash: stash, file: file)
        tabs.activate(worktreeId: worktreeId, tabId: tab.id)
    }

    func openCommitTab(worktreeId: String, commit: CommitInfo) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        if selectedWorktreeId != worktree.id {
            focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        }

        let existing = tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .commit(let state) = tab { return state.sha == commit.sha }
            return false
        }
        if let existing {
            tabs.activate(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let title = "\(commit.shortSha) \(commit.conventionalTag.map { "\($0): \(commit.subject)" } ?? commit.subject)"
            let tab = tabs.appendCommit(worktreeId: worktree.id, sha: commit.sha, title: title)
            tabs.activate(worktreeId: worktree.id, tabId: tab.id)
        }
    }

    func openFileSnapshotAtHEAD(relativePath: String, worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
        if selectedWorktreeId != worktree.id {
            focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        }
        let tab = tabs.openOrFocusFileSnapshot(worktreeId: worktree.id, relativePath: relativePath, ref: "HEAD")
        tabs.activate(worktreeId: worktree.id, tabId: tab.id)
    }

    func openFileHistory(relativePath: String, worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
        if selectedWorktreeId != worktree.id {
            focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        }
        let tab = tabs.openOrFocusFileHistory(worktreeId: worktree.id, relativePath: relativePath)
        tabs.activate(worktreeId: worktree.id, tabId: tab.id)
    }

    /// Project-scoped gg inbox capability. This intentionally does not use a
    /// hosting worktree's effective context because the inbox spans the repo.
    func ggInboxAvailable(projectId: String) -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        return Self.resolveGGInboxAvailable(
            masterEnabled: config.changes.stackedDiffsEnabled,
            ggInstalled: GGAvailability.shared.isInstalled,
            isRemoteProject: project.host != nil,
            projectMode: project.ggMode,
            repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path),
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
        Self.resolveGGWorktreeContext(
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
        return GGWorktreeMenuModel(
            selectedMode: selectedMode,
            context: ggWorktreeContext(
                project: project,
                worktree: worktree,
                branch: worktree.branch
            ),
            hasStackSummary: GGStackSummaryStore.shared.summaries[worktree.path.path] != nil,
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
            isRemoteProject: project.host != nil,
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
            return (
                project,
                worktree,
                ggWorktreeContext(
                    project: project,
                    worktree: worktree,
                    branch: branch,
                    ggInstalled: ggInstalled
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
}

// MARK: - RemoteSessionsProvider
//
// Lives in this file (not a separate one) so it can reach the private
// `acpManagers` dictionary. Aggregates across every live per-worktree manager;
// worktrees not opened this run simply don't appear (documented v1 behavior).
extension AppState: RemoteSessionsProvider {
    private func remoteWorktreeSummary(project: ProjectConfig, worktree: Worktree) async -> RemoteWorktreeSummary {
        let git = GitService()
        do {
            async let status = git.status(worktreePath: worktree.path)
            async let commits = git.commitsAhead(
                at: worktree.path,
                baseBranch: config.worktrees.baseBranch,
                resolution: GitService.BaseResolution.forCommits(
                    mode: config.changes.comparisonMode, userOverrodeBaseBranch: false
                )
            )
            let (changes, commitResult) = try await (status, commits)
            return RemoteWorktreeSummaryBuilder.make(
                projectName: project.name,
                worktree: worktree,
                metrics: .available(
                    comparisonRef: commitResult.comparisonRef,
                    commitCount: commitResult.commits.count,
                    changes: changes
                )
            )
        } catch {
            return remoteWorktreeSummaryWithoutMetrics(project: project, worktree: worktree)
        }
    }

    private func remoteWorktreeSummaryWithoutMetrics(project: ProjectConfig, worktree: Worktree) -> RemoteWorktreeSummary {
        RemoteWorktreeSummaryBuilder.make(
            projectName: project.name,
            worktree: worktree,
            metrics: .unavailable
        )
    }

    private func remoteWorktreeOption(project: ProjectConfig, worktree: Worktree) async -> RemoteWorktreeOption {
        let summary = await remoteWorktreeSummary(project: project, worktree: worktree)
        return RemoteWorktreeOption(
            id: worktree.id,
            projectName: summary.projectName,
            worktreeName: summary.worktreeName,
            branch: summary.branch,
            path: summary.path,
            metricsAvailable: summary.metricsAvailable,
            comparisonRef: summary.comparisonRef,
            commitCount: summary.commitCount,
            changedFileCount: summary.changedFileCount,
            addedLines: summary.addedLines,
            deletedLines: summary.deletedLines,
            conflictCount: summary.conflictCount
        )
    }

    private func remoteSessionSummary(
        session: ACPSession,
        manager: ACPSessionManager,
        worktreeSummary: RemoteWorktreeSummary?
    ) -> RemoteSessionSummary {
        let streamingState = manager.runners[session.id]?.session.transcript.streamingState
            ?? session.transcript.streamingState
        return RemoteSessionSummary(
            id: session.id,
            title: session.title,
            agentId: session.agentId,
            status: RemoteSessionGateway.stateString(streamingState),
            canDrive: manager.isWriter(for: session.id),
            worktree: worktreeSummary
        )
    }

    func sessionSummaries() async -> [RemoteSessionSummary] {
        var summariesByIdentity: [String: RemoteSessionSummaryCandidate] = [:]
        var identities: [String] = []

        for mgr in acpManagers.values {
            let worktreeSummary: RemoteWorktreeSummary?
            if let resolved = projectAndWorktree(withWorktreeId: mgr.worktreeId) {
                worktreeSummary = await remoteWorktreeSummary(project: resolved.project, worktree: resolved.worktree)
            } else {
                worktreeSummary = nil
            }

            for row in mgr.sessionRows where !row.archived {
                let liveSession = mgr.liveSession(for: row.id)
                var effectiveRow = row
                if let liveRemoteId = liveSession?.remoteSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !liveRemoteId.isEmpty {
                    effectiveRow.remoteSessionId = liveRemoteId
                }
                let state = mgr.runners[row.id]?.session.transcript.streamingState
                let candidate = RemoteSessionSummaryCandidate(
                    row: effectiveRow,
                    status: state.map(RemoteSessionGateway.stateString) ?? "idle",
                    hasRunner: state != nil,
                    isActive: hasOpenACPSessionTab(worktreeId: mgr.worktreeId, sessionId: row.id),
                    canDrive: mgr.isWriter(for: row.id),
                    worktree: worktreeSummary
                )
                let identity = remoteSessionListIdentity(worktreeId: mgr.worktreeId, row: effectiveRow)
                if let existing = summariesByIdentity[identity] {
                    summariesByIdentity[identity] = existing.merging(candidate)
                } else {
                    identities.append(identity)
                    summariesByIdentity[identity] = candidate
                }
            }
        }
        return identities.compactMap { summariesByIdentity[$0]?.summary }
    }

    private func hasOpenACPSessionTab(worktreeId: String, sessionId: ACPSession.ID) -> Bool {
        tabs.tabs(forWorktree: worktreeId).contains { tab in
            if case .acpSession(let state) = tab {
                return state.sessionId == sessionId
            }
            return false
        }
    }

    private func remoteSessionListIdentity(worktreeId: String, row: ACPSessionRow) -> String {
        if let remoteSessionId = row.remoteSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteSessionId.isEmpty {
            return "\(worktreeId)\u{0}\(row.agentId)\u{0}\(remoteSessionId)"
        }
        return "\(worktreeId)\u{0}local:\(row.id)"
    }

    private struct RemoteSessionSummaryCandidate {
        var operationalRow: ACPSessionRow
        var displayRow: ACPSessionRow
        var status: String
        var hasRunner: Bool
        var isActive: Bool
        var canDrive: Bool
        let worktree: RemoteWorktreeSummary?

        init(
            row: ACPSessionRow,
            status: String,
            hasRunner: Bool,
            isActive: Bool,
            canDrive: Bool,
            worktree: RemoteWorktreeSummary?
        ) {
            self.operationalRow = row
            self.displayRow = row
            self.status = status
            self.hasRunner = hasRunner
            self.isActive = isActive
            self.canDrive = canDrive
            self.worktree = worktree
        }

        var summary: RemoteSessionSummary {
            RemoteSessionSummary(
                id: operationalRow.id,
                title: displayRow.title,
                agentId: operationalRow.agentId,
                status: status,
                canDrive: canDrive,
                isActive: isActive,
                worktree: worktree
            )
        }

        func merging(_ other: RemoteSessionSummaryCandidate) -> RemoteSessionSummaryCandidate {
            var merged = self
            if other.isBetterOperationalRow(than: merged) {
                merged.operationalRow = other.operationalRow
                merged.status = other.status
                merged.hasRunner = other.hasRunner
                merged.isActive = other.isActive
                merged.canDrive = other.canDrive
            }
            if Self.isBetterDisplayRow(other.displayRow, than: merged.displayRow) {
                merged.displayRow = other.displayRow
            }
            return merged
        }

        private func isBetterOperationalRow(than other: RemoteSessionSummaryCandidate) -> Bool {
            if canDrive != other.canDrive { return canDrive }
            if hasRunner != other.hasRunner { return hasRunner }
            if isActive != other.isActive { return isActive }
            if operationalRow.lastOpenedAt != other.operationalRow.lastOpenedAt {
                return operationalRow.lastOpenedAt > other.operationalRow.lastOpenedAt
            }
            return operationalRow.updatedAt > other.operationalRow.updatedAt
        }

        private static func isBetterDisplayRow(_ candidate: ACPSessionRow, than current: ACPSessionRow) -> Bool {
            let candidateScore = displayTitleScore(candidate)
            let currentScore = displayTitleScore(current)
            if candidateScore != currentScore { return candidateScore > currentScore }
            return candidate.updatedAt > current.updatedAt
        }

        private static func displayTitleScore(_ row: ACPSessionRow) -> Int {
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let meaningfulTitle = !title.isEmpty && title != "New session"
            let sourceScore: Int
            switch row.titleSource {
            case .manual: sourceScore = 3
            case .generated: sourceScore = 2
            case .placeholder: sourceScore = 1
            }
            return (meaningfulTitle ? 100 : 0) + sourceScore
        }
    }

    func remoteWorktrees() async -> [RemoteWorktreeOption] {
        var out: [RemoteWorktreeOption] = []
        for project in projects {
            for worktree in projectsManager.visibleWorktrees(projectId: project.id) {
                switch projectsManager.operationState(for: worktree.id) {
                case .creating, .deleting, .createFailed:
                    continue
                case nil, .deleteFailed:
                    out.append(await remoteWorktreeOption(project: project, worktree: worktree))
                }
            }
        }
        return out
    }

    func remoteAgents() -> [RemoteAgentOption] {
        let enabledById = Dictionary(uniqueKeysWithValues: agentRegistry.enabled().map { ($0.id, $0) })
        let ordered = ACPLaunchCatalog.specs.compactMap { enabledById[$0.agentID] }
        return ordered.enumerated().map { index, agent in
            RemoteAgentOption(id: agent.id, name: agent.displayName, isDefault: index == 0)
        }
    }

    func createRemoteSession(worktreeId: String, agentId: String) async -> RemoteCreateSessionResult {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeId),
              projectsManager.visibleWorktrees(projectId: resolved.project.id).contains(where: { $0.id == worktreeId })
        else {
            return .failure("Worktree is no longer available.")
        }
        switch projectsManager.operationState(for: worktreeId) {
        case .creating, .deleting, .createFailed:
            return .failure("Worktree is no longer available.")
        case nil, .deleteFailed:
            break
        }

        let acpIds = Set(ACPLaunchCatalog.specs.map(\.agentID))
        guard let agent = agentRegistry.enabled().first(where: { $0.id == agentId }), acpIds.contains(agent.id) else {
            return .failure("Agent is no longer available.")
        }

        guard let manager = acpManager(for: resolved.worktree) else {
            return .failure("Could not create session.")
        }

        let session = manager.createSession(agentId: agent.id, autoRunDefault: config.harness.acpAutoRunByDefault)
        focusGlobalWorktree(id: resolved.worktree.id, projectId: resolved.project.id)
        let tabState = ACPSessionTabState(sessionId: session.id, title: session.title)
        let tab = tabs.append(acpSession: tabState, to: resolved.worktree.id)
        tabs.activate(worktreeId: resolved.worktree.id, tabId: tab.id)

        if let remoteSessionAttachScheduler {
            remoteSessionAttachScheduler(manager, session.id)
        } else {
            Task { @MainActor [weak manager] in
                await manager?.attach(to: session.id, freshlyCreated: true)
            }
        }

        let worktreeSummary = remoteWorktreeSummaryWithoutMetrics(project: resolved.project, worktree: resolved.worktree)
        return .success(remoteSessionSummary(session: session, manager: manager, worktreeSummary: worktreeSummary))
    }

    func session(for id: String) -> ACPSession? {
        for mgr in acpManagers.values {
            if let s = mgr.liveSession(for: id) { return s }
        }
        return nil
    }

    func permissionPolicy(for id: String) -> ACPPermissionPolicy? {
        for mgr in acpManagers.values {
            if let p = mgr.permissionPolicy(for: id) { return p }
        }
        return nil
    }

    func fullToolCallContent(sessionId: String, toolCallId: String) async -> String? {
        for mgr in acpManagers.values {
            if let content = await mgr.reloadFullToolCallContent(
                sessionId: sessionId,
                toolCallId: toolCallId
            ) {
                return content
            }
        }
        return nil
    }

    func hydrateIfNeeded(id: String) async {
        // The remote list includes recent sessions that aren't currently open
        // on the Mac (no live ACPSession yet). Materialize the session in its
        // owning manager — same read-only path the UI uses (placeholderSession
        // does a single indexed lookup; no writer lease / attach) — so a remote
        // client can open any listed session, not just already-open ones.
        for mgr in acpManagers.values {
            guard mgr.liveSession(for: id) != nil
                    || mgr.sessionRows.contains(where: { $0.id == id }) else { continue }
            _ = mgr.placeholderSession(id: id)
            await mgr.hydrateIfNeeded(id: id)
            return
        }
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

    func respondToUserInput(for id: String, token: UUID, action: ACPUserInputAction) {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            mgr.respondToUserInput(for: id, token: token, action: action)
            return
        }
    }

    func isWriter(for id: String) -> Bool {
        for mgr in acpManagers.values where mgr.isWriter(for: id) { return true }
        return false
    }

    func takeOver(for id: String) async {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            await mgr.takeOver(sessionId: id)
            return
        }
    }

    /// `onResult` fires once (false when no manager owns the id, the manager
    /// refuses, or delivery later fails) so the gateway can restore the text.
    func sendPrompt(for id: String, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void) async {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            await mgr.sendPrompt(for: id, text: text, attachments: attachments, onResult: onResult)
            return
        }
        onResult(false)
    }

    func writeAttachment(_ data: Data, mimeType: String, name: String?, for id: String) -> URL? {
        guard let mgr = acpManagers.values.first(where: { $0.liveSession(for: id) != nil }),
              let session = mgr.liveSession(for: id) else { return nil }
        let dir = Paths.acpAttachmentsDir(forWorktreeId: session.worktreeId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = mimeType == "image/png" ? "png" : (mimeType == "image/jpeg" ? "jpg" : "img")
        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    func stop(for id: String) async {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            await mgr.interruptBypassingLease(for: id)
            return
        }
    }

    func setModel(for id: String, modelId: String) async {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            await mgr.setModel(for: id, modelId: modelId)
            return
        }
    }

    func setMode(for id: String, modeId: String) async {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            await mgr.setMode(for: id, modeId: modeId)
            return
        }
    }

    func setAutoRun(for id: String, enabled: Bool) async {
        for mgr in acpManagers.values where mgr.liveSession(for: id) != nil {
            await mgr.setAutoRun(for: id, enabled: enabled)
            return
        }
    }

    func renameSession(for id: String, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        for mgr in acpManagers.values {
            guard mgr.liveSession(for: id) != nil
                    || mgr.sessionRows.contains(where: { $0.id == id && !$0.archived }) else { continue }
            guard let session = mgr.liveSession(for: id) ?? mgr.placeholderSession(id: id) else { return false }
            guard mgr.renameSessionCosmetic(id: session.id, title: trimmed, source: .manual) else { return false }

            _ = tabs.renameACPSessionTabs(worktreeId: mgr.worktreeId, sessionId: session.id, title: trimmed)
            return true
        }

        return false
    }

    func sessionConfig(for id: String) -> RemoteSessionConfig? {
        for mgr in acpManagers.values {
            guard let s = mgr.liveSession(for: id) else { continue }
            return RemoteSessionConfig(
                sessionId: id,
                models: s.availableModels.map { RemoteModelInfo(id: $0.id, name: $0.name) },
                modes: s.availableModes.map { RemoteModelInfo(id: $0.id, name: $0.name) },
                currentModel: s.currentModel,
                currentMode: s.currentMode,
                autoRunEnabled: s.autoRunEnabled,
                acceptsImages: s.promptCapabilities.image)
        }
        return nil
    }
}
