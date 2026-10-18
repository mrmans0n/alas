import Foundation

/// Why `AlasHost.boot(in:)` did not boot.
public enum HostBootRefusal: Error, Equatable, LocalizedError {
    /// A host serves only its own process's data directory: every store,
    /// session database included, lives under `Paths.appSupportRoot`.
    case notThisProcesssDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .notThisProcesssDirectory(let url):
            "\(url.path) is not this process's data directory; set ALAS_APP_SUPPORT_DIR to serve it."
        }
    }
}

extension HeadlessHostEnvironment {
    /// The environment of data directory `directory`: its `app.json`, or the
    /// defaults when it has none or cannot be read, as the app falls back.
    /// Registry agents are published, since sessions look their launch spec
    /// up by id.
    public convenience init(loadingFrom directory: URL) {
        let config = (try? PersistenceStore().readIfExists(AppConfig.self, from: directory.appendingPathComponent("app.json"))) ?? .defaults
        ACPLaunchCatalog.publishRegistryAgents(config.agents.registry)
        self.init(configuration: config)
    }
}

extension AlasHost {
    /// A host for this process's data directory, with nothing from the app:
    /// its settings, projects, workspaces, run and usage history, delegations,
    /// reviews and sessions are the directory's, agents run headlessly and
    /// scripts run as plain processes. The directory is the profile's
    /// (`ALAS_APP_SUPPORT_DIR`); any other is refused, because the stores
    /// that resolve `Paths` would write the profile's instead.
    ///
    /// Throws when the project list cannot be read.
    // ponytail: no startup migrations; the app runs them on launch, so a directory the app has not opened since an upgrade is read as-is.
    public static func boot(in directory: URL = Paths.appSupportRoot) throws -> AlasHost {
        guard directory.standardizedFileURL.path == Paths.appSupportRoot.standardizedFileURL.path else {
            throw HostBootRefusal.notThisProcesssDirectory(directory)
        }
        let environment = HeadlessHostEnvironment(loadingFrom: directory)
        let store = PersistenceStore()
        let projects = try store.readIfExists(ProjectsFile.self, from: Paths.projectsFile) ?? ProjectsFile(projects: [])
        // Every other store keeps its `Paths` default, which is this directory.
        let ordering = environment.config.worktrees.defaultOrdering
        return AlasHost(core: AlasCoreContext(
            projects: ProjectsManager(persistedProjects: projects.projects, defaultOrdering: { ordering }),
            store: store,
            environment: environment,
            usageHistory: try? UsageHistoryStore()
        ))
    }
}

extension AlasHost {
    /// Ends every run and agent session, for a host about to exit: runs are
    /// stopped as a worktree's removal stops them, and each session's agent
    /// is detached and its process ended.
    public func shutdown() async {
        let worktreeIDs = Set(core.processRuns.values.map(\.worktreeID))
        for worktreeID in worktreeIDs {
            await core.stopProcessRuns(worktreeID: worktreeID)
        }
        for manager in core.sessionManagers.values {
            await manager.disposeAllLiveSessions()
            manager.shutdownBackgroundTasks()
        }
    }
}
