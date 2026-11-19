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
    /// The `index`th hunk of `path`'s diff as the phone was shown it: the unstaged diff to stage or
    /// discard it, the staged one to unstage it.
    case hunk(path: String, index: Int, header: String, linesHash: String, action: RemoteHunkAction)
}

public enum RemoteHunkAction: String, Sendable { case stage, unstage, discard }

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

/// A worktree's pull request as `reviewStatus` reports it: the part of `ReviewRequest` the phone shows.
public struct RemotePullRequest: Decodable, Equatable, Sendable {
    public struct Check: Decodable, Equatable, Sendable {
        public let name: String
        /// `ReviewCheckBucket`: pass, fail, pending, skipping, cancel or unknown.
        public let bucket: String
        public let detailURL: URL?
    }

    public let number: Int
    public let title: String
    public let url: URL
    /// `ReviewRequestState`: open, closed or merged.
    public let state: String
    public let isDraft: Bool
    /// `ReviewDecision`: approved, changesRequested, reviewRequired or unknown.
    public let reviewDecision: String
    public let checks: [Check]
}

/// A worktree's run script, as `listRunScripts` reports it.
public struct RemoteRunScript: Equatable, Sendable {
    /// `HostRunScript.key`, which run requests name.
    public let key: String
    public let name: String
}

public enum RemoteRunAction: Sendable { case start, restart, stop }

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

    /// Reads the worktree's branch sync and pull request again (`HostRequest.reviewStatus`).
    public static func reviewStatus(id: Int, projectID: String, path: String) -> OpaqueHostMessage {
        envelope(id: id, ["reviewStatus": ["worktree": ["projectID": projectID, "path": path]]])
    }

    /// The pull request in the `reviewStatus` reply to `id`: `.some(nil)` when the worktree has none
    /// or the host couldn't read it, nil when `message` answers something else.
    public static func pullRequest(replying id: Int, in message: OpaqueHostMessage) -> RemotePullRequest?? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], response["id"] as? Int == id,
              let result = response["result"] as? [String: Any] else { return nil }
        guard let raw = ((result["reviewStatus"] as? [String: Any])?["snapshot"] as? [String: Any])?["reviewRequest"],
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return .some(nil) }
        return .some(try? JSONDecoder().decode(RemotePullRequest.self, from: data))
    }

    /// The worktree's run scripts (`HostRequest.listRunScripts`).
    public static func listRunScripts(id: Int, projectID: String, path: String) -> OpaqueHostMessage {
        envelope(id: id, ["listRunScripts": ["worktree": ["projectID": projectID, "path": path]]])
    }

    /// Starts, restarts or stops a run script (`startRun`, `restartRun`, `stopRun`); answered like a
    /// git action, a launch the host refused included.
    public static func run(id: Int, _ action: RemoteRunAction, scriptKey: String, projectID: String, path: String) -> OpaqueHostMessage {
        let verb = switch action {
        case .start: "startRun"
        case .restart: "restartRun"
        case .stop: "stopRun"
        }
        return envelope(id: id, [verb: ["scriptKey": scriptKey, "worktree": ["projectID": projectID, "path": path]]])
    }

    /// The scripts in the `listRunScripts` reply to `id`: empty when the host refused, nil when
    /// `message` answers something else.
    public static func runScripts(replying id: Int, in message: OpaqueHostMessage) -> [RemoteRunScript]? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], response["id"] as? Int == id,
              let result = response["result"] as? [String: Any] else { return nil }
        let scripts = (result["runScripts"] as? [String: Any])?["scripts"] as? [[String: Any]] ?? []
        return scripts.compactMap { script in
            guard let scope = script["scope"] as? String, let file = script["fileName"] as? String,
                  let name = script["name"] as? String else { return nil }
            return RemoteRunScript(key: "\(scope):\(file)", name: name)
        }
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
        // A launch the host refused still answers `runStart`.
        if let start = (result["runStart"] as? [String: Any])?["start"] as? [String: Any] {
            if let refused = start["refused"] as? [String: Any] {
                return .failure(RemoteGitFailure(refused["message"] as? String ?? "The machine didn't start it."))
            }
            if start["alreadyStarting"] != nil { return .failure(RemoteGitFailure("It's already starting.")) }
            if start["projectUnavailable"] != nil { return .failure(RemoteGitFailure("Its project is no longer on the machine.")) }
        }
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
        case .hunk(let path, let index, let header, let linesHash, let action):
            ["hunk": ["path": path, "stage": action == .unstage ? "staged" : "unstaged", "index": index, "header": header,
                      "linesHash": linesHash, "action": action.rawValue]]
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
            if refusal["notWriter"] != nil { return "Take over this session first." }
            if refusal["notFound"] != nil { return "Its machine no longer lists this session." }
            if refusal["promptRejected"] != nil { return "The session didn't take the prompt." }
        }
        return "The machine couldn't do that."
    }
}
