import Foundation

/// The host is stopping and starts nothing new.
public struct HostStopping: Error, Equatable, LocalizedError {
    public var errorDescription: String? { "The host is stopping." }
}

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
    /// Ends every run and agent session, for a host about to exit: runs,
    /// launches still starting included, are stopped as a worktree's removal
    /// stops them; each session's agent is detached and its process ended,
    /// and every queued session write is flushed.
    public func shutdown() async {
        // First: a request still underway cannot start what this stops.
        core.isStopping = true
        let worktreeIDs = Set(core.processRuns.values.map(\.worktreeID))
            .union(core.pendingRunLaunches.keys.map(\.worktreeID))
        for worktreeID in worktreeIDs {
            await core.stopProcessRuns(worktreeID: worktreeID)
        }
        // Every manager is marked disposed before the first await, so an
        // attachment scheduled just before cannot start in any of them.
        let managers = Array(core.sessionManagers.values)
        core.sessionManagers.removeAll()
        for manager in managers {
            manager.flushPendingDraftWrites()
            for runner in manager.runners.values {
                runner.stop()
            }
            manager.prepareForDisposal()
        }
        for manager in managers {
            await AlasCoreContext.finishDisposing(manager)
            manager.shutdownBackgroundTasks()
        }
        // Requests still being served (their Git or SSH checks included) and
        // worktree mutations already past their checks finish rather than
        // being cut off at exit. Sessions are ended above, so a prompt waiting
        // on its turn returns too.
        // ponytail: bounded at a minute, so a hung hook cannot keep the host alive.
        let deadline = ContinuousClock.now + .seconds(60)
        // Failed rows keep their state for a retry; only work underway is waited on.
        func workUnderway() -> Bool {
            core.requestsUnderway > 0 || core.projects.operationStatesSnapshot().values.contains { state in
                switch state {
                case .creating, .deleting, .archiving: true
                default: false
                }
            }
        }
        while workUnderway(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
