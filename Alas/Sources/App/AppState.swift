import Foundation
import AppKit
import Observation
import os

@Observable
@MainActor
final class AppState {
    var config: AppConfig
    var themeStore: ThemeStore
    var projectsManager: ProjectsManager
    var selectedWorktreeId: String?
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
        String?
    ) throws -> OpenedTerminalSession

    @ObservationIgnored
    private let terminalSessionOpener: TerminalSessionOpener?
    let rightPaneStore = RightPaneStore()
    let harness = HarnessService()
    @ObservationIgnored
    private var lspManager: WorkspaceLSPManager?

    var isSearchOpen: Bool = false
    var isRepoSelectorOpen: Bool = false
    var isAgentLauncherOpen: Bool = false
    var isKeyboardOverlayOpen: Bool {
        isSearchOpen || isRepoSelectorOpen || isAgentLauncherOpen
    }
    let repoSelector = RepoSelectorModel()
    let agentLauncher = AgentLauncherModel()

    func openSearchOverlay() {
        repoSelector.close()
        isRepoSelectorOpen = false
        agentLauncher.reset()
        isAgentLauncherOpen = false
        search.open()
        isSearchOpen = true
    }

    func toggleRepoSelectorOverlay() {
        agentLauncher.reset()
        isAgentLauncherOpen = false

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
        search.close()
        isSearchOpen = false
        repoSelector.close()
        isRepoSelectorOpen = false
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
                    color: project.color,
                    startupScripts: updated
                )
            )
            projectsChanged = true
        }
        if projectsChanged { saveProjects() }
    }

    // MARK: - LSP installer

    let lspInstaller = LSPInstaller()
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

    @ObservationIgnored
    lazy var search: SearchModel = SearchModel(environment: makeSearchEnvironment())
    @ObservationIgnored
    private let fileIndex = FileIndex()
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

    /// One FSEvents watcher per project, watching `<repo>/.git` to auto-refresh
    /// the sidebar when branches flip or worktrees appear/disappear externally.
    @ObservationIgnored
    private var projectGitWatchers: [String: ProjectGitWatcher] = [:]

    init(
        store: any PersistenceStoreProtocol = PersistenceStore(),
        persistenceErrorHandler: ((String, String) -> Void)? = nil,
        fileActionErrorHandler: ((String, String) -> Void)? = nil,
        terminalSessionOpener: TerminalSessionOpener? = nil
    ) {
        self.store = store
        self.persistenceErrorHandler = persistenceErrorHandler ?? { title, message in
            AppState.showWarningAlert(title: title, message: message)
        }
        self.fileActionErrorHandler = fileActionErrorHandler ?? { title, message in
            AppState.showWarningAlert(title: title, message: message)
        }
        self.terminalSessionOpener = terminalSessionOpener
        let config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? AppConfig.defaults
        let projectsFile = (try? store.readIfExists(ProjectsFile.self, from: Paths.projectsFile)) ?? ProjectsFile(projects: [])
        self.config = config
        // Publish the effective shortcut reservations so the terminal pane
        // can honor user overrides from the very first keystroke.
        ShortcutReservations.update(from: config)
        self.projectsManager = ProjectsManager(persistedProjects: projectsFile.projects)
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
        WindowAppearance.apply(darkMode: themeStore.current.darkMode)
        // Tabs can't be loaded here: worktrees haven't been refreshed yet (that
        // happens async in RootView.task), so worktreesByProject is empty and
        // we'd resolve to a 0-element id list. RootView calls reloadTabs() after
        // refreshAll() returns.
        rightPaneStore.appState = self

        // Kick off a background resolution of the user's login-shell PATH so
        // every `Process.git()` invocation uses the same environment a terminal
        // session would (Homebrew, nvm, rbenv, etc.). Fire-and-forget: if it
        // hasn't finished by the first git command, gitEnv() falls back to the
        // process PATH (same behaviour as before).
        ShellEnvResolver.shared.resolve()
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
        if let current = selectedWorktreeId, !afterIds.contains(current) {
            selectedWorktreeId = firstVisibleWorktreeId()
        }
    }

    /// Re-scan persisted tab JSONs for every currently-known worktree id. Call
    /// after `projectsManager.refreshAll()` so worktrees actually exist.
    func reloadTabs() {
        let allWorktreeIds = projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        }
        tabs.loadAll(worktreeIds: allWorktreeIds)
        // Persisted terminal-tab leaves are now in memory — refresh their
        // hook symlinks so zmx-persisted shells in undisplayed tabs deliver
        // hooks/CLI requests to the live harness immediately, rather than
        // waiting for `restoreTerminalTabIfNeeded` (driven by
        // TerminalTabView.task) to fire when the user opens the tab.
        refreshPersistedHookSymlinks()
    }

    var projects: [ProjectConfig] { projectsManager.projects }

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
            focusWorktree: { [weak self] id in
                self?.selectedWorktreeId = id
            },
            openNewProject: openNewProject,
            openNewWorktree: openNewWorktree,
            currentWorktreeId: { [weak self] in self?.selectedWorktreeId }
        )
    }

    @discardableResult
    func saveConfig() -> Bool {
        let saved: Bool
        do {
            try store.write(config, to: Paths.appConfigFile)
            saved = true
        } catch {
            saved = false
            persistenceErrorHandler("Settings Save Failed", error.localizedDescription)
        }
        lspManager?.updateRegistry(LanguageServerRegistry(userDefined: config.code.languageServers))
        return saved
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

    /// Optimistically insert a worktree row and run the git operation async.
    /// Returns the optimistic worktree id so the dialog can close immediately.
    @discardableResult
    func createWorktree(
        projectId: String,
        base: String,
        branch: String,
        destination: URL,
        runStartup: Bool,
        openTerminal: Bool,
        launchAgentId: String? = nil
    ) -> String {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            // Should not happen if the dialog validated the project; fail silently.
            return ""
        }
        // Canonicalize once and use this URL everywhere downstream — both
        // the optimistic row and the eventual `WorktreeService.add` return
        // value derive their `id` from the path we hand in, so any
        // divergence here would make `selectedWorktreeId` and terminal
        // routing target a non-existent row after reconcile.
        //
        // resolvingSymlinksInPath only resolves links along path components
        // that exist on disk; the leaf doesn't exist yet, so resolve the
        // parent (which does) and reattach the leaf.
        let canonicalDestination = destination
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
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
        let optimistic = Worktree(
            id: optimisticId,
            projectId: projectId,
            name: branch,
            branch: branch,
            path: canonicalDestination,
            status: .clean,
            lastActivity: Date()
        )
        projectsManager.insertOptimisticWorktree(optimistic)
        projectsManager.setOperationState(id: optimistic.id, state: .creating)

        let repoPath = URL(fileURLWithPath: project.path)
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
                    _ = try? await Process.run(
                        "/bin/zsh",
                        args: ["-c", startupScript],
                        cwd: newWorktree.path
                    )
                }
                guard projects.contains(where: { $0.id == projectId }) else { return }

                // Resolve the per-creation agent into a command line that
                // will run inside the new terminal session — appended to
                // the session's startup script so the agent gets a real
                // TTY and the user can interact with it. Bypass-perms
                // semantics still come from config (project override >
                // global). If no terminal is being opened we silently skip
                // auto-launch: a detached background spawn for an
                // interactive CLI (claude, codex, gemini) would just exit
                // immediately on the EOF from its missing stdin.
                let launchAgentCommand: String? = {
                    guard let id = launchAgentId,
                          let agent = self.agentRegistry.enabled().first(where: { $0.id == id })
                    else { return nil }
                    return self.agentStartupCommand(for: agent, project: project)
                }()

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
                    let gcDropped = try await projectsManager.refreshWorktrees(projectId: project.id)
                    guard projects.contains(where: { $0.id == projectId }) else { return }
                    if wasHidden || gcDropped {
                        saveProjects()
                    }

                    selectedWorktreeId = newWorktree.id
                    // Force the terminal open when an agent was picked —
                    // launching an interactive CLI without a visible
                    // session is functionally a no-op.
                    let shouldOpenTerminal = openTerminal || launchAgentCommand != nil
                    if shouldOpenTerminal {
                        _ = try? openTerminalTab(
                            for: newWorktree,
                            startupScriptSuffix: launchAgentCommand
                        )
                    }
                } catch {
                    projectsManager.setOperationState(
                        id: optimistic.id,
                        state: .createFailed(message: error.localizedDescription, base: base)
                    )
                }
            } catch {
                let msg = error.localizedDescription
                projectsManager.setOperationState(id: optimistic.id, state: .createFailed(message: msg, base: base))
            }
        }
        return optimistic.id
    }

    func agentStartupCommand(for agent: AgentDefinition, project: ProjectConfig) -> String {
        var argv = [agent.resolvedBinary]
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

    @discardableResult
    func openAgentTerminalTab(for worktree: Worktree, agentId: String) throws -> Tab {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw AgentTerminalLaunchError.projectUnavailable
        }
        guard let agent = agentRegistry.enabled().first(where: { $0.id == agentId }) else {
            throw AgentTerminalLaunchError.agentUnavailable
        }
        do {
            if agent.id == AgentKind.copilot.rawValue {
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

    nonisolated private static func shellQuote(_ s: String) -> String {
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
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try await WorktreeService().add(
                repoPath: repoPath,
                base: base,
                branch: branch,
                destination: destination,
                projectId: projectId
            )
        }.value
    }

    func removeFailedOptimisticWorktree(id: String, projectId: String) {
        cleanupWorktreeState(worktreeId: id)
        projectsManager.removeOptimisticWorktree(id: id, projectId: projectId)
        if selectedWorktreeId == id {
            selectedWorktreeId = firstVisibleWorktreeId()
        }
    }

    func addProject(path: URL, displayName: String, color: String) async throws {
        let project = try await projectsManager.addProject(path: path, displayName: displayName, color: color)
        saveProjects()
        if await projectsManager.refreshAll() {
            saveProjects()
        }
        startProjectGitWatcher(for: project)
    }

    @discardableResult
    func removeProject(id: String) -> Bool {
        guard let project = projects.first(where: { $0.id == id }) else { return false }

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
                for entry in dirtyByWorktree {
                    guard saveDirtyBuffers(in: entry.worktree) else { return false }
                }
            case .discard:
                break
            case .cancel:
                return false
            }
        }

        var beforeIds = allWorktreeIds()
        for candidateId in candidateIds {
            beforeIds.insert(candidateId)
        }
        stopProjectGitWatcher(projectId: id)
        projectsManager.removeProject(id: id)
        saveProjects()
        let removedIds = beforeIds.subtracting(allWorktreeIds())
        cleanupMissingWorktrees(beforeIds: beforeIds)
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
            guard removeProject(id: id) else { break }
            removed += 1
        }
        return removed
    }

    @discardableResult
    func clearProjectsWithoutWorktrees() async -> Int {
        var staleProjectIds: [String] = []
        for project in projects {
            do {
                try await projectsManager.refreshWorktrees(projectId: project.id)
            } catch {
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
            guard removeProject(id: id) else { break }
            removed += 1
        }
        return removed
    }

    /// Start a ProjectGitWatcher for `project` and wire its callbacks into
    /// the fast (HEAD-only) and slow (topology) refresh paths. Idempotent:
    /// stops any existing watcher for the same project id first.
    func startProjectGitWatcher(for project: ProjectConfig) {
        stopProjectGitWatcher(projectId: project.id)
        let watcher = ProjectGitWatcher(repoPath: URL(fileURLWithPath: project.path))
        let projectId = project.id
        watcher.onHeadChanged = { [weak self] map in
            self?.projectsManager.applyHeadUpdates(
                projectId: projectId,
                branchByWorktreePath: map
            )
        }
        watcher.onTopologyChanged = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let beforeIds = self.allWorktreeIds()
                // refreshWorktrees returns true when the hidden-path GC dropped
                // entries — persist so archived worktrees removed externally
                // don't reappear after relaunch.
                if (try? await self.projectsManager.refreshWorktrees(projectId: projectId)) == true {
                    self.saveProjects()
                }
                self.cleanupMissingWorktrees(beforeIds: beforeIds)
            }
        }
        watcher.start()
        projectGitWatchers[projectId] = watcher
    }

    func stopProjectGitWatcher(projectId: String) {
        projectGitWatchers.removeValue(forKey: projectId)?.stop()
    }

    func startAllProjectGitWatchers() {
        for project in projectsManager.projects {
            startProjectGitWatcher(for: project)
        }
    }

    func stopAllProjectGitWatchers() {
        for (_, watcher) in projectGitWatchers { watcher.stop() }
        projectGitWatchers.removeAll()
    }

    func updateProject(id: String, name: String, color: String, startupScripts: ProjectStartupScripts) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        projectsManager.updateProject(
            id: id,
            update: ProjectUpdate(
                name: trimmedName,
                color: color,
                startupScripts: startupScripts
            )
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
                guard saveDirtyBuffers(in: worktree) else { return }
            case .discard:
                break
            case .cancel:
                return
            }
        }

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
            selectedWorktreeId = selectionAfterRemoval(
                removedFromProjectId: worktree.projectId,
                removedAtIndex: removedIndex
            )
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
        harness.socketServer.onCLIRequest = { [weak self] request in
            await MainActor.run {
                guard let self else { return .error("Alas is not available.") }
                let router = self.makeCLICommandRouter { [weak self] sessionId in
                    if let s = self?.terminal.registry.session(for: sessionId) {
                        return s.worktreeId
                    }
                    // Fall back to persisted-tab scan so `alas open` etc.
                    // still resolve a worktree for zmx-persisted leaves
                    // whose `TerminalSession` hasn't been restored yet.
                    return self?.persistedLeafLocation(leafId: sessionId)?.worktreeId
                }
                return router.handle(request)
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

    func makeCLICommandRouter(
        sessionWorktreeLookup: @escaping (String) -> String?
    ) -> AlasCLICommandRouter {
        AlasCLICommandRouter(
            sessionWorktreeId: sessionWorktreeLookup,
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
                _ = self.tabs.openExternalEditor(
                    worktreeId: worktreeId,
                    absoluteURL: url,
                    revealLine: nil,
                    revealCharacter: nil,
                    originatingRelativePath: nil
                )
                if self.selectedWorktreeId != worktreeId {
                    self.selectedWorktreeId = worktreeId
                }
            },
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }

    /// Activate a specific harness session: bring the app to front, select
    /// the worktree, activate the terminal tab hosting `sessionId`, and
    /// focus the pane within that tab that owns the session (so keyboard
    /// input and the tab-bar harness badge follow the user's intent).
    /// If the tab is no longer present (session was closed mid-flight) the
    /// worktree is still selected so the user lands somewhere sensible.
    func activateHarnessSession(projectId _: String, worktreeId: String, sessionId: String) {
        selectedWorktreeId = worktreeId
        var matchedTabId: TabID?
        var matchedLeafId: String?
        for tab in tabs.tabs(forWorktree: worktreeId) {
            guard case .terminal(let s) = tab,
                  let leaf = s.root.leaves().first(where: { $0.sessionId == sessionId }) else { continue }
            matchedTabId = tab.id
            matchedLeafId = leaf.id
            break
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
    func openTerminalTab(
        for worktree: Worktree,
        startupScriptSuffix: String? = nil
    ) throws -> Tab {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw NSError(domain: "AppState", code: 2)
        }
        // Single identity for this pane: used as the zmx session name
        // suffix, the SessionRegistry key, the leaf id, the persisted
        // sessionId (mirrored to id on encode), and ALAS_SESSION_ID. Generated
        // here so every downstream call site receives the same value.
        let leafId = UUID().uuidString
        let opened: OpenedTerminalSession
        if let terminalSessionOpener {
            opened = try terminalSessionOpener(
                worktree,
                project,
                config.terminal,
                themeStore.current,
                nil,
                startupScriptSuffix
            )
        } else {
            let session = try terminal.openSession(
                worktree: worktree, project: project,
                cfg: config.terminal, theme: themeStore.current,
                startupScriptSuffix: startupScriptSuffix,
                leafId: leafId
            )
            opened = OpenedTerminalSession(id: session.id, foregroundPid: { [weak session] in
                session?.surface.foregroundPid
            })
        }
        harness.detector.register(sessionId: opened.id, pidProvider: opened.foregroundPid)
        let title = tabs.nextTerminalTitle(
            worktreeId: worktree.id,
            baseTitle: defaultTerminalTitle(for: worktree)
        )
        // `opened.id` is the live session id; for the default opener path
        // above that equals `leafId` (we passed it in). The injected
        // `terminalSessionOpener` (test-only) generates its own id and we
        // honor it for backward-compat with existing tests.
        return tabs.appendTerminal(worktreeId: worktree.id, title: title, sessionId: opened.id)
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
            // Single identity for the new pane: zmx session name suffix,
            // SessionRegistry key, leaf id, persisted sessionId, ALAS_SESSION_ID.
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

    /// Close the focused pane. If it was the last leaf, also closes the tab
    /// via the existing close-tab path (preserves today's ⌘W-on-unsplit
    /// behavior).
    func closeFocusedPane(worktreeId: String) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal = tab else { return }
        guard let outcome = tabs.removeFocusedLeaf(worktreeId: worktreeId, tabId: activeId) else { return }
        if case .tabRemoved = outcome {
            closeTab(worktreeId: worktreeId, tabId: activeId)
        } else {
            let closedLeafId = outcome.closedLeafId
            terminal.closeSession(id: closedLeafId)
            harness.detector.unregister(sessionId: closedLeafId)
            harness.forgetSession(closedLeafId)
        }
    }

    /// "Terminate All Terminal Sessions" menu action. Confirms with the user,
    /// then closes every terminal tab across every worktree (which kills
    /// the underlying zmx session) and sweeps any persisted-but-not-yet-
    /// restored leaves this instance owns.
    func terminateAllTerminalSessions() {
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
        let persistedLeafIds = allPersistedTerminalLeafIds()
        // Count individual leaves, not tabs — a single tab with split panes
        // contains multiple leaves and `terminateAll` kills every one. Union
        // with the live registry catches any session not yet flushed to disk.
        let sessionCount = Set(persistedLeafIds).union(terminal.registry.all.map(\.id)).count

        let alert = NSAlert()
        alert.messageText = "Terminate All Terminal Sessions"
        alert.informativeText = "Terminate \(sessionCount) terminal session(s)? This will kill any agent or process currently running in them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for (worktreeId, tabId) in terminalTabs {
            closeTab(worktreeId: worktreeId, tabId: tabId)
        }
        // Also kill persisted leaves whose tab the user never displayed
        // this run — closeTab only handles registered sessions, but we
        // own those persisted leaves too. Scoped to OUR instance's known
        // leaves so we don't trample sessions owned by a concurrently-
        // running Alas process under the same ZMX_DIR.
        terminal.terminateAll(additionalLeafIds: persistedLeafIds)
    }

    /// All terminal-leaf ids persisted under this Alas instance's projects.
    private func allPersistedTerminalLeafIds() -> [String] {
        projects.flatMap { project in
            projectsManager.worktrees(projectId: project.id).flatMap { worktree in
                tabs.tabs(forWorktree: worktree.id).flatMap { tab -> [String] in
                    guard case .terminal(let state) = tab else { return [] }
                    return state.root.leaves().map(\.id)
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
            closeTab(worktreeId: worktreeId, tabId: activeId)
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
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab,
              let worktree = worktree(withId: worktreeId),
              let project = projects.first(where: { $0.id == worktree.projectId }) else { return nil }

        for leaf in state.root.leaves() {
            // Idempotent: skip leaves whose session is already alive in the
            // registry. The leaf's id is the stable identity used as both
            // the registry key and the zmx session name suffix; we no longer
            // generate a fresh sessionId on each restore.
            if terminal.registry.session(for: leaf.id) != nil { continue }

            let forcedCwd = leaf.lastCwd.map { URL(fileURLWithPath: $0) }
            let session = try terminal.openSession(
                worktree: worktree, project: project,
                cfg: config.terminal, theme: themeStore.current,
                forcedCwd: forcedCwd,
                leafId: leaf.id
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
        var roots: [String: URL] = [:]
        for project in projects {
            for worktree in projectsManager.worktrees(projectId: project.id) {
                roots[worktree.id] = roots[worktree.id] ?? worktree.path
            }
        }
        let errors = tabs.saveAll(worktreeRoots: roots)
        guard !errors.isEmpty else { return }
        showFileActionError(
            title: "Save All Failed",
            message: "\(errors.count) file\(errors.count == 1 ? "" : "s") could not be saved."
        )
    }

    func revertActiveTab(worktreeId: String) {
        _ = tabs.revertActive(worktreeId: worktreeId)
    }

    func newFile(in worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
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

    func saveActiveTabAs(worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId),
              let context = tabs.activeEditorContext(worktreeId: worktreeId) else { return }
        let currentURL = worktree.path.appendingPathComponent(context.tab.relativePath)
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

    func renameActiveFile(worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId),
              let context = tabs.activeEditorContext(worktreeId: worktreeId) else { return }
        let currentURL = worktree.path.appendingPathComponent(context.tab.relativePath)
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

    func closeTab(worktreeId: String, tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        if let tab = allTabs.first(where: { $0.id == tabId }) {
            if case .terminal(let s) = tab {
                for leaf in s.root.leaves() {
                    harness.detector.unregister(sessionId: leaf.id)
                    harness.forgetSession(leaf.id)
                    terminal.closeSession(id: leaf.id)
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

    private func cleanupTerminals(allTabs: [Tab], tabIds: [TabID]) {
        for id in tabIds {
            if let tab = allTabs.first(where: { $0.id == id }),
               case .terminal(let s) = tab {
                for leaf in s.root.leaves() {
                    harness.detector.unregister(sessionId: leaf.id)
                    harness.forgetSession(leaf.id)
                    terminal.closeSession(id: leaf.id)
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
        guard let manager = acpManagers[worktreeId],
              let runner = manager.runners[sessionId] else { return }
        runner.stop()
        Task { @MainActor in
            await manager.detach(sessionId: sessionId)
        }
    }

    func closeOtherTabs(worktreeId: String, keeping tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeOthers(worktreeId: worktreeId, keeping: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        cleanupACPSessions(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    /// Tear down every tab/terminal/harness reference for a worktree id without
    /// touching git or persistence. Shared between Close-All, archive, and
    /// delete so the bookkeeping stays in one place.
    private func cleanupWorktreeState(worktreeId: String) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeAll(worktreeId: worktreeId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        disposeACPManager(for: worktreeId)
    }

    func closeAllTabs(worktreeId: String) {
        cleanupWorktreeState(worktreeId: worktreeId)
    }

    func closeTabsToLeft(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToLeft(worktreeId: worktreeId, of: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
        cleanupACPSessions(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    func closeTabsToRight(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToRight(worktreeId: worktreeId, of: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
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

    private func worktree(withId id: String) -> Worktree? {
        for project in projects {
            if let worktree = projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return worktree
            }
        }
        return nil
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
    /// visible worktrees, picks the first visible worktree across all projects
    /// in declaration order. Returns `nil` if nothing is left.
    private func selectionAfterRemoval(removedFromProjectId: String, removedAtIndex: Int) -> String? {
        let siblings = projectsManager.visibleWorktrees(projectId: removedFromProjectId)
        if !siblings.isEmpty {
            let i = min(removedAtIndex, siblings.count - 1)
            return siblings[i].id
        }
        for project in projects {
            if let first = projectsManager.visibleWorktrees(projectId: project.id).first {
                return first.id
            }
        }
        return nil
    }

    func firstVisibleWorktreeId() -> String? {
        for project in projects {
            if let first = projectsManager.visibleWorktrees(projectId: project.id).first {
                return first.id
            }
        }
        return nil
    }

    var canFocusMainWorktreeForCurrentProject: Bool {
        mainWorktreeForCurrentProject() != nil
    }

    func focusMainWorktreeForCurrentProject() {
        guard let main = mainWorktreeForCurrentProject() else { return }
        selectedWorktreeId = main.id
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
        // Invariant: the two synchronous closures below are only invoked
        // from `SearchModel`, which is `@MainActor` — so `assumeIsolated`
        // is sound. If a future caller invokes them off-main this will
        // trap; keep them on main or convert to async.
        SearchEnvironment(
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
        revealCharacter: Int? = nil
    ) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        // Reject archived worktrees: their ids may still appear in some legacy
        // call sites (e.g. older persisted tabs). Selecting one would set
        // `selectedWorktreeId` to a hidden id that `RootView.selectedWorktree()`
        // (now visibility-aware) would reject anyway, leaving an empty pane.
        guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
        if selectedWorktreeId != worktree.id { selectedWorktreeId = worktree.id }

        if ImageFileType.isSupported(relativePath: relativePath) {
            _ = tabs.openImagePreview(worktreeId: worktree.id, relativePath: relativePath)
            return
        }

        _ = tabs.openEditor(
            worktreeId: worktree.id,
            relativePath: relativePath,
            revealLine: revealLine,
            revealCharacter: revealCharacter
        )
    }

    func revealInFiles(worktreeId: String, path: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        config.rightPaneVisible = true
        _ = saveConfig()
        let rps = rightPaneStore.state(for: worktree, baseBranch: config.worktrees.baseBranch)
        rps.reveal(path: path)
    }

    /// Open a markdown relative-link target as a new editor tab in the same worktree.
    /// Delegates to `openFile` which handles find-or-create, activate, and
    /// worktree-switch if necessary.
    func openMarkdownLink(worktreeId: String, worktreeRoot: URL, relativePath: String) {
        openFile(relativePath: relativePath, worktreeId: worktreeId)
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

        // Resolve a path against the shell cwd (if known) and fall back to the
        // worktree root. This handles both cwd-relative links (the common
        // terminal case) and repo-root-relative links (common in agent output).
        func resolve(_ rawPath: String) -> URL {
            if (rawPath as NSString).isAbsolutePath {
                return URL(fileURLWithPath: rawPath).standardizedFileURL
            }
            let cwdBase = session.surface.currentWorkingDirectory ?? worktree.path
            let cwdRelative = cwdBase.appendingPathComponent(rawPath).standardizedFileURL
            let rootRelative = worktree.path.appendingPathComponent(rawPath).standardizedFileURL
            if FileManager.default.fileExists(atPath: cwdRelative.path) {
                return cwdRelative
            }
            if cwdRelative.path != rootRelative.path,
               FileManager.default.fileExists(atPath: rootRelative.path) {
                return rootRelative
            }
            return cwdRelative
        }

        func attemptOpen(_ candidatePath: String) -> Bool {
            let target: TerminalOpenTarget
            let resolved = resolve(candidatePath)
            if FileManager.default.fileExists(atPath: resolved.path) {
                target = TerminalOpenTarget(url: resolved, revealLine: nil, revealCharacter: nil)
            } else if let parsed = Self.parseTerminalPathPosition(candidatePath) {
                let resolvedParsed = resolve(parsed.path)
                target = TerminalOpenTarget(
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
            NSApp.activate(ignoringOtherApps: true)
            return true
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

    private struct TerminalOpenTarget {
        var url: URL
        var revealLine: Int?
        var revealCharacter: Int?
    }

    private struct TerminalPathPosition {
        var path: String
        var line: Int
        var column: Int?
    }

    nonisolated private static func parseTerminalPathPosition(_ rawPath: String) -> TerminalPathPosition? {
        guard let lineSplit = splitTrailingPositiveInteger(from: rawPath) else { return nil }
        if let columnSplit = splitTrailingPositiveInteger(from: lineSplit.prefix) {
            return TerminalPathPosition(
                path: columnSplit.prefix,
                line: columnSplit.value,
                column: lineSplit.value
            )
        }
        return TerminalPathPosition(path: lineSplit.prefix, line: lineSplit.value, column: nil)
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

    private func showFileActionError(title: String, message: String) {
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
            guard confirmDeleteWorktree(branch: worktree.branch, keepBranch: keepBranch) else { return }
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
            guard saveDirtyBuffers(in: worktree) else { return }
        }
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

        // Mark deleting immediately so the UI dims the row.
        projectsManager.setOperationState(id: worktree.id, state: .deleting)

        Task { @MainActor in
            await performDeleteWorktree(
                worktree: worktree,
                repoPath: repoPath,
                deleteBranchIfMerged: deleteBranch,
                force: false,
                removedIndex: removedIndex
            )
        }
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
            if !force, let reason = Self.forceDeleteReason(for: stderr) {
                // Clear deleting so the user can see the row again while deciding.
                projectsManager.setOperationState(id: worktree.id, state: nil)
                pendingForceDeleteWorktree = PendingForceDeleteWorktree(
                    id: worktree.id,
                    branch: worktree.branch,
                    projectId: worktree.projectId,
                    repoPath: repoPath,
                    worktreePath: worktree.path,
                    deleteBranchIfMerged: deleteBranchIfMerged,
                    removedIndex: removedIndex,
                    reason: reason
                )
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
        if (try? await projectsManager.refreshWorktrees(projectId: worktree.projectId)) == true {
            saveProjects()
        }
        if selectedWorktreeId == worktree.id {
            selectedWorktreeId = selectionAfterRemoval(
                removedFromProjectId: worktree.projectId,
                removedAtIndex: removedIndex
            )
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

    /// Resolve whether `git branch -d` should run after `git worktree remove`.
    /// `keepBranch == true` (a per-operation override) always wins — the local
    /// branch is preserved regardless of the global setting.
    nonisolated static func resolveDeleteBranchIfMerged(
        globalDeleteOnRemove: Bool,
        keepBranch: Bool
    ) -> Bool {
        globalDeleteOnRemove && !keepBranch
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

    private func confirmDeleteWorktree(branch: String, keepBranch: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete worktree '\(branch)'?"
        alert.informativeText = keepBranch
            ? "This removes its files from disk. The local branch will be kept."
            : "This removes its files from disk. The local branch will be deleted if merged."
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
    private func saveDirtyBuffers(in worktree: Worktree) -> Bool {
        let errors = tabs.saveAllUnsaved(forWorktree: worktree.id, root: worktree.path)
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

    /// Returns (or lazily creates) the ACP session manager for the given worktree.
    /// Returns nil when the SQLite backing store cannot be opened.
    func acpManager(for worktree: Worktree) -> ACPSessionManager? {
        if let existing = acpManagers[worktree.id] { return existing }
        let dbURL = Paths.acpSessionsDB(forWorktreeId: worktree.id)
        do {
            let store = try ACPSessionStore(path: dbURL.path)
            let mgr = ACPSessionManager(
                worktreeId: worktree.id,
                worktreePath: worktree.path.path,
                store: store,
                onDirtyCheck: { [weak self] path in
                    self?.editorHasDirtyBuffer(for: path, worktreeId: worktree.id) ?? false
                },
                onLiveBufferRead: { [weak self] path in
                    self?.editorLiveBufferText(for: path, worktreeId: worktree.id)
                }
            )
            acpManagers[worktree.id] = mgr
            return mgr
        } catch {
            return nil
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
        let sessionIds = Array(manager.runners.keys)
        // Synchronously cancel the runner's async loops so they stop
        // pumping the agent's stdout into our handlers immediately —
        // otherwise the loops hold `self` weakly but keep the
        // permission / file / update streams flowing until the
        // detach() task below schedules. The actual child-process
        // shutdown then happens asynchronously.
        for sid in sessionIds { manager.runners[sid]?.stop() }
        Task { @MainActor in
            for sid in sessionIds { await manager.detach(sessionId: sid) }
        }
    }

    /// Open a new ACP session tab for the given agent in the currently-selected worktree.
    func openNewACPSession(agentID: String) {
        guard let worktreeId = selectedWorktreeId,
              let worktree = worktree(withId: worktreeId) else { return }
        guard let mgr = acpManager(for: worktree) else { return }
        let session = mgr.createSession(agentId: agentID)
        let state = ACPSessionTabState(sessionId: session.id, title: session.title)
        tabs.append(acpSession: state, to: worktree.id)
    }

    /// Reopen a persisted ACP session as a center-pane tab. If a tab
    /// for this session is already open in the current worktree we
    /// just focus it; otherwise we create one and let openSession()
    /// rehydrate the transcript from disk.
    func openExistingACPSession(sessionId: ACPSession.ID) {
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

        // Load the row so we can stamp the right title onto the new tab.
        let title: String
        if let row = try? mgr.store.loadSession(id: sessionId) {
            title = row.title
        } else {
            title = "ACP session"
        }
        _ = mgr.openSession(id: sessionId)
        let state = ACPSessionTabState(sessionId: sessionId, title: title)
        tabs.append(acpSession: state, to: worktree.id)
    }

    /// Open a diff tab for the given worktree-relative path.
    /// Reuses an existing unstaged diff tab for the same path if one is already open.
    func openDiffTab(forFileInWorktree worktree: Worktree, relativePath: String) {
        let worktreeId = worktree.id
        let staged = false
        let existing = tabs.tabs(forWorktree: worktreeId).first { tab in
            if case .diff(let s) = tab { return s.relativePath == relativePath && s.staged == staged }
            return false
        }
        if let existing {
            tabs.activate(worktreeId: worktreeId, tabId: existing.id)
        } else {
            let title = (relativePath as NSString).lastPathComponent
            let tab = tabs.appendDiff(
                worktreeId: worktreeId,
                title: title,
                relativePath: relativePath,
                staged: staged
            )
            tabs.activate(worktreeId: worktreeId, tabId: tab.id)
        }
    }
}
