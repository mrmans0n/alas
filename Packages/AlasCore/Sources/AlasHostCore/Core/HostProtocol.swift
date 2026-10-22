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
    case deleteWorktree(worktree: WorktreeRef, lineageID: String?, branch: String, force: Bool, deleteBranchIfMerged: Bool)
    /// Like a delete, names the lineage and branch the client last saw.
    case archiveWorktree(worktree: WorktreeRef, lineageID: String?, branch: String)
    case unarchiveWorktree(worktree: WorktreeRef)
    case listWorkspaceCheckouts
    case workspaceCheckout(id: UUID)
    case startRun(scriptKey: String, worktree: WorktreeRef)
    case stopRun(scriptKey: String, worktree: WorktreeRef)
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
    case remotePairingCode(code: String, expiresAt: Date)
    case peers(peers: [HostPeerSummary])
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
    /// A session or run is live in one of the project's worktrees.
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
