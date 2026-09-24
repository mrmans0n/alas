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
    }

    /// Drops entries whose downstream deallocated without detaching, then
    /// re-evaluates the poll. Called from every site that reads
    /// `downstreams`, so a leaked entry cannot outlive one round of traffic
    /// and the map cannot grow across server restarts.
    private func pruneDeadDownstreams() {
        for (id, box) in downstreams where box.value == nil { forget(id) }
        updatePollTimer()
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
            links.sendToPeer(message.replacingSessionId(target.sessionId), serverId: target.serverId)
        }
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
                fanOut(.sessionClosed(sessionId: namespaced), to: namespaced)
                subscribers[namespaced] = nil
            default:
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
                fanOut(message.replacingSessionId(namespaced), to: namespaced)
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
            projectId: projectId, worktreeId: worktreeId, updatedAt: updatedAt, worktree: worktree,
            serverId: peer.serverId, serverName: peer.name)
    }

    /// An already-namespaced row with a refreshed owner name.
    func retagged(under peer: FederatedPeerInfo) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: id, title: title, agentId: agentId, status: status, canDrive: canDrive, isActive: isActive,
            projectId: projectId, worktreeId: worktreeId, updatedAt: updatedAt, worktree: worktree,
            serverId: peer.serverId, serverName: peer.name)
    }
}
