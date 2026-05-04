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

    private let store = PersistenceStore()

    init() {
        let config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? AppConfig.defaults
        let projectsFile = (try? store.readIfExists(ProjectsFile.self, from: Paths.projectsFile)) ?? ProjectsFile(projects: [])
        self.config = config
        self.projectsManager = ProjectsManager(persistedProjects: projectsFile.projects)
        self.themeStore = (try? ThemeStore(initialId: config.themeId)) ?? (try! ThemeStore())
        let allWorktreeIds = projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        }
        tabs.loadAll(worktreeIds: allWorktreeIds)
    }

    var projects: [ProjectConfig] { projectsManager.projects }

    func saveConfig() {
        try? store.write(config, to: Paths.appConfigFile)
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

    func closeTab(worktreeId: String, tabId: TabID) {
        if let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
           case .terminal(let s) = tab {
            harness.detector.unregister(sessionId: s.sessionId)
            terminal.closeSession(id: s.sessionId)
        }
        tabs.close(worktreeId: worktreeId, tabId: tabId)
    }
}
