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
    /// A worktree refusal the user may overrule by asking again with it.
    public enum Overrule: Equatable, Sendable { case force, discardUnsavedEdits }

    public let message: String
    public var overrule: Overrule?

    public init(_ message: String, overrule: Overrule? = nil) {
        self.message = message
        self.overrule = overrule
    }
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
        // Only strings, numbers, arrays and dictionaries: serialization cannot fail.
        envelope(id: id, ["mutateWorktree": [
            "worktree": ["projectID": projectID, "path": path],
            "branch": branch,
            "change": encode(change),
        ]])
    }

    /// Archives session `sessionID` (`HostRequest.archiveSession`); answered like a git action.
    public static func archiveSession(id: Int, sessionID: String) -> OpaqueHostMessage {
        envelope(id: id, ["archiveSession": ["sessionID": sessionID]])
    }

    /// Renames the worktree's branch `from`, as the phone last saw it, to `to`
    /// (`HostRequest.renameBranch`); answered like a git action.
    public static func renameBranch(id: Int, projectID: String, path: String, from: String, to: String) -> OpaqueHostMessage {
        envelope(id: id, ["renameBranch": ["worktree": ["projectID": projectID, "path": path], "from": from, "to": to]])
    }

    /// Archives a worktree as the phone last saw it (`HostRequest.archiveWorktree`).
    public static func archiveWorktree(id: Int, projectID: String, path: String, lineageID: String?, branch: String,
                                       discardUnsavedEdits: Bool) -> OpaqueHostMessage {
        var body: [String: Any] = ["worktree": ["projectID": projectID, "path": path], "branch": branch,
                                   "discardUnsavedEdits": discardUnsavedEdits]
        body["lineageID"] = lineageID
        return envelope(id: id, ["archiveWorktree": body])
    }

    /// Deletes a worktree as the phone last saw it (`HostRequest.deleteWorktree`).
    public static func deleteWorktree(id: Int, projectID: String, path: String, lineageID: String?, branch: String,
                                      force: Bool, deleteBranchIfMerged: Bool, discardUnsavedEdits: Bool) -> OpaqueHostMessage {
        var body: [String: Any] = ["worktree": ["projectID": projectID, "path": path], "branch": branch, "force": force,
                                   "deleteBranchIfMerged": deleteBranchIfMerged, "discardUnsavedEdits": discardUnsavedEdits]
        body["lineageID"] = lineageID
        return envelope(id: id, ["deleteWorktree": body])
    }

    private static func envelope(id: Int, _ request: [String: Any]) -> OpaqueHostMessage {
        let body: [String: Any] = ["version": hostProtocolVersion, "id": id, "request": request]
        return OpaqueHostMessage(json: (try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)) ?? Data())
    }

    /// The outcome `message` reports for request `id`; nil when it answers something else.
    public static func reply(to id: Int, in message: OpaqueHostMessage) -> Result<Void, RemoteGitFailure>? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], response["id"] as? Int == id,
              let result = response["result"] as? [String: Any] else { return nil }
        guard let failure = result["failure"] as? [String: Any] else { return .success(()) }
        let error = failure["error"] as? [String: Any] ?? [:]
        let refusal = worktreeRefusal(error)
        let overrule: RemoteGitFailure.Overrule? = refusal?["needsForce"] != nil ? .force
            : refusal?["unsavedEdits"] != nil ? .discardUnsavedEdits : nil
        return .failure(RemoteGitFailure(Self.message(error), overrule: overrule))
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

    /// A `WorktreeDeletionRefusal` or `WorktreeArchiveRefusal`, keyed by its case.
    private static func worktreeRefusal(_ error: [String: Any]) -> [String: Any]? {
        ((error["worktreeDeletion"] ?? error["worktreeArchive"]) as? [String: Any])?["refusal"] as? [String: Any]
    }

    /// `HostError` as JSON, keyed by its case.
    private static func message(_ error: [String: Any]) -> String {
        if let refusal = worktreeRefusal(error) {
            // A refusal with a reason (changed, needsForce, failed, ownedByWorkspaceCheckout) carries its words.
            if let text = refusal.values.lazy.compactMap({ ($0 as? [String: Any])?.values.first as? String }).first { return text }
            if refusal["mainWorktree"] != nil { return "The main checkout can't be archived or deleted." }
            if refusal["unsavedEdits"] != nil { return "An editor on the machine has unsaved changes in this worktree." }
            if refusal["remoteUnsupported"] != nil { return "Worktrees of remote projects can only be archived or deleted on the Mac." }
            if refusal["operationInProgress"] != nil { return "Wait for the current worktree operation to finish." }
            if refusal["checkpointRecoveryPending"] != nil { return "Recover the interrupted checkpoint restore on the Mac first." }
        }
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
