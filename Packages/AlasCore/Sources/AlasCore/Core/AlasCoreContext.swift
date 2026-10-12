import Foundation
import Observation

/// The headless composition root: the projects Alas manages, their worktrees,
/// and the session managers that run agents in them. Nothing here needs the
/// app; `AppState` builds one at launch and keeps only UI state on top.
@MainActor
@Observable
public final class AlasCoreContext {
    public var projects: ProjectsManager
    /// One session manager per owner (worktree or workspace checkout).
    public var sessionManagers: [SessionOwnerID: ACPSessionManager] = [:]
    /// Observed command lifecycles, keyed by worktree then script. A run's
    /// outcome outlives whatever shell ran it.
    public var runRecords = RunRecordStore()
    /// Completed-run history.
    public let runHistory: RunHistory
    /// Runs project scripts without a terminal.
    @ObservationIgnored public let runs: RunService
    /// Decides when scheduled runs start; its runner decides how.
    public let runScheduler: RunScheduler

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let projectsFile: URL
    @ObservationIgnored private let makeSessionManager: @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager

    /// Wraps projects already loaded, as `AppState` does after its startup migrations.
    public init(
        projects: ProjectsManager,
        store: any PersistenceStoreProtocol = PersistenceStore(),
        projectsFile: URL = Paths.projectsFile,
        runs: RunService = RunService(),
        runHistoryStore: RunHistoryStore? = try? RunHistoryStore(),
        runScheduler: RunScheduler? = nil,
        makeSessionManager: @escaping @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager = AlasCoreContext.defaultSessionManager
    ) {
        self.projects = projects
        self.runs = runs
        self.runScheduler = runScheduler ?? RunScheduler(store: store)
        self.runHistory = RunHistory(store: runHistoryStore)
        self.store = store
        self.projectsFile = projectsFile
        self.makeSessionManager = makeSessionManager
    }

    /// Loads the projects persisted at `projectsFile`.
    public convenience init(
        loadingFrom store: any PersistenceStoreProtocol = PersistenceStore(),
        projectsFile: URL = Paths.projectsFile,
        runHistoryStore: RunHistoryStore? = try? RunHistoryStore(),
        makeSessionManager: @escaping @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager = AlasCoreContext.defaultSessionManager
    ) throws {
        let file = try store.readIfExists(ProjectsFile.self, from: projectsFile) ?? ProjectsFile(projects: [])
        self.init(
            projects: ProjectsManager(persistedProjects: file.projects),
            store: store,
            projectsFile: projectsFile,
            runHistoryStore: runHistoryStore,
            makeSessionManager: makeSessionManager
        )
    }

    public func saveProjects() throws {
        try store.write(ProjectsFile(projects: projects.projects), to: projectsFile)
    }

    /// Registers the repository or folder at `path` and persists it. Nothing
    /// is kept if the save fails.
    @discardableResult
    public func addProject(
        path: URL,
        displayName: String,
        icon: ProjectIcon,
        host: String? = nil,
        kind: ProjectKind = .git,
        id: String = UUID().uuidString
    ) async throws -> ProjectConfig {
        guard !projects.projects.contains(where: { $0.id == id }) else {
            throw ProjectCreationError.projectAlreadyExists
        }
        let project = try await projects.addProject(
            path: path,
            displayName: displayName,
            icon: icon,
            host: host,
            kind: kind,
            id: id
        )
        do {
            try saveProjects()
        } catch {
            projects.removeProject(id: project.id)
            throw ProjectCreationError.projectPersistenceFailed
        }
        // The project is committed. A refresh or save that fails from here on
        // leaves the topology to the next refresh rather than failing the add.
        if (try? await projects.refreshWorktrees(projectId: project.id)) == true {
            try? saveProjects()
        }
        return project
    }

    /// Creates a worktree for `branch` from `base` at `destination`, then
    /// refreshes and persists the project's worktree list on a best-effort basis.
    public func createWorktree(
        projectID: String,
        branch: String,
        base: String,
        destination: URL
    ) async throws -> Worktree {
        guard let project = projects.projects.first(where: { $0.id == projectID }) else {
            throw ProjectCreationError.projectNotFound
        }
        let repoPath = URL(fileURLWithPath: project.path)
        let prepared = try await WorktreeLifecycle.preparedCreateWorktreeDestination(
            repoPath: repoPath,
            destination: destination
        )
        let worktree = try await WorktreeLifecycle.performCreateWorktree(
            repoPath: repoPath,
            base: base,
            branch: branch,
            destination: prepared,
            projectId: projectID
        )
        // The worktree now exists on disk, and git is the source of truth for
        // it: a refresh or save that fails here is left to the next refresh
        // rather than reported as a failed creation.
        if (try? await projects.refreshWorktrees(projectId: projectID)) == true {
            try? saveProjects()
        }
        return worktree
    }

    /// Runs `script` in `worktree` without a terminal, recording it and
    /// archiving its output like a terminal run. A run that never started
    /// leaves the previous record in place; one whose exit status was never
    /// observed finishes as `unknown`.
    @discardableResult
    public func runScript(_ script: RunScript, in worktree: Worktree) async throws -> RunOutcome {
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard project.host == nil else { throw RunService.RunError.remoteProjectUnsupported }
        guard runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive != true else {
            throw RunService.RunError.alreadyRunning
        }
        let runID = UUID().uuidString
        let displaced = runRecords.begin(RunRecord(
            id: runID,
            scriptKey: script.key,
            scriptName: script.displayName,
            worktreeID: worktree.id,
            branch: worktree.branch,
            target: RunExecutionTarget(
                host: nil,
                workingDirectory: script.cwd.map { worktree.path.appendingPathComponent($0).path } ?? worktree.path.path
            ),
            endpoint: script.endpoint,
            status: .running,
            startedAt: Date()
        ))
        let completion: RunScriptCompletion
        do {
            completion = try await runs.run(script, in: worktree, project: project, runID: runID)
        } catch is CancellationError {
            runHistory.archive(runRecords.finish(runID: runID, outcome: .stopped, at: Date()), capture: .unavailable)
            throw CancellationError()
        } catch where error is RunService.RunError || error is RunScriptCompletionMonitor.MonitorError {
            // The command ran but its exit status was never observed.
            runHistory.archive(runRecords.markLostObservation(runID: runID, at: Date()), capture: .unavailable)
            throw error
        } catch {
            runRecords.rollback(runID: runID, to: displaced)
            throw error
        }
        let outcome: RunOutcome = completion.exitCode == 0 ? .succeeded : .failed(exitCode: completion.exitCode)
        runHistory.archive(
            runRecords.finish(runID: runID, outcome: outcome, at: completion.completedAt),
            capture: .completion(completion)
        )
        return outcome
    }

    /// A manager with its own session database, as the app keeps per owner.
    public static func defaultSessionManager(owner: SessionOwnerID, worktree: Worktree) -> ACPSessionManager {
        ACPSessionManager(
            worktreeId: worktree.id,
            worktreePath: worktree.path.path,
            owner: owner,
            persistence: ACPSessionPersistence(path: Paths.acpSessionsDB(for: owner).path)
        )
    }

    /// The session manager for `worktree`, created on first use.
    public func sessionManager(for worktree: Worktree) -> ACPSessionManager {
        let owner = SessionOwnerID.worktree(worktree.id)
        if let manager = sessionManagers[owner] { return manager }
        let manager = makeSessionManager(owner, worktree)
        sessionManagers[owner] = manager
        return manager
    }
}
