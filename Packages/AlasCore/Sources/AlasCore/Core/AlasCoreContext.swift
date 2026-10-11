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
    /// Runs project scripts without a terminal.
    @ObservationIgnored public let runs: RunService

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let projectsFile: URL
    @ObservationIgnored private let makeSessionManager: @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager

    /// Wraps projects already loaded, as `AppState` does after its startup migrations.
    public init(
        projects: ProjectsManager,
        store: any PersistenceStoreProtocol = PersistenceStore(),
        projectsFile: URL = Paths.projectsFile,
        runs: RunService = RunService(),
        makeSessionManager: @escaping @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager = AlasCoreContext.defaultSessionManager
    ) {
        self.projects = projects
        self.runs = runs
        self.store = store
        self.projectsFile = projectsFile
        self.makeSessionManager = makeSessionManager
    }

    /// Loads the projects persisted at `projectsFile`.
    public convenience init(
        loadingFrom store: any PersistenceStoreProtocol = PersistenceStore(),
        projectsFile: URL = Paths.projectsFile,
        makeSessionManager: @escaping @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager = AlasCoreContext.defaultSessionManager
    ) throws {
        let file = try store.readIfExists(ProjectsFile.self, from: projectsFile) ?? ProjectsFile(projects: [])
        self.init(
            projects: ProjectsManager(persistedProjects: file.projects),
            store: store,
            projectsFile: projectsFile,
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
        if try await projects.refreshWorktrees(projectId: project.id) {
            try saveProjects()
        }
        return project
    }

    /// Creates a worktree for `branch` from `base` at `destination`, then
    /// refreshes and persists the project's worktree list.
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
        _ = try await projects.refreshWorktrees(projectId: projectID)
        try saveProjects()
        return worktree
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
