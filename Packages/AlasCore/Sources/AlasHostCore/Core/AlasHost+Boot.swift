import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP
import AlasAgentKit

private let bootLogger = Logger(subsystem: "io.nlopez.alas", category: "AlasHost")

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
    /// It starts as the app does: legacy remote worktree ids are migrated
    /// before anything loads, the login-shell PATH is resolved for git and
    /// agents, and staged worktree trash and stale run files are swept.
    ///
    /// With `cliBinDir`, the directory holding the installed `alas` CLI, its
    /// agents get the built-in `alas` MCP server and CLI env.
    ///
    /// Throws when the project list cannot be read.
    public static func boot(in directory: URL = Paths.appSupportRoot, cliBinDir: URL? = nil) throws -> AlasHost {
        guard directory.standardizedFileURL.path == Paths.appSupportRoot.standardizedFileURL.path else {
            throw HostBootRefusal.notThisProcesssDirectory(directory)
        }
        let store = PersistenceStore()
        var projects = try store.readIfExists(ProjectsFile.self, from: Paths.projectsFile) ?? ProjectsFile(projects: [])
        var config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? .defaults
        var spaces = try? store.readIfExists(SpacesFile.self, from: Paths.spacesFile)
        RemotePathMigration.complete(
            projectsFile: &projects, config: &config, spaces: &spaces, saving: store,
            migrateStores: { RemotePathMigration.migrate(idMap: $0, defaults: AlasProfile.userDefaults) }
        )
        ShellEnvResolver.shared.resolve()
        let sweptProjects = projects.projects
        Task.detached(priority: .utility) {
            RunScriptCompletionMonitor.cleanupStaleLocalFiles()
            WorktreeTrashCleaner.sweep(projects: sweptProjects)
        }
        ACPLaunchCatalog.publishRegistryAgents(config.agents.registry)
        let environment = HeadlessHostEnvironment(configuration: config)
        // Every other store keeps its `Paths` default, which is this directory.
        let ordering = environment.config.worktrees.defaultOrdering
        let harness = HarnessService()
        // A process without an app bundle has no notification center.
        harness.notifications.notificationAdder = { request in
            bootLogger.notice("Dropped notification \(request.content.title, privacy: .private)")
        }
        weak var builtCore: AlasCoreContext?
        let alasTools = cliBinDir.map {
            HeadlessAlasTools(binDir: $0, socketServer: harness.socketServer, config: { environment.config }, core: { builtCore })
        }
        let core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: projects.projects, defaultOrdering: { ordering }),
            store: store,
            makeSessionManager: AlasCoreContext.sessionManagerFactory(
                config: { environment.config },
                onChipsObserved: { agentID, host, chips in
                    environment.modelCatalog?.record(
                        agentID: agentID,
                        models: (chips.models?.options ?? []).map { ACPAgentModelCatalog.Model(id: $0.id, name: $0.name) },
                        host: host
                    )
                    environment.modelCatalog?.recordEffort(agentID: agentID, thinking: chips.thinking)
                },
                alasTools: alasTools,
                onTurnCompleted: { completion in
                    Task { @MainActor in await builtCore?.turnCompleted(completion) }
                }
            ),
            environment: environment,
            harness: harness,
            usageHistory: try? UsageHistoryStore()
        )
        builtCore = core
        core.installDefaultShepherdEffects()
        core.installDefaultRunScheduleRunner()
        return AlasHost(core: core)
    }
}

extension AlasHost {
    /// Starts the PR and stack shepherds and the run schedules. Call once the
    /// projects' worktrees are listed: a record whose worktree the host does
    /// not list is left for the app until the next start.
    public func startAutomation() async {
        // gg is often only on the login shell's PATH, and a probe that misses
        // it is not repeated.
        await ShellEnvResolver.shared.waitUntilResolved()
        await GGAvailability.shared.probe()
        guard !core.isStopping else { return }
        core.reviewShepherd.start()
        core.stackShepherd.start()
        core.runScheduler.start()
    }

    /// Ends every run and agent session, for a host about to exit: runs,
    /// launches still starting included, are stopped as a worktree's removal
    /// stops them; each session's agent is detached and its process ended,
    /// and every queued session write is flushed.
    public func shutdown() async {
        // ponytail: stop() only ends the timers; an evaluation underway (a prompt delivery, a gg mutation) runs on, harmless since the process exits next
        core.reviewShepherd.stop()
        core.stackShepherd.stop()
        core.runScheduler.stop()
        // First: a request still underway cannot start what this stops.
        core.isStopping = true
        let worktreeIDs = Set(core.processRuns.values.map(\.worktreeID))
            .union(core.pendingRunLaunches.keys.map(\.worktreeID))
        for worktreeID in worktreeIDs {
            await core.stopProcessRuns(worktreeID: worktreeID)
        }
        // Runs stopped earlier, by a client or just above, whose process has
        // not exited yet.
        for stopping in Array(core.stoppingRuns.values) {
            await stopping.value
        }
        // Review refreshes of followed worktrees: none starts another round,
        // and one already reading Git or the code host finishes first.
        let refreshes = Array(core.reviewRefreshes.values)
        core.reviewRefreshes.removeAll()
        core.reviewFollowers.removeAll()
        for refresh in refreshes {
            refresh.cancel()
        }
        for refresh in refreshes {
            await refresh.value
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
