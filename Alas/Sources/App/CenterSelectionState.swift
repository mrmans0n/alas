import Foundation

enum CenterSelectionState: Equatable {
    case worktree(Worktree)
    case deleting(Worktree)
    case deleteFailed(Worktree, message: String)
    case creating(Worktree)
    case loadingProject
    case empty
}

struct CenterSelectionStateResolver {
    let selectedWorktreeId: String?
    let projects: [ProjectConfig]
    let projectsManager: ProjectsManager
    var isRefreshingProjectTopologies = false

    @MainActor
    func resolve() -> CenterSelectionState {
        guard let id = selectedWorktreeId else {
            return isRefreshingProjectTopologies && !projects.isEmpty ? .loadingProject : .empty
        }
        if let op = projectsManager.operationState(for: id) {
            switch op {
            case .preparingDelete:
                break
            case .deleting:
                if let wt = findWorktree(by: id) { return .deleting(wt) }
                return .empty
            case .creating:
                if let wt = findWorktree(by: id) { return .creating(wt) }
                return .empty
            case .deleteFailed(let message):
                if let wt = findWorktree(by: id) { return .deleteFailed(wt, message: message) }
                return .empty
            default:
                break
            }
        }
        if let wt = selectedWorktree() { return .worktree(wt) }
        return .empty
    }

    @MainActor
    private func findWorktree(by id: String) -> Worktree? {
        for project in projects {
            if let wt = candidateWorktrees(projectId: project.id).first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }

    @MainActor
    private func selectedWorktree() -> Worktree? {
        guard let id = selectedWorktreeId else { return nil }
        for project in projects {
            if let wt = candidateWorktrees(projectId: project.id).first(where: { $0.id == id }) {
                if let op = projectsManager.operationState(for: wt.id) {
                    switch op {
                    case .creating, .deleting, .createFailed:
                        return nil
                    case .preparingDelete, .deleteFailed:
                        break
                    }
                }
                return wt
            }
        }
        return nil
    }

    @MainActor
    private func candidateWorktrees(projectId: String) -> [Worktree] {
        projectsManager.visibleWorktrees(projectId: projectId)
    }
}
