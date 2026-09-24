import Foundation

enum CenterSelectionState: Equatable {
    case worktree(Worktree)
    case deleting(Worktree)
    case deleteFailed(Worktree, message: String)
    case creating(Worktree)
    case loadingProject
    case empty
}

struct CheckoutFocusedWorktreeScope: Equatable, Sendable {
    var worktreeID: String
    var projectID: String
    var executionLocation: ExecutionLocation
}

struct CenterSelectionStateResolver {
    let selectedWorktreeId: String?
    var selectedWorktreeProjectId: String? = nil
    let projects: [ProjectConfig]
    let projectsManager: ProjectsManager
    /// When a checkout is selected, only its explicitly focused member may
    /// drive repository panes. Ordinary Project navigation stays unrestricted.
    var allowedWorktreeIDs: Set<String>? = nil
    var checkoutFocusedWorktreeScope: CheckoutFocusedWorktreeScope? = nil
    var isRefreshingProjectTopologies = false

    @MainActor
    func resolve() -> CenterSelectionState {
        guard let id = selectedWorktreeId else {
            return isRefreshingProjectTopologies && !projects.isEmpty ? .loadingProject : .empty
        }
        guard allowedWorktreeIDs?.contains(id) ?? true else { return .empty }
        guard checkoutFocusedWorktreeScope?.worktreeID == id || checkoutFocusedWorktreeScope == nil else { return .empty }
        // Qualified by project: a deletion claim opened for a same-path
        // checkout under another project must not blank this one's pane.
        if let wt = findWorktree(by: id),
           let op = projectsManager.operationState(forWorktreeId: wt.id, projectId: wt.projectId) {
            switch op {
            case .deleting:
                return .deleting(wt)
            case .creating:
                return .creating(wt)
            case .launchFailed:
                break
            case .deleteFailed(let message):
                return .deleteFailed(wt, message: message)
            default:
                break
            }
        }
        if let wt = selectedWorktree() { return .worktree(wt) }
        return .empty
    }

    @MainActor
    private func findWorktree(by id: String) -> Worktree? {
        if let selectedWorktreeProjectId {
            guard projects.contains(where: { $0.id == selectedWorktreeProjectId }) else { return nil }
            return candidateWorktrees(projectId: selectedWorktreeProjectId).first(where: { $0.id == id })
        }
        for project in projects {
            guard matchesCheckoutScope(project: project, worktreeID: id) else { continue }
            if let wt = candidateWorktrees(projectId: project.id).first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }

    @MainActor
    private func selectedWorktree() -> Worktree? {
        guard let id = selectedWorktreeId else { return nil }
        guard let wt = findWorktree(by: id) else { return nil }
        if let op = projectsManager.operationState(forWorktreeId: wt.id, projectId: wt.projectId) {
            switch op {
            case .creating, .deleting, .createFailed:
                return nil
            case .preparingDelete, .launchFailed, .deleteFailed:
                break
            }
        }
        return wt
    }

    @MainActor
    private func candidateWorktrees(projectId: String) -> [Worktree] {
        projectsManager.visibleWorktrees(projectId: projectId)
    }

    private func matchesCheckoutScope(project: ProjectConfig, worktreeID: String) -> Bool {
        guard let scope = checkoutFocusedWorktreeScope else { return true }
        return scope.worktreeID == worktreeID
            && scope.projectID == project.id
            && scope.executionLocation == project.executionLocation
    }
}

extension ProjectConfig {
    var executionLocation: ExecutionLocation {
        host.map(ExecutionLocation.ssh) ?? .local
    }
}
