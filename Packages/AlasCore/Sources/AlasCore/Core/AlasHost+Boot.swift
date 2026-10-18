import Foundation

extension AlasHost {
    /// A host for the data directory `directory`, with nothing from the app:
    /// its settings, projects, workspaces, run and usage history, delegations
    /// and reviews are read from the directory's files, sessions run their
    /// agents headlessly and scripts run as plain processes. The directory is
    /// the profile's (`ALAS_APP_SUPPORT_DIR`); session databases stay under
    /// `Paths`, which resolves the same root.
    ///
    /// Throws when the project list cannot be read. A missing or unreadable
    /// `app.json` falls back to the defaults, as the app does.
    // ponytail: no startup migrations; the app runs them on launch, so a directory the app has not opened since an upgrade is read as-is.
    public static func boot(in directory: URL = Paths.appSupportRoot) throws -> AlasHost {
        let store = PersistenceStore()
        let config = (try? store.readIfExists(AppConfig.self, from: directory.appendingPathComponent("app.json"))) ?? .defaults
        // Sessions of registry agents look their launch spec up by id.
        ACPLaunchCatalog.publishRegistryAgents(config.agents.registry)
        let projectsFile = directory.appendingPathComponent("projects.json")
        let projects = try store.readIfExists(ProjectsFile.self, from: projectsFile) ?? ProjectsFile(projects: [])
        let core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: projects.projects),
            store: store,
            projectsFile: projectsFile,
            runHistoryStore: try? RunHistoryStore(path: directory.appendingPathComponent("run-history.sqlite").path),
            workspaceStore: WorkspaceStore(store: store, url: directory.appendingPathComponent("workspaces.json")),
            environment: HeadlessHostEnvironment(configuration: config),
            orchestrationPersistence: ACPOrchestrationPersistence(path: directory.appendingPathComponent("acp-orchestration.sqlite").path),
            reviewDrafts: ReviewDraftCommentStore(store: store, url: directory.appendingPathComponent("review-draft-comments.json")),
            reviewSessions: ReviewSessionStore(store: store, url: directory.appendingPathComponent("review-sessions.json")),
            usageHistory: try? UsageHistoryStore(path: directory.appendingPathComponent("usage-history.sqlite").path)
        )
        return AlasHost(core: core)
    }
}
