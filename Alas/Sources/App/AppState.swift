import Foundation
import Observation

@Observable
final class AppState {
    var config: AppConfig
    var projects: [ProjectConfig]
    var themeStore: ThemeStore
    var selectedWorktreeId: String?

    private let store = PersistenceStore()

    init() {
        let store = PersistenceStore()
        let config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? AppConfig.defaults
        let projectsFile = (try? store.readIfExists(ProjectsFile.self, from: Paths.projectsFile)) ?? ProjectsFile(projects: [])
        self.config = config
        self.projects = projectsFile.projects
        self.themeStore = (try? ThemeStore(initialId: config.themeId)) ?? (try! ThemeStore())
    }

    func saveConfig() {
        try? store.write(config, to: Paths.appConfigFile)
    }

    func saveProjects() {
        try? store.write(ProjectsFile(projects: projects), to: Paths.projectsFile)
    }
}
