import Foundation

/// A git action on a worktree, as the phone offers them: no amend, no force push.
public enum RemoteGitChange: Equatable, Sendable {
    case stage(paths: [String])
    case unstage(paths: [String])
    case discard(paths: [String])
    case commit(subject: String, body: String)
    case push
    case pull
    case fetch
}

/// Why the host refused a git action, worded for the user.
public struct RemoteGitFailure: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

/// Git actions as host-protocol messages, for a client that can't link
/// AlasHostCore and so carries them as `OpaqueHostMessage`. The JSON is
/// `HostClientMessage` with `HostRequest.mutateWorktree`, and the reply a
/// `HostServerMessage.response`; a test in AlasCore pins both shapes.
public enum RemoteGitRequest {
    /// `HostProtocolVersion.current`.
    public static let hostProtocolVersion = 1

    public static func message(id: Int, projectID: String, path: String, branch: String,
                               change: RemoteGitChange) -> OpaqueHostMessage {
        let body: [String: Any] = [
            "version": hostProtocolVersion,
            "id": id,
            "request": ["mutateWorktree": [
                "worktree": ["projectID": projectID, "path": path],
                "branch": branch,
                "change": encode(change),
            ]],
        ]
        // Only strings, numbers, arrays and dictionaries: serialization cannot fail.
        return OpaqueHostMessage(json: (try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)) ?? Data())
    }

    /// The outcome `message` reports for request `id`; nil when it answers something else.
    public static func reply(to id: Int, in message: OpaqueHostMessage) -> Result<Void, RemoteGitFailure>? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], response["id"] as? Int == id,
              let result = response["result"] as? [String: Any] else { return nil }
        guard let failure = result["failure"] as? [String: Any] else { return .success(()) }
        return .failure(RemoteGitFailure(Self.message(failure["error"] as? [String: Any] ?? [:])))
    }

    private static func encode(_ change: RemoteGitChange) -> [String: Any] {
        switch change {
        case .stage(let paths): ["stage": ["paths": paths]]
        case .unstage(let paths): ["unstage": ["paths": paths]]
        case .discard(let paths): ["discard": ["paths": paths]]
        case .commit(let subject, let body): ["commit": ["subject": subject, "body": body, "amend": false]]
        case .push: ["push": ["forceWithLease": false]]
        case .pull: ["pull": [String: Any]()]
        case .fetch: ["fetch": [String: Any]()]
        }
    }

    /// `HostError` as JSON, keyed by its case.
    private static func message(_ error: [String: Any]) -> String {
        if let failed = error["failed"] as? [String: Any], let message = failed["message"] as? String { return message }
        if let invalid = error["invalidRequest"] as? [String: Any], let reason = invalid["reason"] as? String { return reason }
        if error["operationInProgress"] != nil { return "Another operation is running in this worktree. Try again when it finishes." }
        if error["notFound"] != nil { return "This worktree is no longer on its machine." }
        if let refusal = (error["session"] as? [String: Any])?["refusal"] as? [String: Any] {
            if refusal["notWriter"] != nil { return "Another device is driving this session." }
            if refusal["notFound"] != nil { return "Its machine no longer lists this session." }
            if refusal["promptRejected"] != nil { return "The session didn't take the prompt." }
        }
        return "The machine couldn't do that."
    }
}
