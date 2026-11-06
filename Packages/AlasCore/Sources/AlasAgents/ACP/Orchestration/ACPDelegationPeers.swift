import Foundation
import AlasModel

/// How the orchestration coordinator reaches a paired Mac's host to delegate
/// work to it. `AlasAgents` cannot see the host protocol, so the host layer
/// implements this with plain types. Every call is one request; none retries.
@MainActor
public protocol ACPDelegationPeers: AnyObject {
    /// Every paired Mac, whether or not it can be reached now.
    var peers: [ACPDelegationPeerInfo] { get }
    /// The peer's projects (those whose origin is `repository`, or all when
    /// nil), their worktrees and agents, and what this Mac may do there.
    func discover(serverId: String, repository: String?) async -> Result<ACPPeerDiscovery, ACPPeerError>
    /// Answers once the child's row exists on the peer.
    func start(serverId: String, _ start: ACPPeerChildStartRequest) async -> Result<ACPPeerStartReply, ACPPeerError>
    func send(serverId: String, sessionID: String, prompt: String) async -> Result<Void, ACPPeerError>
    /// `ACPOrchestrationReadResponse`, encoded.
    func read(serverId: String, sessionID: String, offset: Int?, limit: Int?, maxChars: Int?) async -> Result<Data, ACPPeerError>
    /// `ACPOrchestrationWaitResponse`, encoded.
    func status(serverId: String, sessionIDs: [String]) async -> Result<Data, ACPPeerError>
    /// Whether the peer began cancelling the child's running turn.
    func interrupt(serverId: String, sessionID: String) async -> Result<Bool, ACPPeerError>
    /// Outcomes after `after`. Asking also acknowledges everything up to it.
    func outbox(serverId: String, after: Int64) async -> Result<ACPPeerOutboxPage, ACPPeerError>
    /// Told that `serverId` has outcomes waiting in its outbox.
    var onOutboxChanged: (@MainActor (_ serverId: String) -> Void)? { get set }
    /// Told that whether `serverId` can be reached may have changed.
    var onAvailabilityChanged: (@MainActor (_ serverId: String) -> Void)? { get set }
}

public enum ACPPeerError: Error, Equatable, Sendable {
    /// The link is down or unproven, or the peer did not answer.
    case unreachable(peer: String)
    /// The peer answered no, with its reason.
    case refused(String)
    /// The peer has no such child. Proof it is gone, so only a typed
    /// not-found answer produces it.
    case notFound
    /// The peer's build predates delegation.
    case outdated(peer: String)
    /// This Mac's pairing with the peer was revoked or forgotten.
    case revoked(peer: String)
}

public enum ACPDelegationPeerState: String, Equatable, Sendable {
    case online, offline, unverified, incompatible
}

public struct ACPDelegationPeerInfo: Equatable, Sendable {
    public let name: String
    public let serverId: String
    public let state: ACPDelegationPeerState
    public let supportsDelegation: Bool

    public init(name: String, serverId: String, state: ACPDelegationPeerState, supportsDelegation: Bool) {
        self.name = name
        self.serverId = serverId
        self.state = state
        self.supportsDelegation = supportsDelegation
    }
}

/// What a peer offers this Mac's agents.
public struct ACPPeerDiscovery: Equatable, Sendable {
    public struct Project: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Worktree: Equatable, Sendable {
        public let projectID: String
        public let path: String
        public let branch: String
        public let isArchived: Bool

        public init(projectID: String, path: String, branch: String, isArchived: Bool) {
            self.projectID = projectID
            self.path = path
            self.branch = branch
            self.isArchived = isArchived
        }
    }

    public struct Agent: Equatable, Sendable {
        public let id: String
        public let name: String
        public let isDefault: Bool
        /// Projects the agent cannot run in; empty when it runs everywhere.
        public let unavailableProjectIDs: [String]

        public init(id: String, name: String, isDefault: Bool, unavailableProjectIDs: [String]) {
            self.id = id
            self.name = name
            self.isDefault = isDefault
            self.unavailableProjectIDs = unavailableProjectIDs
        }
    }

    /// `off`, `ask` or `autoRun`: what the peer lets this Mac's agents do.
    public let access: String
    public let projects: [Project]
    public let worktrees: [Worktree]
    public let agents: [Agent]

    public init(access: String, projects: [Project], worktrees: [Worktree], agents: [Agent]) {
        self.access = access
        self.projects = projects
        self.worktrees = worktrees
        self.agents = agents
    }
}

public struct ACPPeerChildStartRequest: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case worktree(projectID: String, path: String)
        case newWorktree(projectID: String, branch: String, base: String, expectedBaseSHA: String?)
    }

    /// Minted here; a repeat with the same id finds the same child.
    public let childID: String
    public let target: Target
    public let agentID: String
    public let modelID: String?
    public let reasoning: String?
    public let role: String?
    /// The parent's state; the peer can only lower it.
    public let autoRun: Bool
    public let prompt: String

    public init(
        childID: String, target: Target, agentID: String, modelID: String?, reasoning: String?,
        role: String?, autoRun: Bool, prompt: String
    ) {
        self.childID = childID
        self.target = target
        self.agentID = agentID
        self.modelID = modelID
        self.reasoning = reasoning
        self.role = role
        self.autoRun = autoRun
        self.prompt = prompt
    }
}

public struct ACPPeerStartReply: Equatable, Sendable {
    public let sessionID: String
    /// An `ACPOrchestrationPublicState` raw value.
    public let state: String

    public init(sessionID: String, state: String) {
        self.sessionID = sessionID
        self.state = state
    }
}

public struct ACPPeerOutboxPage: Equatable, Sendable {
    public let entries: [ACPPeerOutboxEntry]
    public let hasMore: Bool

    public init(entries: [ACPPeerOutboxEntry], hasMore: Bool) {
        self.entries = entries
        self.hasMore = hasMore
    }
}
