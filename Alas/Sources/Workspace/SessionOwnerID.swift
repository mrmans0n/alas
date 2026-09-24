import Foundation

/// Identifies the durable owner of shared session state.
///
/// Worktrees intentionally retain their historical raw path IDs so existing
/// tab, zmx, and ACP storage remains byte-for-byte compatible. Checkout
/// owners include both their snapshot UUID and execution location because the
/// same checkout path can exist on different hosts.
enum SessionOwnerID: Hashable, Sendable {
    case worktree(String)
    /// ACP history for a worktree is project-scoped because the same remote
    /// absolute path can be present on multiple SSH hosts.
    case projectWorktree(projectId: String, worktreeId: String)
    case workspaceCheckout(UUID, ExecutionLocation)

    /// Repository-specific compatibility APIs may only derive a target from a
    /// real worktree owner. Checkout-owned shared sessions intentionally have
    /// no implicit repository target.
    var worktreeID: String? {
        switch self {
        case .worktree(let id), .projectWorktree(_, let id): id
        case .workspaceCheckout: nil
        }
    }

    var projectID: String? {
        guard case .projectWorktree(let projectId, _) = self else { return nil }
        return projectId
    }

    /// Worktree tabs remain stored under the path-derived ID used by the
    /// worktree APIs. ACP persistence derives a project-scoped database name.
    var tabStorageKey: String {
        switch self {
        case .worktree(let id), .projectWorktree(_, let id): id
        case .workspaceCheckout: storageKey
        }
    }

    var checkoutExecutionLocation: ExecutionLocation? {
        guard case .workspaceCheckout(_, let location) = self else { return nil }
        return location.normalized
    }

    var storageKey: String {
        switch self {
        case .worktree(let id):
            id
        case .projectWorktree(let projectId, let worktreeId):
            "project-worktree--\(storageComponent(projectId))--\(storageComponent(worktreeId))"
        case .workspaceCheckout(let id, let location):
            "workspace-checkout--\(id.uuidString.lowercased())--\(locationStorageComponent(location))"
        }
    }

    static func == (lhs: SessionOwnerID, rhs: SessionOwnerID) -> Bool {
        switch (lhs, rhs) {
        case (.worktree(let lhs), .worktree(let rhs)):
            lhs == rhs
        case let (.projectWorktree(lhsProjectId, lhsWorktreeId), .projectWorktree(rhsProjectId, rhsWorktreeId)):
            lhsProjectId == rhsProjectId && lhsWorktreeId == rhsWorktreeId
        case (.workspaceCheckout(let lhsID, let lhsLocation), .workspaceCheckout(let rhsID, let rhsLocation)):
            lhsID == rhsID && lhsLocation.normalized == rhsLocation.normalized
        default:
            false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .worktree(let id):
            hasher.combine(0)
            hasher.combine(id)
        case .projectWorktree(let projectId, let worktreeId):
            hasher.combine(1)
            hasher.combine(projectId)
            hasher.combine(worktreeId)
        case .workspaceCheckout(let id, let location):
            hasher.combine(2)
            hasher.combine(id)
            switch location.normalized {
            case .local:
                hasher.combine(0)
            case .ssh(let destination):
                hasher.combine(1)
                hasher.combine(destination)
            }
        }
    }

    private func locationStorageComponent(_ location: ExecutionLocation) -> String {
        let raw: String
        switch location.normalized {
        case .local:
            raw = "local"
        case .ssh(let destination):
            raw = "ssh:\(destination)"
        }
        return storageComponent(raw)
    }

    private func storageComponent(_ raw: String) -> String {
        Data(raw.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
