import Foundation

/// A file's commit history as a host-protocol `readWorktree` (`host.worktrees.fileHistory.v1`),
/// for a client that carries it as `OpaqueHostMessage`.
public enum RemoteFileHistoryRequest {
    public static func request(id: Int, projectID: String, worktreePath: String, path: String) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["readWorktree": [
            "worktree": ["projectID": projectID, "path": worktreePath],
            "read": ["fileHistory": ["path": path]],
        ]])
    }

    /// The history in the reply to `id`; nil when `message` answers something else.
    public static func result(replying id: Int, in message: OpaqueHostMessage) -> RemoteFileHistoryResult? {
        guard let result = RemoteGitRequest.responseResult(in: message, matching: id) else { return nil }
        if case .failure(let failure)? = RemoteGitRequest.reply(to: id, in: message), result["failure"] != nil {
            return .failure(reason: .unknown, message: failure.message)
        }
        guard let reply = (result["worktreeRead"] as? [String: Any])?["reply"],
              let data = try? JSONSerialization.data(withJSONObject: reply),
              let decoded = try? JSONDecoder().decode(RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>.self, from: data)
        else { return nil }
        switch decoded {
        case .fileHistory(_, _, let entries, let truncated): return .success(entries: entries, truncated: truncated)
        case .fileHistoryFailed(_, _, let reason, let message): return .failure(reason: reason, message: message)
        default: return nil
        }
    }
}
