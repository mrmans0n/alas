import Foundation

/// Any host-protocol `readWorktree`, for a client that carries it as `OpaqueHostMessage`.
/// The JSON matches `HostWorktreeRead`'s synthesized coding; absent optionals are omitted.
public enum RemoteWorktreeRead {
    public enum Read: Equatable, Sendable {
        case changes(comparisonMode: ChangesComparisonMode?)
        case fileDiff(path: String, stage: String?, comparisonMode: ChangesComparisonMode?)
        case files(path: String?)
        case commitFiles(sha: String)
        case commitDiff(sha: String, path: String)
        case file(path: String)
        case fileHistory(path: String)

        fileprivate var json: [String: Any] {
            switch self {
            case .changes(let mode): ["changes": Self.compact(["comparisonMode": mode?.rawValue])]
            case .fileDiff(let path, let stage, let mode):
                ["fileDiff": Self.compact(["path": path, "stage": stage, "comparisonMode": mode?.rawValue])]
            case .files(let path): ["files": Self.compact(["path": path])]
            case .commitFiles(let sha): ["commitFiles": ["sha": sha]]
            case .commitDiff(let sha, let path): ["commitDiff": ["sha": sha, "path": path]]
            case .file(let path): ["file": ["path": path]]
            case .fileHistory(let path): ["fileHistory": ["path": path]]
            }
        }

        private static func compact(_ fields: [String: Any?]) -> [String: Any] { fields.compactMapValues { $0 } }
    }

    public static func request(id: Int, projectID: String, path: String, read: Read) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["readWorktree": [
            "worktree": ["projectID": projectID, "path": path],
            "read": read.json,
        ]])
    }

    /// The inner server message answering `id`, or the host's refusal; nil when `message` answers something else.
    /// An answer to `id` that can't be read fails, so whoever waits for it stops waiting.
    public static func reply(to id: Int, in message: OpaqueHostMessage)
        -> Result<RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>, RemoteGitFailure>? {
        guard let result = RemoteGitRequest.responseResult(in: message, matching: id) else { return nil }
        if case .failure(let failure)? = RemoteGitRequest.reply(to: id, in: message), result["failure"] != nil {
            return .failure(failure)
        }
        guard let reply = (result["worktreeRead"] as? [String: Any])?["reply"],
              let data = try? JSONSerialization.data(withJSONObject: reply),
              let decoded = try? JSONDecoder().decode(RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>.self, from: data)
        else { return .failure(RemoteGitFailure("The machine's answer couldn't be read.")) }
        return .success(decoded)
    }
}
