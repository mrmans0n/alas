import Foundation

/// A file's commit history as a host-protocol `readWorktree` (`host.worktrees.fileHistory.v1`),
/// for a client that carries it as `OpaqueHostMessage`.
public enum RemoteFileHistoryRequest {
    public static func request(id: Int, projectID: String, worktreePath: String, path: String) -> OpaqueHostMessage {
        RemoteWorktreeRead.request(id: id, projectID: projectID, path: worktreePath, read: .fileHistory(path: path))
    }

    /// The history in the reply to `id`; nil when `message` answers something else.
    public static func result(replying id: Int, in message: OpaqueHostMessage) -> RemoteFileHistoryResult? {
        switch RemoteWorktreeRead.reply(to: id, in: message) {
        case nil: return nil
        case .failure(let failure)?: return .failure(reason: .unknown, message: failure.message)
        case .success(let decoded)?:
            switch decoded {
            case .fileHistory(_, _, let entries, let truncated): return .success(entries: entries, truncated: truncated)
            case .fileHistoryFailed(_, _, let reason, let message): return .failure(reason: reason, message: message)
            default: return nil
            }
        }
    }
}
