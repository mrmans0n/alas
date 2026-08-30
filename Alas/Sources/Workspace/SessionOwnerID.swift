import Foundation

/// Identifies the durable owner of shared session state.
///
/// Worktrees intentionally retain their historical raw path IDs so existing
/// tab, zmx, and ACP storage remains byte-for-byte compatible. Checkout
/// owners include both their snapshot UUID and execution location because the
/// same checkout path can exist on different hosts.
enum SessionOwnerID: Hashable, Sendable {
    case worktree(String)
    case workspaceCheckout(UUID, ExecutionLocation)

    var storageKey: String {
        switch self {
        case .worktree(let id):
            id
        case .workspaceCheckout(let id, let location):
            "workspace-checkout--\(id.uuidString.lowercased())--\(locationStorageComponent(location))"
        }
    }

    static func == (lhs: SessionOwnerID, rhs: SessionOwnerID) -> Bool {
        switch (lhs, rhs) {
        case (.worktree(let lhs), .worktree(let rhs)):
            lhs == rhs
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
        case .workspaceCheckout(let id, let location):
            hasher.combine(1)
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
        return Data(raw.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
