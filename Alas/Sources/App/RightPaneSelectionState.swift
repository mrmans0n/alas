import Foundation

enum RightPaneSelectionState: Equatable {
    case empty
    case active(Worktree)
    case creating(Worktree)
    case deleting(Worktree)
    case createFailed(Worktree)

    var showsRightPane: Bool {
        switch self {
        case .empty:
            false
        case .active, .creating, .deleting, .createFailed:
            true
        }
    }
}

struct RightPaneSelectionStateResolver {
    let selectedWorktreeId: String?
    let projects: [ProjectConfig]
    let projectsManager: ProjectsManager

    @MainActor
    func resolve() -> RightPaneSelectionState {
        guard let id = selectedWorktreeId else { return .empty }
        guard let wt = findWorktree(by: id) else { return .empty }
        if let op = projectsManager.operationState(for: wt.id) {
            switch op {
            case .creating:
                return .creating(wt)
            case .deleting:
                return .deleting(wt)
            case .createFailed:
                return .createFailed(wt)
            case .deleteFailed:
                // The worktree still exists on disk; the right pane shows
                // real content while the center pane carries the failure
                // hero and recovery actions.
                return .active(wt)
            }
        }
        return .active(wt)
    }

    @MainActor
    private func findWorktree(by id: String) -> Worktree? {
        for project in projects {
            if let wt = projectsManager.visibleWorktrees(projectId: project.id).first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }
}
