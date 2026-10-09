import Foundation

/// One gateway's view into federation: where forwarded frames go, and how
/// to tell it the merged session list changed. A gateway creates one in its
/// init, attaches it, and detaches it in `close()`.
@MainActor
final class FederatedDownstream {
    let id = UUID()
    let send: @MainActor (RemoteServerMessage) -> Void
    let sessionListChanged: @MainActor () -> Void

    init(send: @escaping @MainActor (RemoteServerMessage) -> Void,
         sessionListChanged: @escaping @MainActor () -> Void) {
        self.send = send
        self.sessionListChanged = sessionListChanged
    }
}

/// Composes this Mac's peers' sessions into what its own remote clients see.
///
/// Sits beside `RemoteSessionsProvider`, not in front of it: the local
/// provider hands gateways live `ACPSession`s, while a peer's session only
/// ever exists here as wire frames. Each `RemoteSessionGateway` asks
/// `route(_:from:)` first; a message naming a peer session is rewritten to
/// the peer's own id and sent over that peer's link, and everything the peer
/// answers for a subscribed session comes back re-prefixed to every gateway
/// subscribed to it. The peer's own `sessionList` is cached per peer, tagged
/// with its `serverId` and name, and appended to the local list by the
/// gateway.
///
/// The id scheme (`RemoteFederatedSessionID`) never leaves this type. A
/// prefix is only honoured while that peer carries sessions, so an id for a
/// peer that is offline, unverified or forgotten falls through to local
/// handling — where the gateway reports it as closed or refuses the prompt,
/// which is the right answer for a session this Mac cannot reach.
///
/// Every session has one home Mac: writer leases, `canDrive` and permission
/// policy are evaluated there, and this Mac forwards without re-evaluating.
/// This Mac holds one device credential per peer, so its clients share that
/// one lease on the peer; the design accepts that a gateway is a trusted
/// controller.
@MainActor
final class FederatedSessionsProvider {
    static let peerUnavailableMessage = "Peer is unavailable."

    /// How often a peer is re-asked for its list while anyone is attached.
    /// Matches the web client's own idle poll, so a peer's status changes
    /// reach a phone about as fast as its own Mac's do.
    static let listPollInterval: TimeInterval = 15
    /// Several phones polling at once must not turn into a burst upstream.
    static let listRequestThrottle: TimeInterval = 2

    /// Fired whenever any peer's link state or advertised record may have
    /// changed, so the server can push a fresh `hello` (its `peers` list —
    /// `RemotePeerManager.helloPeers` reports every peer's state, not only
    /// the ones carrying sessions) to connected clients. Every call is
    /// already a genuine transition: `reconcilePeers()` only runs in
    /// response to a `RemotePeerManager` signal that itself never repeats
    /// an unchanged state, so this can fire unconditionally rather than
    /// re-deriving a narrower "did the carrying set change" condition that
    /// would miss transitions among peers that were never carrying, and
    /// miss `forget` on one that never was.
    var onPeerAvailabilityChanged: (@MainActor () -> Void)?

    /// Holds a `FederatedDownstream` weakly. This provider does not own
    /// downstream lifetime — the `RemoteSessionGateway` that created one does,
    /// through its own strong `downstream` property — and it outlives every
    /// gateway: it hangs off `AppState.remoteFederation`, which survives each
    /// server start/stop cycle. A connection torn down without a clean
    /// `detach(_:)` must therefore not pin its downstream, its subscriptions
    /// or its share of the idle poll here forever. Entries whose value has
    /// gone are pruned on the next read.
    private struct WeakDownstream {
        weak var value: FederatedDownstream?
    }

    private struct PendingPeerRequests {
        var plan: RemotePlanPayload?
        var elicitation: RemoteElicitationPayload?

        var isEmpty: Bool { plan == nil && elicitation == nil }

        func messages(sessionId: String) -> [RemoteServerMessage] {
            var messages: [RemoteServerMessage] = []
            if let plan { messages.append(.planRequest(sessionId: sessionId, payload: plan)) }
            if let elicitation { messages.append(.elicitationRequest(sessionId: sessionId, payload: elicitation)) }
            return messages
        }
    }
    private enum ComparisonRequestKey: Hashable {
        case changes(sessionId: String)
        case diff(sessionId: String, path: String, stage: String?)
        case commitFiles(sessionId: String, sha: String)
        case commitDiff(sessionId: String, sha: String, path: String)
        case files(sessionId: String, path: String?)

        var sessionId: String {
            switch self {
            case .changes(let sessionId),
                 .diff(let sessionId, _, _),
                 .commitFiles(let sessionId, _),
                 .commitDiff(let sessionId, _, _),
                 .files(let sessionId, _):
                sessionId
            }
        }
    }

    private struct PendingComparisonRequest {
        var downstreamId: UUID?
        let serverId: String
        let message: RemoteClientMessage
    }

    /// The unscoped requests a client can aim at one peer. Their replies carry
    /// no request id, so each kind is answered in the order it was asked.
    private enum PeerRequestKind: Hashable {
        case agents, worktrees, branches, create, createWorktree

        init?(request: RemoteClientMessage) {
            switch request {
            case .listAgents: self = .agents
            case .listWorktrees: self = .worktrees
            case .listBranches: self = .branches
            case .createSession: self = .create
            case .createWorktreeSession: self = .createWorktree
            default: return nil
            }
        }

        init?(reply: RemoteServerMessage) {
            switch reply {
            case .agentList: self = .agents
            case .worktreeList: self = .worktrees
            case .branchList, .branchListFailed: self = .branches
            case .sessionCreated, .createSessionFailed: self = .create
            case .worktreeSessionCreated, .worktreeSessionCreationFailed: self = .createWorktree
            default: return nil
            }
        }
    }

    private struct PeerRequestKey: Hashable {
        let serverId: String
        let kind: PeerRequestKind
    }

    private struct PendingPeerRequest {
        let downstreamId: UUID
        let message: RemoteClientMessage
        /// Nil once the requester detached; the reply is still consumed so
        /// the next requester gets its own answer.
        var reply: (@MainActor (RemoteServerMessage) -> Void)?
    }

    private let links: FederatedPeerLinks
    private var downstreams: [UUID: WeakDownstream] = [:]
    /// Peers that carry sessions right now, by `serverId`.
    private var activePeers: [String: FederatedPeerInfo] = [:]
    /// Each active peer's last list, already loop-guarded, tagged and namespaced.
    private var peerRows: [String: [RemoteSessionSummary]] = [:]
    /// Namespaced session id → downstreams that asked for it.
    private var subscribers: [String: Set<UUID>] = [:]
    /// Active prompt requests received while at least one downstream was subscribed.
    /// A new downstream needs these independently of the upstream gateway's
    /// per-connection request de-duplication.
    private var pendingRequests: [String: PendingPeerRequests] = [:]
    /// Namespaced session id → downstreams waiting on a tab action, oldest
    /// first. The peer answers each action exactly once, in order, so each
    /// reply goes to the head; the asker need not be subscribed. A detached
    /// requester stays as nil so the next reply still lines up.
    private var tabActionRequesters: [String: [UUID?]] = [:]
    /// Comparison-sensitive replies do not carry a request id. Serialize
    /// equivalent requests and return each reply only to its requester.
    private var comparisonRequests: [ComparisonRequestKey: [PendingComparisonRequest]] = [:]
    /// One queue per peer and kind; only the head is outstanding upstream.
    private var peerRequests: [PeerRequestKey: [PendingPeerRequest]] = [:]
    private var pollTimer: Task<Void, Never>?
    private var lastListRequestAt: Date?
    private let now: () -> Date

    init(links: FederatedPeerLinks, now: @escaping () -> Date = { Date() }) {
        self.links = links
        self.now = now
        links.onFederationEvent = { [weak self] event in self?.handle(event) }
        reconcilePeers()
    }

    // MARK: - Downstreams

    func attach(_ downstream: FederatedDownstream) {
        downstreams[downstream.id] = WeakDownstream(value: downstream)
        pruneDeadDownstreams()
    }

    func detach(_ downstream: FederatedDownstream) {
        forget(downstream.id)
        pruneDeadDownstreams()
    }

    /// True while the idle peer-list poll is running: it needs both a live
    /// downstream to tell and a session-carrying peer to ask.
    var isPollingPeerLists: Bool { pollTimer != nil }

    /// Forgets one downstream and everything it had asked for. The clean
    /// `detach(_:)` path and the prune path are deliberately the same code:
    /// a downstream that deallocated is a downstream that left.
    ///
    /// `removeSubscriber` only tells the peer to stop once the session has no
    /// subscriber left, so releasing a gone downstream's interest can never
    /// cancel a surviving downstream's subscription.
    private func forget(_ id: UUID) {
        downstreams[id] = nil
        for (namespaced, ids) in subscribers where ids.contains(id) {
            removeSubscriber(id, from: namespaced)
        }
        removeComparisonRequests(for: id)
        removePeerRequests(for: id)
        for (namespaced, queue) in tabActionRequesters where queue.contains(id) {
            tabActionRequesters[namespaced] = queue.map { $0 == id ? nil : $0 }
        }
    }

    /// Drops entries whose downstream deallocated without detaching, then
    /// re-evaluates the poll. Called from every site that reads
    /// `downstreams`, so a leaked entry cannot outlive one round of traffic
    /// and the map cannot grow across server restarts.
    private func pruneDeadDownstreams() {
        for (id, box) in downstreams where box.value == nil { forget(id) }
        updatePollTimer()
    }

    func peerSupports(_ capability: String, serverId: String) -> Bool {
        links.peerSupports(capability, serverId: serverId)
    }

    /// Peer rows for the merged `sessionList`, grouped by peer name.
    var peerSessionSummaries: [RemoteSessionSummary] {
        activePeers.values
            .sorted { ($0.name, $0.serverId) < ($1.name, $1.serverId) }
            .flatMap { peerRows[$0.serverId] ?? [] }
    }

    /// Routes a client message. Returns true when it was consumed here.
    func route(_ message: RemoteClientMessage, from downstream: FederatedDownstream) -> Bool {
        if case .listSessions = message {
            // The gateway still answers from the local list plus the cache;
            // this only refreshes the cache for next time.
            requestPeerSessionLists()
            return false
        }
        guard let namespaced = message.sessionId,
              let target = RemoteFederatedSessionID.parse(namespaced, peers: Set(activePeers.keys)) else {
            return false
        }
        switch message {
        case .subscribe:
            subscribers[namespaced, default: []].insert(downstream.id)
            for pending in pendingRequests[namespaced]?.messages(sessionId: namespaced) ?? [] {
                downstream.send(pending)
            }
            // Re-asked on every downstream subscribe, even when the session
            // is already subscribed upstream: the peer answers a repeated
            // subscribe with a fresh snapshot, which is exactly what the
            // newcomer needs, and the others apply a snapshot harmlessly.
            links.sendToPeer(.subscribe(sessionId: target.sessionId), serverId: target.serverId)
        case .unsubscribe:
            removeSubscriber(downstream.id, from: namespaced)
        default:
            switch message {
            case .openSessionTab, .closeSessionTab:
                // An older peer would drop the request without a reply.
                guard links.peerSupports(PeerSessionTabsCapability.v1, serverId: target.serverId) else {
                    downstream.send(.sessionTabActionFailed(
                        sessionId: namespaced,
                        message: "\(activePeers[target.serverId]?.name ?? "This Mac") needs a newer Alas to open or close tabs."))
                    return true
                }
                tabActionRequesters[namespaced, default: []].append(downstream.id)
            default:
                break
            }
            let forwarded = message.replacingSessionId(target.sessionId)
            if let key = comparisonRequestKey(for: message, namespacedSessionId: namespaced) {
                var queue = comparisonRequests[key, default: []]
                queue.append(PendingComparisonRequest(
                    downstreamId: downstream.id,
                    serverId: target.serverId,
                    message: forwarded
                ))
                comparisonRequests[key] = queue
                if queue.count == 1 {
                    links.sendToPeer(forwarded, serverId: target.serverId)
                }
            } else {
                links.sendToPeer(forwarded, serverId: target.serverId)
            }
        }
        return true
    }

    /// Sends an unscoped request to one peer and hands its reply to `reply`
    /// only. Returns false when the message is not one of `listAgents`,
    /// `listWorktrees`, `listBranches`, `createSession`,
    /// `createWorktreeSession`, or the peer does not carry sessions.
    func request(_ message: RemoteClientMessage, toPeer serverId: String,
                 from downstream: FederatedDownstream,
                 reply: @escaping @MainActor (RemoteServerMessage) -> Void) -> Bool {
        guard activePeers[serverId] != nil, let kind = PeerRequestKind(request: message) else { return false }
        let key = PeerRequestKey(serverId: serverId, kind: kind)
        var queue = peerRequests[key, default: []]
        queue.append(PendingPeerRequest(downstreamId: downstream.id, message: message, reply: reply))
        peerRequests[key] = queue
        if queue.count == 1 { links.sendToPeer(message, serverId: serverId) }
        return true
    }

    // MARK: - Upstream

    private func handle(_ event: FederatedPeerLinkEvent) {
        switch event {
        case .availabilityChanged:
            reconcilePeers()
        case .message(let serverId, let message):
            guard let peer = activePeers[serverId] else { return }
            switch message {
            case .sessionList(let rows):
                // Loop guard: a row the peer itself forwarded from one of
                // ITS peers already carries a serverId. Only the peer's own
                // rows are re-exported, so A↔B↔C cannot echo sessions
                // around the ring or duplicate them.
                let tagged = rows.filter { $0.serverId == nil }.map { $0.namespaced(under: peer) }
                guard peerRows[serverId] != tagged else { return }
                peerRows[serverId] = tagged
                notifySessionListChanged()
            case .sessionClosed(let sessionId):
                let namespaced = RemoteFederatedSessionID.compose(serverId: serverId, sessionId: sessionId)
                pendingRequests[namespaced] = nil
                comparisonRequests = comparisonRequests.filter { $0.key.sessionId != namespaced }
                fanOut(.sessionClosed(sessionId: namespaced), to: namespaced)
                subscribers[namespaced] = nil
            default:
                if let kind = PeerRequestKind(reply: message) {
                    deliverPeerReply(message, kind: kind, from: peer)
                    return
                }
                guard let sessionId = message.sessionId else { return }
                let namespaced = RemoteFederatedSessionID.compose(serverId: serverId, sessionId: sessionId)
                switch message {
                case .planRequest(_, let payload):
                    pendingRequests[namespaced, default: PendingPeerRequests()].plan = payload
                case .planResolved(_, let requestId):
                    clearPendingPlan(requestId, for: namespaced)
                case .elicitationRequest(_, let payload):
                    pendingRequests[namespaced, default: PendingPeerRequests()].elicitation = payload
                case .elicitationResolved(_, let requestId):
                    clearPendingElicitation(requestId, for: namespaced)
                default:
                    break
                }
                let routed = message.replacingSessionId(namespaced)
                switch message {
                case .sessionTabActionSucceeded, .sessionTabActionFailed:
                    guard var queue = tabActionRequesters[namespaced], !queue.isEmpty else { return }
                    let requester = queue.removeFirst()
                    tabActionRequesters[namespaced] = queue.isEmpty ? nil : queue
                    requester.flatMap { downstreams[$0]?.value }?.send(routed)
                    return
                default:
                    break
                }
                if let key = comparisonResponseKey(for: message, namespacedSessionId: namespaced),
                   deliverComparisonReply(routed, for: key) {
                    return
                }
                fanOut(routed, to: namespaced)
            }
        }
    }

    private func reconcilePeers() {
        let current = Dictionary(links.sessionCarryingPeers.map { ($0.serverId, $0) }, uniquingKeysWith: { $1 })
        let previous = activePeers
        activePeers = current
        var listChanged = false
        for serverId in previous.keys where current[serverId] == nil {
            // Everything this peer was carrying is unreachable now. Its
            // rows leave the list, and every client watching one of its
            // sessions is told it closed — the same thing the peer's own
            // gateway says when a session goes away.
            if peerRows.removeValue(forKey: serverId) != nil { listChanged = true }
            let prefix = RemoteFederatedSessionID.compose(serverId: serverId, sessionId: "")
            for namespaced in subscribers.keys where namespaced.hasPrefix(prefix) {
                fanOut(.sessionClosed(sessionId: namespaced), to: namespaced)
                subscribers[namespaced] = nil
            }
            for namespaced in Array(pendingRequests.keys) where namespaced.hasPrefix(prefix) {
                pendingRequests[namespaced] = nil
            }
            for namespaced in Array(tabActionRequesters.keys) where namespaced.hasPrefix(prefix) {
                let failure = RemoteServerMessage.sessionTabActionFailed(
                    sessionId: namespaced, message: Self.peerUnavailableMessage)
                for id in tabActionRequesters.removeValue(forKey: namespaced) ?? [] {
                    id.flatMap { downstreams[$0]?.value }?.send(failure)
                }
            }
            comparisonRequests = comparisonRequests.filter { !$0.key.sessionId.hasPrefix(prefix) }
            for key in Array(peerRequests.keys) where key.serverId == serverId {
                let pending = peerRequests.removeValue(forKey: key) ?? []
                let failure: RemoteServerMessage
                switch key.kind {
                case .create:
                    failure = .createSessionFailed(message: Self.peerUnavailableMessage)
                case .createWorktree:
                    failure = .worktreeSessionCreationFailed(
                        stage: .worktree, message: Self.peerUnavailableMessage, worktreeId: nil)
                case .agents, .worktrees, .branches:
                    continue
                }
                for request in pending { request.reply?(failure) }
            }
        }
        for serverId in current.keys where previous[serverId] == nil {
            links.sendToPeer(.listSessions, serverId: serverId)
        }
        // A rename reaches here as a changed `name` on the same id.
        for (serverId, peer) in current where previous[serverId] != nil && previous[serverId] != peer {
            if let rows = peerRows[serverId] {
                peerRows[serverId] = rows.map { $0.retagged(under: peer) }
                listChanged = true
            }
        }
        if listChanged { notifySessionListChanged() }
        onPeerAvailabilityChanged?()
        pruneDeadDownstreams()
    }

    private func requestPeerSessionLists() {
        let at = now()
        if let last = lastListRequestAt, at.timeIntervalSince(last) < Self.listRequestThrottle { return }
        lastListRequestAt = at
        for serverId in activePeers.keys {
            links.sendToPeer(.listSessions, serverId: serverId)
        }
    }

    /// Runs only while there is someone to tell and someone to ask. Reads
    /// liveness without mutating `downstreams`, so pruning can call it.
    private func updatePollTimer() {
        let shouldRun = downstreams.values.contains { $0.value != nil } && !activePeers.isEmpty
        if shouldRun, pollTimer == nil {
            pollTimer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Self.listPollInterval * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    // Re-check first: the last downstream may have gone away
                    // with its connection instead of detaching, and this tick
                    // is then the thing that has to stop itself.
                    self.pruneDeadDownstreams()
                    guard !Task.isCancelled else { return }
                    self.requestPeerSessionLists()
                }
            }
        } else if !shouldRun {
            pollTimer?.cancel()
            pollTimer = nil
        }
    }

    private func comparisonRequestKey(
        for message: RemoteClientMessage,
        namespacedSessionId: String
    ) -> ComparisonRequestKey? {
        switch message {
        case .listChanges:
            .changes(sessionId: namespacedSessionId)
        case .fileDiff(_, let path, let stage, _):
            .diff(sessionId: namespacedSessionId, path: path, stage: stage)
        case .listCommitFiles(_, let sha):
            .commitFiles(sessionId: namespacedSessionId, sha: sha)
        case .commitFileDiff(_, let sha, let path):
            .commitDiff(sessionId: namespacedSessionId, sha: sha, path: path)
        case .listFiles(_, let path, _):
            .files(sessionId: namespacedSessionId, path: path)
        default:
            nil
        }
    }

    private func comparisonResponseKey(
        for message: RemoteServerMessage,
        namespacedSessionId: String
    ) -> ComparisonRequestKey? {
        switch message {
        case .changeList, .changeListFailed:
            .changes(sessionId: namespacedSessionId)
        case .fileDiffResult(_, let path, let stage, _, _, _),
             .fileDiffFailed(_, let path, let stage, _, _):
            .diff(sessionId: namespacedSessionId, path: path, stage: stage)
        case .commitFiles(_, let sha, _, _), .commitFilesFailed(_, let sha, _, _):
            .commitFiles(sessionId: namespacedSessionId, sha: sha)
        case .commitDiffResult(_, let sha, let path, _, _, _), .commitDiffFailed(_, let sha, let path, _, _):
            .commitDiff(sessionId: namespacedSessionId, sha: sha, path: path)
        case .fileTree(_, let path, _, _),
             .fileTreeFailed(_, let path, _, _):
            .files(sessionId: namespacedSessionId, path: path)
        default:
            nil
        }
    }

    private func deliverComparisonReply(
        _ message: RemoteServerMessage,
        for key: ComparisonRequestKey
    ) -> Bool {
        guard var queue = comparisonRequests[key], !queue.isEmpty else { return false }
        let completed = queue.removeFirst()
        if let next = queue.first {
            comparisonRequests[key] = queue
            links.sendToPeer(next.message, serverId: next.serverId)
        } else {
            comparisonRequests[key] = nil
        }
        completed.downstreamId.flatMap { downstreams[$0]?.value }?.send(message)
        return true
    }

    private func deliverPeerReply(_ message: RemoteServerMessage, kind: PeerRequestKind, from peer: FederatedPeerInfo) {
        let key = PeerRequestKey(serverId: peer.serverId, kind: kind)
        guard var queue = peerRequests[key], !queue.isEmpty else { return }
        let completed = queue.removeFirst()
        if let next = queue.first {
            peerRequests[key] = queue
            links.sendToPeer(next.message, serverId: peer.serverId)
        } else {
            peerRequests[key] = nil
        }
        switch message {
        case .sessionCreated(let summary):
            completed.reply?(.sessionCreated(session: summary.namespaced(under: peer)))
        case .worktreeSessionCreated(let summary):
            completed.reply?(.worktreeSessionCreated(session: summary.namespaced(under: peer)))
        default:
            completed.reply?(message)
        }
    }

    private func removePeerRequests(for downstreamId: UUID) {
        for key in Array(peerRequests.keys) {
            guard var queue = peerRequests[key], !queue.isEmpty else { continue }
            if queue[0].downstreamId == downstreamId { queue[0].reply = nil }
            queue = [queue[0]] + queue.dropFirst().filter { $0.downstreamId != downstreamId }
            peerRequests[key] = queue
        }
    }

    private func removeComparisonRequests(for downstreamId: UUID) {
        for key in Array(comparisonRequests.keys) {
            guard var queue = comparisonRequests[key], !queue.isEmpty else { continue }
            if queue[0].downstreamId == downstreamId {
                queue[0].downstreamId = nil
            }
            queue = [queue[0]] + queue.dropFirst().filter { $0.downstreamId != downstreamId }
            comparisonRequests[key] = queue
        }
    }

    // MARK: - Fan-out

    private func fanOut(_ message: RemoteServerMessage, to namespaced: String) {
        // Prune first: pruning releases the gone downstreams' subscriptions,
        // so the set read below is the one that still has listeners.
        pruneDeadDownstreams()
        for id in subscribers[namespaced] ?? [] {
            downstreams[id]?.value?.send(message)
        }
    }

    private func removeSubscriber(_ id: UUID, from namespaced: String) {
        guard var ids = subscribers[namespaced], ids.remove(id) != nil else { return }
        if ids.isEmpty {
            subscribers[namespaced] = nil
            // The upstream gateway clears its request de-duplication state on
            // unsubscribe and will re-emit any still-active requests on the
            // next subscribe. Dropping our copy here also avoids replaying a
            // request that resolved while nobody was listening.
            pendingRequests[namespaced] = nil
            if let target = RemoteFederatedSessionID.parse(namespaced, peers: Set(activePeers.keys)) {
                links.sendToPeer(.unsubscribe(sessionId: target.sessionId), serverId: target.serverId)
            }
        } else {
            subscribers[namespaced] = ids
        }
    }

    private func clearPendingPlan(_ requestId: JSONRPCID, for namespaced: String) {
        guard var pending = pendingRequests[namespaced], pending.plan?.requestId == requestId else { return }
        pending.plan = nil
        pendingRequests[namespaced] = pending.isEmpty ? nil : pending
    }

    private func clearPendingElicitation(_ requestId: String, for namespaced: String) {
        guard var pending = pendingRequests[namespaced], pending.elicitation?.requestId == requestId else { return }
        pending.elicitation = nil
        pendingRequests[namespaced] = pending.isEmpty ? nil : pending
    }

    private func notifySessionListChanged() {
        pruneDeadDownstreams()
        for box in downstreams.values { box.value?.sessionListChanged() }
    }
}

private extension RemoteSessionSummary {
    /// The same row under the peer's namespace, tagged with its owner.
    func namespaced(under peer: FederatedPeerInfo) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: RemoteFederatedSessionID.compose(serverId: peer.serverId, sessionId: id),
            title: title, agentId: agentId, status: status, canDrive: canDrive, isActive: isActive,
            tabIndex: tabIndex, projectId: projectId, worktreeId: worktreeId, updatedAt: updatedAt, worktree: worktree,
            serverId: peer.serverId, serverName: peer.name)
    }

    /// An already-namespaced row with a refreshed owner name.
    func retagged(under peer: FederatedPeerInfo) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: id, title: title, agentId: agentId, status: status, canDrive: canDrive, isActive: isActive,
            tabIndex: tabIndex, projectId: projectId, worktreeId: worktreeId, updatedAt: updatedAt, worktree: worktree,
            serverId: peer.serverId, serverName: peer.name)
    }
}
