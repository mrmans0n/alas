import Foundation
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
    private let deliver: @MainActor (_ parentSessionId: String) async -> Void
    private let outboxChanged: @MainActor (_ serverId: String) -> Void
    private let availabilityChanged: @MainActor (_ serverId: String) -> Void

    private var pulling: Set<String> = []
    private var queued: Set<String> = []

    /// - Parameters:
    ///   - deliver: Hands a parent its waiting messages, attaching it if needed.
    ///   - outboxChanged: Also told whenever a peer reports outcomes waiting.
    ///   - availabilityChanged: Also told whenever a peer may have become
    ///     reachable or unreachable.
    public init(
        peers: ACPDelegationPeers,
        persistence: ACPOrchestrationPersistence,
        deliver: @escaping @MainActor (_ parentSessionId: String) async -> Void,
        outboxChanged: @escaping @MainActor (_ serverId: String) -> Void = { _ in },
        availabilityChanged: @escaping @MainActor (_ serverId: String) -> Void = { _ in }
    ) {
        self.peers = peers
        self.persistence = persistence
        self.deliver = deliver
        self.outboxChanged = outboxChanged
        self.availabilityChanged = availabilityChanged
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
    /// and nothing retries until the next signal.
    public func collect(serverId: String) async {
        guard pulling.insert(serverId).inserted else {
            queued.insert(serverId)
            return
        }
        defer { pulling.remove(serverId) }
        repeat {
            queued.remove(serverId)
            await pull(serverId)
        } while queued.contains(serverId)
    }

    private func pull(_ serverId: String) async {
        guard var after = try? await persistence.peerCursor(peerServerId: serverId) else { return }
        while true {
            // Asking also acknowledges everything through `after`, which is
            // only ever a cursor that is already committed.
            guard case .success(let page) = await peers.outbox(serverId: serverId, after: after) else { return }
            for entry in page.entries {
                guard await collect(entry, from: serverId) else { return }
                after = entry.seq
            }
            guard page.hasMore, !page.entries.isEmpty else { return }
        }
    }

    /// False when the entry could not be settled, which ends the pull.
    private func collect(_ entry: ACPPeerOutboxEntry, from serverId: String) async -> Bool {
        do {
            guard let child = try await persistence.delegation(childSessionId: entry.childSessionId),
                  child.peerServerId == serverId
            else {
                // Nobody here to wake: do not let it block the ones behind it.
                try await persistence.advancePeerCursor(peerServerId: serverId, to: entry.seq)
                return true
            }
            _ = try await persistence.collectPeerEntry(entry, peerServerId: serverId, parentSessionId: child.parentSessionId)
            // Also when another collector won: delivery is idempotent, and
            // that one may have stopped before it got here.
            await deliver(child.parentSessionId)
            return true
        } catch {
            return false
        }
    }
}
