import Foundation

enum RightPaneSelectionState: Equatable {
    case empty
    case active(Worktree)
    case creating(Worktree)
    case createFailed(Worktree)
    /// A peer session is selected. `selectedWorktreeId` still holds the last
    /// local worktree, which must not be shown in its place.
    case peer(sessionId: String)

    var showsRightPane: Bool {
        switch self {
        case .empty:
            false
        case .active, .creating, .createFailed, .peer:
            true
        }
    }
}

struct RightPaneSelectionStateResolver {
    let selectedWorktreeId: String?
    let projects: [ProjectConfig]
    let projectsManager: ProjectsManager
    /// See `CenterSelectionStateResolver.allowedWorktreeIDs`.
    var allowedWorktreeIDs: Set<String>? = nil
    var checkoutFocusedWorktreeScope: CheckoutFocusedWorktreeScope? = nil
    var peerSessionId: String? = nil
    /// Meaningful only when `peerSessionId` is set. A peer session with no
    /// assigned worktree can't serve changes or files — the peer answers
    /// `worktreeUnavailable` for both — so the rail hides rather than
    /// filling with error messages, or worse, falling through to show
    /// whatever local worktree happened to be selected before.
    var peerSessionHasWorktree: Bool = true
    /// A peer console, or a peer worktree with no tab open, fills the center
    /// pane. It has no worktree on this Mac, so the rail hides instead of
    /// showing the stale local selection.
    var peerSelectedWithoutSession: Bool = false

    @MainActor
    func resolve() -> RightPaneSelectionState {
        if peerSelectedWithoutSession { return .empty }
        if let peerSessionId {
            return peerSessionHasWorktree ? .peer(sessionId: peerSessionId) : .empty
        }
        guard let id = selectedWorktreeId else { return .empty }
        guard allowedWorktreeIDs?.contains(id) ?? true else { return .empty }
        guard checkoutFocusedWorktreeScope?.worktreeID == id || checkoutFocusedWorktreeScope == nil else { return .empty }
        guard let wt = findWorktree(by: id) else { return .empty }
        if let op = projectsManager.operationState(forWorktreeId: wt.id, projectId: wt.projectId) {
            switch op {
            case .preparingDelete:
                return .active(wt)
            case .creating:
                return .creating(wt)
            case .deleting:
                // The worktree is being removed. Returning `.empty` unmounts
                // the right pane (rail included) for this deletion only; the
                // global `rightPaneVisible` preference is untouched, so the
                // sibling the selection reconciles to reopens the pane. A
                // claim opened for a same-path checkout under another project
                // is filtered out by the qualified lookup above.
                return .empty
            case .createFailed:
                return .createFailed(wt)
            case .launchFailed, .deleteFailed:
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
            if let scope = checkoutFocusedWorktreeScope,
               (scope.projectID != project.id || scope.executionLocation != project.executionLocation) {
                continue
            }
            if let wt = projectsManager.visibleWorktrees(projectId: project.id).first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }
}
