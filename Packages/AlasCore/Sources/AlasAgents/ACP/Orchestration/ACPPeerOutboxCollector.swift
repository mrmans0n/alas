import Foundation
import OSLog
import AlasModel
import AlasACP

/// Collects the outcomes paired Macs' children left in their outboxes and
/// wakes the parents here. The cursor is durable and moves with the enqueue,
/// so any number of collectors sharing a profile wake a parent once.
///
/// This is the only assignee of the peers' `onOutboxChanged` and
/// `onAvailabilityChanged` slots. Everything else that wants those signals
/// gets them from the callbacks passed in, so the order in which things
/// start does not matter.
@MainActor
public final class ACPPeerOutboxCollector {
    private let peers: ACPDelegationPeers
    private let persistence: ACPOrchestrationPersistence
    private let deliver: @MainActor (_ child: ACPDelegationRecord) async -> Void
    private let parentIsGone: @MainActor (_ child: ACPDelegationRecord) async -> Bool
    private let outboxChanged: @MainActor (_ serverId: String) -> Void
    private let availabilityChanged: @MainActor (_ serverId: String) -> Void
    private let collected: @MainActor (_ entry: ACPPeerOutboxEntry) -> Void
    private let retryStarts: @MainActor (_ serverId: String) async -> Void
    private let schedule: (Int, @escaping @Sendable () async -> Void) -> Void

    private let logger = Logger(subsystem: "io.nlopez.alas", category: "peer-outbox")
    private var pulling: Set<String> = []
    private var queued: Set<String> = []
    private var failedPulls: Set<String> = []
    private var retryArmed: Set<String> = []

    /// How often a live link is asked again while something is left open.
    private static let retrySeconds = 60

    /// - Parameters:
    ///   - deliver: Hands the parent of `child` its waiting messages, attaching
    ///     it if needed. It may take a long time, so a pull never waits for it.
    ///   - parentIsGone: Whether the parent of `child` is known not to exist
    ///     any more. Only a definite answer counts: when in doubt, false.
    ///   - outboxChanged: Also told whenever a peer reports outcomes waiting.
    ///   - availabilityChanged: Also told whenever a peer may have become
    ///     reachable or unreachable.
    ///   - collected: Told about each entry for one of the peer's children
    ///     that was settled here.
    ///   - retryStarts: Asks again about children still starting on a peer.
    ///   - schedule: Arranges for work to run after a number of seconds.
    public init(
        peers: ACPDelegationPeers,
        persistence: ACPOrchestrationPersistence,
        deliver: @escaping @MainActor (_ child: ACPDelegationRecord) async -> Void,
        parentIsGone: @escaping @MainActor (_ child: ACPDelegationRecord) async -> Bool = { _ in false },
        outboxChanged: @escaping @MainActor (_ serverId: String) -> Void = { _ in },
        availabilityChanged: @escaping @MainActor (_ serverId: String) -> Void = { _ in },
        collected: @escaping @MainActor (_ entry: ACPPeerOutboxEntry) -> Void = { _ in },
        retryStarts: @escaping @MainActor (_ serverId: String) async -> Void = { _ in },
        schedule: @escaping (Int, @escaping @Sendable () async -> Void) -> Void = { _, _ in }
    ) {
        self.peers = peers
        self.persistence = persistence
        self.deliver = deliver
        self.parentIsGone = parentIsGone
        self.outboxChanged = outboxChanged
        self.availabilityChanged = availabilityChanged
        self.collected = collected
        self.retryStarts = retryStarts
        self.schedule = schedule
    }

    /// Starts listening, and collects from every peer that is online now: its
    /// channel may have subscribed before anyone was listening.
    public func start() {
        peers.onOutboxChanged = { [weak self] serverId in
            guard let self else { return }
            outboxChanged(serverId)
            collectSoon(serverId)
        }
        peers.onAvailabilityChanged = { [weak self] serverId in
            guard let self else { return }
            availabilityChanged(serverId)
            collectSoon(serverId)
        }
        for peer in peers.peers where peer.state == .online { collectSoon(peer.serverId) }
    }

    private func collectSoon(_ serverId: String) {
        Task { @MainActor [weak self] in await self?.collect(serverId: serverId) }
    }

    /// Pulls and delivers everything `serverId` has waiting. A call during a
    /// pull queues one more pull behind it and returns; the running pull
    /// makes it. A failed page ends the pull with the cursor where it was,
    /// to be tried again by `retryWhileNeeded` or the next signal.
    public func collect(serverId: String) async {
        guard pulling.insert(serverId).inserted else {
            queued.insert(serverId)
            return
        }
        repeat {
            queued.remove(serverId)
            if await pull(serverId) {
                failedPulls.remove(serverId)
            } else {
                failedPulls.insert(serverId)
            }
        } while queued.contains(serverId)
        pulling.remove(serverId)
        await retryWhileNeeded(serverId: serverId)
    }

    /// Arranges to ask an online peer again while a pull failed or a child is
    /// still starting there: with the link up, no signal is coming. A peer that
    /// is down needs no timer, since coming back is a signal. One timer per
    /// peer at a time, and it ends once neither applies.
    public func retryWhileNeeded(serverId: String) async {
        guard !retryArmed.contains(serverId), isOnline(serverId) else { return }
        var needed = failedPulls.contains(serverId)
        if !needed {
            let children = try? await persistence.peerChildren(peerServerId: serverId)
            needed = children?.contains { $0.phase == .starting } == true
        }
        guard needed, isOnline(serverId), retryArmed.insert(serverId).inserted else { return }
        schedule(Self.retrySeconds) { [weak self] in await self?.retry(serverId) }
    }

    private func retry(_ serverId: String) async {
        // Pull first: asking about starts can hold a row for a minute each.
        await collect(serverId: serverId)
        await retryStarts(serverId)
        // Held until here, so a slow retry does not get a second one beside it.
        retryArmed.remove(serverId)
        await retryWhileNeeded(serverId: serverId)
    }

    private func isOnline(_ serverId: String) -> Bool {
        peers.peers.first { $0.serverId == serverId }?.state == .online
    }

    /// False when it stopped on something a retry could get past.
    private func pull(_ serverId: String) async -> Bool {
        let cursor: Int64
        do {
            cursor = try await persistence.peerCursor(peerServerId: serverId)
        } catch {
            logger.error("Could not read the cursor for peer \(serverId, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        var after = cursor
        var gone: [String: Bool] = [:]
        while true {
            // Asking also acknowledges everything through `after`, which is
            // only ever a cursor that is already committed.
            let page: ACPPeerOutboxPage
            switch await peers.outbox(serverId: serverId, after: after) {
            case .success(let answer): page = answer
            case .failure(let error):
                logger.notice("Outbox of peer \(serverId, privacy: .public) not collected after \(after): \(String(describing: error), privacy: .public)")
                return false
            }
            // The whole page is committed before anyone is woken, so a slow
            // parent holds up neither another parent nor the next page.
            var parents: [ACPDelegationRecord] = []
            var stopped = false
            var settled = true
            for entry in page.entries {
                guard entry.seq > after else {
                    logger.error("Peer \(serverId, privacy: .public) sent seq \(entry.seq) after \(after); ignoring the rest")
                    stopped = true
                    break
                }
                guard let child = await settle(entry, from: serverId, gone: &gone) else {
                    stopped = true
                    settled = false
                    break
                }
                if let child, !parents.contains(where: { $0.parentSessionId == child.parentSessionId }) {
                    parents.append(child)
                }
                after = entry.seq
            }
            for child in parents {
                Task { @MainActor [deliver] in await deliver(child) }
            }
            guard !stopped, page.hasMore, !page.entries.isEmpty else { return settled }
        }
    }

    /// Commits one entry. The outer nil means it could not be settled, which
    /// ends the pull; the inner nil means there is nobody to wake for it.
    private func settle(
        _ entry: ACPPeerOutboxEntry, from serverId: String, gone: inout [String: Bool]
    ) async -> ACPDelegationRecord?? {
        do {
            guard let child = try await persistence.delegation(childSessionId: entry.childSessionId),
                  child.peerServerId == serverId
            else {
                // Not one of this peer's children: do not let it block the
                // ones behind it, and never address anyone else's session.
                try await persistence.advancePeerCursor(peerServerId: serverId, to: entry.seq)
                return .some(nil)
            }
            let isGone: Bool
            if let known = gone[child.parentSessionId] {
                isGone = known
            } else {
                isGone = await parentIsGone(child)
                // Only a definite absence is remembered.
                if isGone { gone[child.parentSessionId] = true }
            }
            if isGone {
                try await persistence.advancePeerCursor(peerServerId: serverId, to: entry.seq)
                collected(entry)
                return .some(nil)
            }
            _ = try await persistence.collectPeerEntry(entry, peerServerId: serverId, parentSessionId: child.parentSessionId)
            collected(entry)
            // The parent is woken even when another collector won: delivery
            // is idempotent, and that one may have stopped before it got there.
            return .some(child)
        } catch {
            logger.error("Could not settle entry \(entry.seq) from peer \(serverId, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
