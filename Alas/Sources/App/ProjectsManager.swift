import Foundation
import Observation

struct ProjectUpdate: Equatable {
    var name: String
    var color: String
    var startupScripts: ProjectStartupScripts = .defaults
}

@Observable
@MainActor
final class ProjectsManager {
    private(set) var projects: [ProjectConfig]
    private(set) var worktreesByProject: [String: [Worktree]] = [:]

    private let git = GitService()
    private let worktreeSvc = WorktreeService()

    init(persistedProjects: [ProjectConfig]) {
        self.projects = persistedProjects
    }

    func addProject(path: URL, displayName: String, color: String) async throws -> ProjectConfig {
        let isRepo = try await git.isGitRepository(path)
        guard isRepo else {
            throw NSError(domain: "ProjectsManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a git repository: \(path.path)"])
        }
        let project = ProjectConfig(
            id: UUID().uuidString,
            name: displayName,
            path: path.path,
            color: color,
            addedAt: Date()
        )
        projects.append(project)
        return project
    }

    func removeProject(id: String) {
        projects.removeAll { $0.id == id }
        worktreesByProject.removeValue(forKey: id)
    }

    func updateProject(id: String, update: ProjectUpdate) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = update.name
        projects[idx].color = update.color
        projects[idx].startupScripts = update.startupScripts
    }

    func worktrees(projectId: String) -> [Worktree] {
        worktreesByProject[projectId] ?? []
    }

    func visibleWorktrees(projectId: String) -> [Worktree] {
        let hidden = hiddenSet(projectId: projectId)
        return worktrees(projectId: projectId).filter { !hidden.contains(canonical($0.path)) }
    }

    func archivedWorktrees(projectId: String) -> [Worktree] {
        let hidden = hiddenSet(projectId: projectId)
        return worktrees(projectId: projectId).filter { hidden.contains(canonical($0.path)) }
    }

    func isWorktreeHidden(projectId: String, path: URL) -> Bool {
        hiddenSet(projectId: projectId).contains(canonical(path))
    }

    func setWorktreeHidden(projectId: String, path: URL, hidden: Bool) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let key = canonical(path)
        var paths = projects[idx].hiddenWorktreePaths
        if hidden {
            if !paths.contains(key) { paths.append(key) }
        } else {
            paths.removeAll { $0 == key }
        }
        projects[idx].hiddenWorktreePaths = paths
    }

    /// Refresh the live worktree list for a project and GC orphan hidden
    /// paths. Returns `true` when the GC dropped at least one entry, so the
    /// caller can persist the change to disk; `false` otherwise.
    @discardableResult
    func refreshWorktrees(projectId: String) async throws -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        let url = URL(fileURLWithPath: project.path)
        let trees = try await worktreeSvc.list(repoPath: url, projectId: projectId)
        worktreesByProject[projectId] = trees
        // GC orphan hidden entries: drop any hidden path that doesn't match a
        // live worktree path. Prevents stale entries accumulating when worktrees
        // get removed externally (e.g. `git worktree remove` from a terminal).
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        let live = Set(trees.map { canonical($0.path) })
        let before = projects[idx].hiddenWorktreePaths.count
        projects[idx].hiddenWorktreePaths.removeAll { !live.contains($0) }
        return projects[idx].hiddenWorktreePaths.count != before
    }

    /// Refresh every project. Returns `true` when at least one project's
    /// hidden-path GC dropped an entry, so the caller can persist the change.
    @discardableResult
    func refreshAll() async -> Bool {
        var changed = false
        for project in projects {
            if let didGC = try? await refreshWorktrees(projectId: project.id) {
                changed = changed || didGC
            }
        }
        return changed
    }

    private func hiddenSet(projectId: String) -> Set<String> {
        guard let project = projects.first(where: { $0.id == projectId }) else { return [] }
        return Set(project.hiddenWorktreePaths)
    }

    private func canonical(_ url: URL) -> String {
        Worktree.makeId(path: url)
    }
}
