import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class AppState {
    var config: AppConfig
    var themeStore: ThemeStore
    var projectsManager: ProjectsManager
    var selectedWorktreeId: String?
    let tabs = TabsManager()
    let terminal = TerminalService()
    let rightPaneStore = RightPaneStore()
    let harness = HarnessService()
    @ObservationIgnored
    private var lspManager: WorkspaceLSPManager?

    var isSearchOpen: Bool = false
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

    private let store = PersistenceStore()

    init() {
        let config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? AppConfig.defaults
        let projectsFile = (try? store.readIfExists(ProjectsFile.self, from: Paths.projectsFile)) ?? ProjectsFile(projects: [])
        self.config = config
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
    }

    /// Re-scan persisted tab JSONs for every currently-known worktree id. Call
    /// after `projectsManager.refreshAll()` so worktrees actually exist.
    func reloadTabs() {
        let allWorktreeIds = projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        }
        tabs.loadAll(worktreeIds: allWorktreeIds)
    }

    var projects: [ProjectConfig] { projectsManager.projects }

    func saveConfig() {
        try? store.write(config, to: Paths.appConfigFile)
        lspManager?.updateRegistry(LanguageServerRegistry(userDefined: config.code.languageServers))
    }

    func saveProjects() {
        try? store.write(ProjectsFile(projects: projectsManager.projects), to: Paths.projectsFile)
    }

    func addProject(path: URL, displayName: String, color: String) async throws {
        _ = try await projectsManager.addProject(path: path, displayName: displayName, color: color)
        saveProjects()
        await projectsManager.refreshAll()
    }

    func removeProject(id: String) {
        projectsManager.removeProject(id: id)
        saveProjects()
    }

    func startHarness() {
        // Sync the persisted preference into NotificationService BEFORE start —
        // otherwise the service defaults to enabled and users who turned
        // notifications off in a previous session get them again until they
        // re-toggle.
        harness.notifications.setEnabled(config.harness.notifyOnFinish)
        harness.start { [weak self] sessionId in
            guard let self else { return nil }
            for s in self.terminal.registry.all where s.id == sessionId {
                return (projectId: s.projectId, worktreeId: s.worktreeId)
            }
            return nil
        }
        harness.onClickThrough = { [weak self] _, worktreeId, _ in
            self?.selectedWorktreeId = worktreeId
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @discardableResult
    func openTerminalTab(for worktree: Worktree) throws -> Tab {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw NSError(domain: "AppState", code: 2)
        }
        let session = try terminal.openSession(
            worktree: worktree, project: project,
            cfg: config.terminal, theme: themeStore.current
        )
        harness.detector.register(sessionId: session.id) { [weak session] in
            session?.surface.foregroundPid
        }
        return tabs.appendTerminal(worktreeId: worktree.id, title: worktree.branch, sessionId: session.id)
    }

    @discardableResult
    func restoreTerminalTabIfNeeded(worktreeId: String, tabId: TabID, sessionId: String) throws -> Tab? {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab,
              state.sessionId == sessionId else { return nil }
        if terminal.registry.session(for: sessionId) != nil { return tab }
        return try replaceMissingTerminalSession(worktreeId: worktreeId, tab: state)
    }

    func closeTab(worktreeId: String, tabId: TabID) {
        if let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
           case .terminal(let s) = tab {
            harness.detector.unregister(sessionId: s.sessionId)
            harness.forgetSession(s.sessionId)
            terminal.closeSession(id: s.sessionId)
        }
        tabs.close(worktreeId: worktreeId, tabId: tabId)
    }

    private func cleanupTerminals(allTabs: [Tab], tabIds: [TabID]) {
        for id in tabIds {
            if let tab = allTabs.first(where: { $0.id == id }),
               case .terminal(let s) = tab {
                harness.detector.unregister(sessionId: s.sessionId)
                harness.forgetSession(s.sessionId)
                terminal.closeSession(id: s.sessionId)
            }
        }
    }

    func closeOtherTabs(worktreeId: String, keeping tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeOthers(worktreeId: worktreeId, keeping: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
    }

    func closeAllTabs(worktreeId: String) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeAll(worktreeId: worktreeId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
    }

    func closeTabsToLeft(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToLeft(worktreeId: worktreeId, of: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
    }

    func closeTabsToRight(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToRight(worktreeId: worktreeId, of: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
    }

    @discardableResult
    private func replaceMissingTerminalSession(worktreeId: String, tab: TerminalTabState) throws -> Tab {
        guard let worktree = worktree(withId: worktreeId),
              let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw NSError(domain: "AppState", code: 2)
        }

        let oldSessionId = tab.sessionId
        let session = try terminal.openSession(
            worktree: worktree, project: project,
            cfg: config.terminal, theme: themeStore.current
        )
        harness.detector.unregister(sessionId: oldSessionId)
        harness.forgetSession(oldSessionId)
        harness.detector.register(sessionId: session.id) { [weak session] in
            session?.surface.foregroundPid
        }
        guard let replacement = tabs.replaceTerminalSession(
            worktreeId: worktreeId,
            tabId: tab.id,
            sessionId: session.id
        ) else {
            terminal.closeSession(id: session.id)
            throw NSError(domain: "AppState", code: 3)
        }
        return replacement
    }

    private func worktree(withId id: String) -> Worktree? {
        for project in projects {
            if let worktree = projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return worktree
            }
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
                        for wt in self.projectsManager.worktrees(projectId: project.id) {
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
    func openFile(relativePath: String, worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        if selectedWorktreeId != worktree.id { selectedWorktreeId = worktree.id }

        let existing = tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .editor(let s) = tab { return s.relativePath == relativePath } else { return false }
        }
        if let existing {
            tabs.activate(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let tab = tabs.appendEditor(
                worktreeId: worktree.id,
                title: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath
            )
            tabs.activate(worktreeId: worktree.id, tabId: tab.id)
        }
    }
}
