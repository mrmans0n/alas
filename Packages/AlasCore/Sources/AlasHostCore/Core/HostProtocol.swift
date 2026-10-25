import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP
import AlasSessions

/// The host protocol: the messages a client exchanges with `AlasHost` over
/// any transport. A client sends `HostClientMessage`s and receives
/// `HostServerMessage`s: one response per request, matched by id, and the
/// events of its subscription in between. Who the client is comes from the
/// transport, never from a message.
public enum HostProtocolVersion {
    public static let current = 1
}

/// A worktree named the way the host keys its claims: a path can be listed
/// under more than one host's project.
public struct WorktreeRef: Codable, Hashable, Sendable {
    public var projectID: String
    public var path: String

    public init(projectID: String, path: String) {
        self.projectID = projectID
        self.path = path
    }
}

public struct HostClientMessage: Codable, Equatable, Sendable {
    public var version: Int
    /// Echoed on the response, so a client can match it.
    public var id: Int
    public var request: HostRequest

    public init(version: Int = HostProtocolVersion.current, id: Int, request: HostRequest) {
        self.version = version
        self.id = id
        self.request = request
    }
}

public enum HostRequest: Codable, Equatable, Sendable {
    case snapshot
    /// Starts the connection's subscription with the events after `after`,
    /// a cursor from a snapshot. A second subscribe replaces the first.
    case subscribe(after: HostCursor)
    case unsubscribe
    case listSessions
    case addProject(path: String, displayName: String, host: String?, kind: ProjectKind)
    /// Forgets a project. A host before it answers `invalidRequest`.
    case removeProject(projectID: String)
    case createWorktree(projectID: String, base: String, branch: String, destination: String)
    /// `lineageID` and `branch` are the worktree's as the client last saw
    /// it: a checkout replaced or switched since is refused as changed.
    /// `discardUnsavedEdits`: whether the user agreed to discard unsaved
    /// editor changes on the host (`host.worktrees.lifecycle.v1`). Nil from an
    /// older client, refused like false with an untyped message.
    case deleteWorktree(
        worktree: WorktreeRef, lineageID: String?, branch: String, force: Bool, deleteBranchIfMerged: Bool,
        discardUnsavedEdits: Bool? = nil
    )
    /// Like a delete, names the lineage and branch the client last saw, and
    /// acknowledges discarding unsaved editor changes.
    case archiveWorktree(worktree: WorktreeRef, lineageID: String?, branch: String, discardUnsavedEdits: Bool? = nil)
    case unarchiveWorktree(worktree: WorktreeRef)
    /// Renames a listed worktree's branch `from`, the one the client last
    /// saw, to `to`, or a numbered variant when taken, under the local menu's
    /// rules (`host.worktrees.renameBranch.v1`).
    case renameBranch(worktree: WorktreeRef, from: String, to: String)
    case listWorkspaceCheckouts
    case workspaceCheckout(id: UUID)
    case startRun(scriptKey: String, worktree: WorktreeRef)
    case stopRun(scriptKey: String, worktree: WorktreeRef)
    /// The scripts a listed worktree's Run tab lists (`host.runs.scripts.v1`).
    case listRunScripts(worktree: WorktreeRef)
    /// Stops whatever the script's slot holds, then starts it again
    /// (`host.runs.scripts.v1`).
    case restartRun(scriptKey: String, worktree: WorktreeRef)
    case createSession(target: SessionTarget, agentID: String, modelID: String?, autoRun: Bool)
    case sendPrompt(sessionID: String, prompt: String)
    case stopSession(sessionID: String)
    case renameSession(sessionID: String, title: String)
    case archiveSession(sessionID: String)
    case setSessionModel(sessionID: String, modelID: String)
    case setSessionMode(sessionID: String, modeID: String)
    case setSessionConfigOption(sessionID: String, configID: String, value: ACPConfigValue)
    /// Answers the request the subscription announced under `requestID`.
    case answerPermission(sessionID: String, requestID: JSONRPCID, optionID: String, scope: ACPRequestAnswers.PermissionScope)
    case answerQuestion(sessionID: String, requestID: JSONRPCID, answers: [ACPQuestionAnswer])
    case respondToPlan(sessionID: String, requestID: JSONRPCID, action: ACPRequestAnswers.PlanAction)
    case respondToUserInput(sessionID: String, requestID: UUID, answer: ACPRequestAnswers.UserInputAnswer)
    /// Streams the session's transcript and pending requests on the
    /// connection's subscription, which must exist: a new subscription
    /// follows nothing until asked.
    case followSession(sessionID: String, from: TranscriptRevision?)
    case unfollowSession(sessionID: String)
    /// Keeps the worktree's review status refreshed while the connection's
    /// subscription follows it (`host.worktrees.follow.v1`).
    case followWorktree(worktreeID: String)
    case unfollowWorktree(worktreeID: String)
    /// The optional features this host serves, for clients without Remote's
    /// `hello`. A host before them cannot decode it and answers
    /// `invalidRequest`, which a client takes as no extensions.
    case capabilities
    /// Subscribes as `subscribe` does, also sending the event kinds in
    /// `events` that a version 1 client cannot decode (`host.events.v1`).
    case subscribeAccepting(after: HostCursor, events: [String])
    /// What run `runID` of project `projectID` printed, once it finished
    /// (`host.runs.output.v1`).
    case runOutput(runID: String, projectID: String)
    /// A new code a device redeems at the Remote server's `POST /pair`, from
    /// a host that serves Remote headlessly and to a local client only. A
    /// host that serves no Remote, or the app, refuses it.
    case remotePairingCode
    /// The Macs paired with a host that serves Remote headlessly, to a local
    /// client only. A host that serves no Remote, or the app, refuses it.
    case listPeers
    /// Forgets a paired Mac and revokes its token; local client only.
    case forgetPeer(peerID: String)
    /// Reads a listed worktree's code as a session in it would
    /// (`host.worktrees.read.v1`).
    case readWorktree(worktree: WorktreeRef, read: HostWorktreeRead)
    /// Changes a listed worktree on `branch`, the one the client last saw,
    /// as its Changes tab would (`host.worktrees.git.v1`).
    case mutateWorktree(worktree: WorktreeRef, branch: String, change: HostWorktreeChange)
    /// What a commit message is suggested from, for the client's own model
    /// (`host.worktrees.git.v1`).
    case commitMessageInput(worktree: WorktreeRef)
    /// A listed worktree's branch sync and pull request status, read again
    /// first (`host.worktrees.git.v1`).
    case reviewStatus(worktree: WorktreeRef)
    /// A listed worktree's draft reviews, newest first (`host.reviews.v1`).
    case listReviews(worktree: WorktreeRef)
    /// One of them, `sessionID` as listed, with every comment (`host.reviews.v1`).
    case readReview(worktree: WorktreeRef, sessionID: String)
    /// Changes a comment of review `sessionID` (`host.reviews.v1`).
    case mutateReview(worktree: WorktreeRef, sessionID: String, mutation: HostReviewMutation)
}

/// One git action on a worktree. Paths are relative to the worktree, as its
/// changes list them.
public enum HostWorktreeChange: Codable, Equatable, Sendable {
    case stage(paths: [String]), unstage(paths: [String]), discard(paths: [String])
    case commit(subject: String, body: String, amend: Bool)
    case push(forceWithLease: Bool), pull, fetch
}

/// One read of a worktree's code, as the Remote session requests of the same name.
public enum HostWorktreeRead: Codable, Equatable, Sendable {
    case changes(comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case fileDiff(path: String, stage: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case files(path: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case commitFiles(sha: String)
    case commitDiff(sha: String, path: String)
    case file(path: String)
}

/// A draft review as a worktree's Reviews list shows it.
public struct HostReviewSummary: Codable, Equatable, Sendable {
    /// Synthesized, never saved, for a local-changes review with no record.
    public var record: ReviewSessionRecord
    public var openCommentCount: Int
    public var sessionID: String { record.target.draftSessionID.rawValue }

    public init(record: ReviewSessionRecord, openCommentCount: Int) {
        self.record = record
        self.openCommentCount = openCommentCount
    }
}

/// A draft review with its comments, those on files that no longer differ included.
public struct HostReview: Codable, Equatable, Sendable {
    public var summary: HostReviewSummary
    public var comments: [ReviewDraftComment]

    public init(summary: HostReviewSummary, comments: [ReviewDraftComment]) {
        self.summary = summary
        self.comments = comments
    }

    /// Leaves out a comment a newer host sends in a shape this Mac can't read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(HostReviewSummary.self, forKey: .summary)
        comments = try container.decode([Lossy<ReviewDraftComment>].self, forKey: .comments).compactMap(\.value)
    }
}

/// One change to a review's comments, as a paired Mac files it.
public enum HostReviewMutation: Codable, Equatable, Sendable {
    case add(fileID: DiffReviewFileID, path: String, originalPath: String?, anchor: ReviewDraftCommentAnchor, body: String)
    case edit(commentID: String, body: String)
    case delete(commentID: String)
    case resolve(commentID: String)
    case dismiss(commentID: String)
}

/// An element that decodes as nil when it is in a shape this side can't read.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Picked over the generic `decode` by `HostResponse.reviews`'s
    /// synthesized decoding: a review of a kind a newer host added is left
    /// out, not the whole list.
    fileprivate func decode(_ type: [HostReviewSummary].Type, forKey key: Key) throws -> [HostReviewSummary] {
        try decode([Lossy<HostReviewSummary>].self, forKey: key).compactMap(\.value)
    }
}

/// A run script as a worktree's Run tab lists it.
public struct HostRunScript: Codable, Equatable, Sendable {
    public var scope: RunScriptScope
    public var fileName: String
    public var name: String
    /// Working directory relative to the worktree root. Nil = worktree root.
    public var cwd: String?
    /// Where a run executes: the host and working directory.
    public var target: RunExecutionTarget

    public var key: String { "\(scope.rawValue):\(fileName)" }

    public init(scope: RunScriptScope, fileName: String, name: String, cwd: String?, target: RunExecutionTarget) {
        self.scope = scope
        self.fileName = fileName
        self.name = name
        self.cwd = cwd
        self.target = target
    }

    public init(_ script: RunScript, target: RunExecutionTarget) {
        self.init(scope: script.scope, fileName: script.fileName, name: script.displayName, cwd: script.cwd, target: target)
    }
}

/// A paired Mac as `alas-host peers list` shows it; never its token.
public struct HostPeerSummary: Codable, Equatable, Sendable {
    public var id: String
    public var serverId: String
    public var name: String
    public var origins: [String]

    public init(id: String, serverId: String, name: String, origins: [String]) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.origins = origins
    }

    /// The peer `query` names: its id or server id, else a name only one peer has.
    public static func resolve(_ query: String, in peers: [HostPeerSummary]) throws -> HostPeerSummary {
        if let peer = peers.first(where: { $0.id == query || $0.serverId == query }) { return peer }
        let named = peers.filter { $0.name == query }
        if named.count == 1 { return named[0] }
        if named.isEmpty { throw HostError.failed(message: "No paired Mac has the id, name or server id \(query).") }
        let candidates = named.map { "  \($0.id)  \($0.name)" }.joined(separator: "\n")
        throw HostError.failed(message: "More than one paired Mac is named \(query); remove one by id:\n\(candidates)")
    }
}

public enum HostServerMessage: Codable, Equatable, Sendable {
    case response(id: Int, result: HostResponse)
    /// The subscription's next events, coalesced per key, and the cursor
    /// they reach: a client that reconnects subscribes after it.
    case events(events: [HostEvent], cursor: HostCursor)
}

public enum HostResponse: Codable, Equatable, Sendable {
    case snapshot(snapshot: HostSnapshot)
    case subscribed
    case unsubscribed
    case sessions(sessions: [HostSessionSummary])
    case project(project: ProjectSnapshot)
    case worktree(worktree: Worktree)
    /// The verb finished and has nothing to return.
    case done
    case workspaceCheckouts(checkouts: [WorkspaceCheckoutSnapshot])
    case workspaceCheckout(checkout: WorkspaceCheckoutSnapshot)
    case runStart(start: RunStart)
    case session(session: HostSessionSummary)
    case capabilities(capabilities: [String])
    case runOutput(output: HostRunOutput)
    /// `link` is absent from an older host, and where the host has no address for one.
    case remotePairingCode(code: String, expiresAt: Date, link: String?)
    case peers(peers: [HostPeerSummary])
    /// The message a session in the worktree gets for the same read, with
    /// the worktree's id as its `sessionId`. Indirect: a Remote message
    /// carries host messages.
    indirect case worktreeRead(reply: RemoteServerMessage)
    /// The answer to `listRunScripts`.
    case runScripts(scripts: [HostRunScript])
    /// The answer to `commitMessageInput`.
    case commitMessageInput(input: CommitMessageSuggestionInput)
    /// The answer to `reviewStatus`; nil when the host could not read it.
    case reviewStatus(snapshot: ReviewLoopSnapshot?)
    /// The answer to `listReviews`.
    case reviews(reviews: [HostReviewSummary])
    /// The answer to `readReview`.
    case review(review: HostReview)
    case failure(error: HostError)
}

/// Why the host did not do what a request asked: the domain's own typed
/// refusal where there is one.
public enum HostError: Error, Codable, Equatable, Sendable {
    /// The host speaks `supported` and not the message's version.
    case unsupportedVersion(supported: Int)
    case invalidRequest(reason: String)
    /// A project, worktree or script the request names does not exist.
    case notFound(what: String)
    /// Another operation holds the worktree.
    case operationInProgress
    /// A session, run or terminal is live in one of the project's worktrees.
    case projectBusy
    case project(error: ProjectCreationError)
    case worktreeCreation(refusal: WorktreeCreationRefusal)
    case worktreeCreationFailed(message: String)
    case worktreeDeletion(refusal: WorktreeDeletionRefusal)
    case worktreeArchive(refusal: WorktreeArchiveRefusal)
    case workspace(error: WorkspaceAutomationError)
    case session(refusal: SessionRefusal)
    case failed(message: String)
}
