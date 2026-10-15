import Foundation

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
    case createWorktree(projectID: String, base: String, branch: String, destination: String)
    /// `lineageID` and `branch` are the worktree's as the client last saw
    /// it: a checkout replaced or switched since is refused as changed.
    case deleteWorktree(worktree: WorktreeRef, lineageID: String?, branch: String, force: Bool, deleteBranchIfMerged: Bool)
    case archiveWorktree(worktree: WorktreeRef)
    case unarchiveWorktree(worktree: WorktreeRef)
    case listWorkspaceCheckouts
    case workspaceCheckout(id: UUID)
    case startRun(scriptKey: String, worktree: WorktreeRef)
    case stopRun(scriptKey: String, worktree: WorktreeRef)
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
    case project(error: ProjectCreationError)
    case worktreeCreation(refusal: WorktreeCreationRefusal)
    case worktreeCreationFailed(message: String)
    case worktreeDeletion(refusal: WorktreeDeletionRefusal)
    case worktreeArchive(refusal: WorktreeArchiveRefusal)
    case workspace(error: WorkspaceAutomationError)
    case failed(message: String)
}
