import Foundation
import Observation

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

    func worktrees(projectId: String) -> [Worktree] {
        worktreesByProject[projectId] ?? []
    }

    func refreshWorktrees(projectId: String) async throws {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        let url = URL(fileURLWithPath: project.path)
        let trees = try await worktreeSvc.list(repoPath: url, projectId: projectId)
        worktreesByProject[projectId] = trees
    }

    func refreshAll() async {
        for project in projects {
            try? await refreshWorktrees(projectId: project.id)
        }
    }
}
