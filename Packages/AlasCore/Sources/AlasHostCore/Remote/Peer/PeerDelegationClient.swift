import Foundation
import AlasModel
import AlasAgents

/// Sends a paired Mac's host the delegation requests the orchestration
/// coordinator makes, and maps what comes back to `ACPPeerError`. A peer that
/// cannot carry the request gets none: it is unreachable when its link is not
/// proven and online, and outdated when it lacks `host.delegation.v1`.
@MainActor
public final class PeerDelegationClient: ACPDelegationPeers {
    /// `start` answers once the child's row exists, which is quick; the
    /// worktree work continues in the background on the peer. With `discover`,
    /// it runs inside one `session_new`, which must answer within the CLI's
    /// 30-second read, or the agent loses the child's id and may start another.
    static let startTimeout: Duration = .seconds(12)
    static let discoverTimeout: Duration = .seconds(10)

    private let links: FederatedPeerLinks
    private let channel: @MainActor (String) -> PeerHostChannel?

    public var onOutboxChanged: (@MainActor (_ serverId: String) -> Void)?
    public var onAvailabilityChanged: (@MainActor (_ serverId: String) -> Void)?

    public init(links: FederatedPeerLinks, channel: @escaping @MainActor (String) -> PeerHostChannel?) {
        self.links = links
        self.channel = channel
    }

    public var peers: [ACPDelegationPeerInfo] {
        links.helloPeers.map { peer in
            ACPDelegationPeerInfo(
                name: peer.name, serverId: peer.serverId, state: Self.state(of: peer.state),
                supportsDelegation: links.peerSupports(HostProtocolCapability.delegationV1, serverId: peer.serverId)
            )
        }
    }

    /// Every state short of a proven, online link that is not a build problem
    /// is offline for an agent: it cannot be used now.
    static func state(of helloState: String) -> ACPDelegationPeerState {
        switch helloState {
        case "online": .online
        case "unverified": .unverified
        case "incompatible": .incompatible
        default: .offline
        }
    }

    public func discover(serverId: String, repository: String?) async -> Result<ACPPeerDiscovery, ACPPeerError> {
        await ask(serverId, .discover(repository: repository), timeout: Self.discoverTimeout) { response in
            guard case .discovered(let found) = response else { return nil }
            return ACPPeerDiscovery(
                access: found.access.rawValue,
                projects: found.projects.map { .init(id: $0.id, name: $0.name) },
                worktrees: found.worktrees.map {
                    .init(
                        projectID: $0.worktree.projectId, path: $0.worktree.path.path,
                        branch: $0.worktree.branch, isArchived: $0.isArchived
                    )
                },
                agents: found.agents.map {
                    .init(id: $0.id, name: $0.name, isDefault: $0.isDefault, unavailableProjectIDs: $0.unavailableProjectIds ?? [])
                }
            )
        }
    }

    public func start(serverId: String, _ start: ACPPeerChildStartRequest) async -> Result<ACPPeerStartReply, ACPPeerError> {
        let target: HostDelegationTarget = switch start.target {
        case .worktree(let projectID, let path): .worktree(WorktreeRef(projectID: projectID, path: path))
        case .newWorktree(let projectID, let branch, let base, let sha):
            .newWorktree(projectID: projectID, branch: branch, base: base, expectedBaseSHA: sha)
        }
        let request = HostDelegationStart(
            childID: start.childID, target: target, agentID: start.agentID, modelID: start.modelID,
            reasoning: start.reasoning, role: start.role, autoRun: start.autoRun, prompt: start.prompt
        )
        return await ask(serverId, .start(request), timeout: Self.startTimeout) { response in
            guard case .started(let sessionID, let state) = response else { return nil }
            return ACPPeerStartReply(sessionID: sessionID, state: state)
        }
    }

    public func send(serverId: String, sessionID: String, prompt: String) async -> Result<Void, ACPPeerError> {
        switch await perform(serverId, .delegation(.send(sessionID: sessionID, prompt: prompt))) {
        case .failure(let error): return .failure(error)
        case .success(.done): return .success(())
        case .success: return .failure(Self.unexpectedReply)
        }
    }

    public func read(
        serverId: String, sessionID: String, offset: Int?, limit: Int?, maxChars: Int?
    ) async -> Result<Data, ACPPeerError> {
        await ask(serverId, .read(sessionID: sessionID, offset: offset, limit: limit, maxChars: maxChars)) { response in
            guard case .read(let data) = response else { return nil }
            return data
        }
    }

    public func status(serverId: String, sessionIDs: [String]) async -> Result<Data, ACPPeerError> {
        await ask(serverId, .status(sessionIDs: sessionIDs)) { response in
            guard case .status(let data) = response else { return nil }
            return data
        }
    }

    public func interrupt(serverId: String, sessionID: String) async -> Result<Bool, ACPPeerError> {
        await ask(serverId, .interrupt(sessionID: sessionID)) { response in
            guard case .interrupted(let cancelRequested) = response else { return nil }
            return cancelRequested
        }
    }

    public func outbox(serverId: String, after: Int64) async -> Result<ACPPeerOutboxPage, ACPPeerError> {
        await ask(serverId, .outbox(after: after)) { response in
            guard case .outbox(let entries, let hasMore) = response else { return nil }
            return ACPPeerOutboxPage(entries: entries, hasMore: hasMore)
        }
    }

    private static let unexpectedReply = ACPPeerError.refused("The peer sent a reply this Mac did not expect.")

    /// A delegation request whose answer `decode` reads; a reply it cannot is a refusal.
    private func ask<Value>(
        _ serverId: String, _ request: HostDelegationRequest, timeout: Duration? = nil,
        decode: (HostDelegationResponse) -> Value?
    ) async -> Result<Value, ACPPeerError> {
        switch await perform(serverId, .delegation(request), timeout: timeout) {
        case .failure(let error): return .failure(error)
        case .success(.delegation(let response)): return decode(response).map { .success($0) } ?? .failure(Self.unexpectedReply)
        case .success: return .failure(Self.unexpectedReply)
        }
    }

    private func perform(
        _ serverId: String, _ request: HostRequest, timeout: Duration? = nil
    ) async -> Result<HostResponse, ACPPeerError> {
        guard let carrying = links.sessionCarryingPeers.first(where: { $0.serverId == serverId }) else {
            return .failure(.unreachable(peer: name(of: serverId)))
        }
        guard links.peerSupports(HostProtocolCapability.delegationV1, serverId: serverId) else {
            return .failure(.outdated(peer: carrying.name))
        }
        guard let channel = channel(serverId) else { return .failure(.unreachable(peer: carrying.name)) }
        let response = await channel.request(request, timeout: timeout)
        guard case .failure(let error) = response else { return .success(response) }
        return .failure(Self.map(error, peer: carrying.name))
    }

    private func name(of serverId: String) -> String {
        links.helloPeers.first { $0.serverId == serverId }?.name ?? serverId
    }

    /// Only a typed `SessionRefusal.notFound` is `notFound`. The two messages
    /// are the channel's own for a request that got no answer.
    static func map(_ error: HostError, peer: String) -> ACPPeerError {
        switch error {
        case .session(.notFound): .notFound
        case .failed(let message) where message == PeerHostChannel.unansweredMessage
            || message == FederatedSessionsProvider.peerUnavailableMessage:
            .unreachable(peer: peer)
        case .failed(let message): .refused(message)
        case .invalidRequest(let reason): .refused(reason)
        case .session(let refusal): .refused(describe(refusal))
        default: .refused("The peer could not do that.")
        }
    }

    private static func describe(_ refusal: SessionRefusal) -> String {
        switch refusal {
        case .notFound: "No such session."
        case .notWriter: "Another instance or device drives the session."
        case .ownerUnavailable(let reason): reason
        case .agentUnavailable: "The agent is not available there."
        case .notPending: "That request was already answered."
        case .invalidAnswer: "The answer does not fit the request."
        case .promptRejected: "The session did not take the prompt."
        case .invalidSetting: "The session does not offer that setting."
        }
    }
}
