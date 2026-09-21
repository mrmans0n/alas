import Foundation
import Observation

/// Owns this Mac's outbound peers: the persisted records, one link each, and
/// both halves of reciprocal pairing. Session traffic over the links is
/// consumed by a later `FederatedSessionsProvider`; for now `.message`
/// events are dropped.
///
/// **The owner must call `disconnectAll()` before releasing this manager.**
/// It holds a `RemotePeerConnection` per peer, and dropping the last reference
/// to one of those is not enough to close it: a connected link keeps itself,
/// its task, and an authenticated socket to the peer alive until `disconnect()`
/// is called. Releasing the manager without `disconnectAll()` leaks one of each
/// per connected peer.
@MainActor
@Observable
final class RemotePeerManager {
    struct LocalIdentity: Equatable, Sendable {
        let serverId: String
        let name: String
        let origins: [String]
    }

    enum AddError: Error, Equatable {
        case invalidLink
        case expiredCode
        case originRejected
        case unreachable
        /// This Mac advertises no address a peer could dial back on, so the
        /// exchange cannot complete even if the far side is reachable.
        case noLocalAddress
        /// The far side's reciprocal pair-back was never confirmed within
        /// `addPeer`'s wait: it neither redeemed our counter-code (which
        /// would have set `localDeviceId`) nor gave any other signal, because
        /// a failed pair-back on its end produces no error message routed
        /// back to us — only silence. The half-completed peer has already
        /// been forgotten.
        case reciprocalPairingFailed
        /// The peer this link was re-pairing was forgotten while the network
        /// round trip was still in flight. Reporting either success or a
        /// pairing failure would misrepresent what happened — the user's own
        /// Forget is why nothing was added, not anything about the exchange.
        case cancelled
    }

    typealias MakeConnection = @MainActor (RemotePeer, @escaping @MainActor (RemotePeerConnection.Event) -> Void) -> any RemotePeerConnecting

    private(set) var peers: [RemotePeer]
    private(set) var states: [String: RemotePeerConnection.State] = [:]
    /// Called with a `RemoteDevice.id` when forgetting a peer should also cut
    /// its live inbound socket. `AppState` points this at
    /// `RemoteServer.disconnectDevice`, which is what makes `forget` sever a
    /// peer's access immediately: revoking the device record alone would leave
    /// an already-open socket authorized until it happened to close.
    @ObservationIgnored var onRevokeDevice: (@MainActor (String) -> Void)?

    private let store: RemotePeerStore
    private let pairing: RemotePairingService
    private let pairer: RemotePeerPairer
    private let localIdentity: @MainActor () -> LocalIdentity
    private let makeConnection: MakeConnection
    private let now: () -> Date
    /// How long `addPeer` waits for A's reciprocal call to redeem our
    /// counter-code before giving up and reporting failure. Real wall-clock
    /// time — never `now()`, which tests freeze — so a confirmation that
    /// already landed resolves with no real wait, and one that never lands
    /// times out for real rather than spinning forever. Must cover the
    /// reciprocal pairer's own worst case: up to `RemoteHTTPResponder`'s
    /// 8-origin cap, each tried with `RemotePeerPairer`'s 4s per-origin
    /// timeout, i.e. up to 32s — a shorter window would report a
    /// legitimately-slow-but-working exchange as failed. 35s leaves a
    /// margin above that ceiling without making a genuinely dead exchange
    /// hang the UI far longer than the worst case that can still succeed.
    private let reciprocalConfirmationTimeout: TimeInterval
    /// Reciprocal confirmations that arrived before the local record they
    /// belong to existed, keyed by the counter-code they redeemed — NOT by
    /// `serverId`. A's reciprocal call competes with A's own reply to our
    /// original request — A schedules it right after redeeming our code,
    /// before A's HTTP response has even finished transmitting — so it can
    /// land on our `/pair` endpoint before our own `addPeer` has returned
    /// from the network call that will create this record. Without
    /// buffering, `handleInboundPeer`'s lookup finds nothing and silently
    /// drops the only confirmation this attempt will ever get.
    ///
    /// Keying by `serverId` alone is not enough: if an EARLIER attempt for
    /// the same peer sent its counter-code, got a reciprocal callback back
    /// (which buffers here), but then lost its OWN `/pair` reply to a
    /// network glitch, `addPeer` for that attempt returns early and never
    /// reaches `upsert` — leaving this entry unconsumed. A LATER, unrelated
    /// retry for the SAME peer, still well within any reasonable time
    /// window, would then wrongly adopt that stale entry as its own
    /// confirmation, even though ITS OWN reciprocal leg might still fail.
    /// Keying by the counter-code itself — a fresh, unique value `addPeer`
    /// mints for every attempt — means only the confirmation an attempt's
    /// own counter-code actually earns can ever satisfy it.
    ///
    /// `waitForReciprocalRedemption` consumes the entry for its OWN
    /// counter-code the moment one appears, applying it to the peer record
    /// directly. Entries older than `reciprocalConfirmationTimeout` are
    /// pruned whenever a new one arrives, so a confirmation that is never
    /// claimed by any attempt does not accumulate forever.
    @ObservationIgnored private var pendingReciprocalConfirmations: [String: (serverId: String, localDeviceId: String, receivedAt: Date)] = [:]
    /// Counter-codes for `addPeer` attempts that already gave up — reported
    /// failure or timed out waiting — keyed to when that happened. The far
    /// side's own retries run on their own schedule and have no way to know
    /// this attempt already ended, so its reciprocal call can still land
    /// afterward; checked before buffering in `handleInboundPeer` so a
    /// late-arriving one is checked for revocation the moment it lands
    /// rather than buffered with nothing left to ever claim or sweep it.
    /// Retained for `RemotePairingService.codeTTL`, not just
    /// `reciprocalConfirmationTimeout`: the far side can still redeem this
    /// counter-code for as long as it stays valid there, well after this
    /// attempt's own wait gave up.
    @ObservationIgnored private var endedCounterCodes: [String: Date] = [:]
    /// Bumped by `forget` for the identity it just removed. `addPeer` and
    /// `handleInboundPeer` each capture this count for their target
    /// identity before their own network round trip, then compare again
    /// right before `upsert` — if it changed, something happened to this
    /// identity while this attempt was in flight, so its own now-stale
    /// result must not clobber whatever the current, more current state is.
    /// This covers more than "the peer THIS attempt itself created was
    /// forgotten": two concurrent exchanges for the SAME previously-unknown
    /// identity (e.g. a doubled add, or a retried pair-back) can each
    /// observe "nothing exists yet" at their own start, so neither's own
    /// before/after existence check alone would ever catch one of them
    /// resurrecting a peer the OTHER sibling's success let the user forget.
    @ObservationIgnored private var forgetGenerationByServerId: [String: Int] = [:]
    /// The forget-generation for a redemption's identity, captured
    /// synchronously by `notePeerPairingArrived` at the moment a `/pair`
    /// redemption fires — before the `onPeerPaired` →
    /// `Task { @MainActor in ... }` hop that schedules `handleInboundPeer`
    /// introduces an arbitrary delay. Keyed by the device THIS redemption
    /// just minted — unique per attempt — rather than by `serverId`: two
    /// concurrent redemptions for the SAME identity would otherwise share
    /// one slot, and the later one's snapshot would silently overwrite the
    /// earlier one's, so a handler consuming an entry someone else wrote
    /// would compare against the wrong baseline and could miss its OWN
    /// exchange's peer having been forgotten out from under it. Consumed
    /// (and removed) the first time `handleInboundPeer` runs for that
    /// device.
    @ObservationIgnored private var startGenerationAtRedeem: [String: Int] = [:]

    private func forgetGeneration(for serverId: String) -> Int {
        forgetGenerationByServerId[serverId] ?? 0
    }
    /// The last real wall-clock time `forget` removed a peer for a given
    /// `serverId`. `addPeer` cannot snapshot a per-identity generation
    /// before its own network round trip the way `handleInboundPeer` can —
    /// it does not learn which identity it is even talking to until the
    /// reply names it — so it instead records when IT started and, once
    /// the identity is known, checks whether that identity was forgotten
    /// at or after that time. This also catches a peer created by a
    /// completely unrelated, concurrent INBOUND pairing for the same
    /// identity that this attempt could never have known about in advance.
    @ObservationIgnored private var lastForgottenAt: [String: Date] = [:]
    @ObservationIgnored private var connections: [String: any RemotePeerConnecting] = [:]
    @ObservationIgnored private var isActive = false

    init(store: RemotePeerStore,
         pairing: RemotePairingService,
         pairer: RemotePeerPairer = .live,
         reciprocalConfirmationTimeout: TimeInterval = 35,
         localIdentity: @escaping @MainActor () -> LocalIdentity,
         makeConnection: @escaping MakeConnection = { peer, onEvent in
             // `expectedServerId` binds the link to the identity this record
             // was paired with: the socket's `hello` must report it or the
             // connection is refused, and the /health probe must report it
             // before a refused upgrade counts as "our token was revoked".
             // Without it, whatever answers a stored address decides both.
             RemotePeerConnection(
                 origins: peer.origins,
                 lastOrigin: peer.lastOrigin,
                 token: peer.token,
                 expectedServerId: peer.serverId,
                 onEvent: onEvent)
         },
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.pairing = pairing
        self.pairer = pairer
        self.reciprocalConfirmationTimeout = reciprocalConfirmationTimeout
        self.localIdentity = localIdentity
        self.makeConnection = makeConnection
        self.now = now
        self.peers = store.load()
    }

    // MARK: - Pairing

    /// `localIdentity()`, with its origins capped to `RemotePairingLink.maxOrigins`.
    /// A Mac with more advertised addresses than that (several interfaces
    /// plus configured allowed hosts) would otherwise send an advertisement
    /// the receiving Mac rejects outright — it can never tell "too many
    /// legitimate addresses" apart from a hostile one, so it enforces the
    /// same bound on every advertisement it receives.
    private func boundedIdentity() -> LocalIdentity {
        let me = localIdentity()
        return LocalIdentity(serverId: me.serverId, name: me.name,
                             origins: Array(me.origins.prefix(RemotePairingLink.maxOrigins)))
    }

    /// Pastes another Mac's pairing link: redeems its code there while
    /// offering a counter-code so that Mac pairs back with us.
    func addPeer(link: String) async -> AddError? {
        guard let parts = RemotePairingLink.parse(link) else { return .invalidLink }
        let me = boundedIdentity()
        // With no advertisable address the counter-code is unusable: the far
        // side's pair-back finds nothing to dial, gives up, and revokes the
        // device it just minted for us. Reporting success here and failing
        // moments later on "revoked" would blame the wrong machine, so refuse
        // before minting a code and point the user at their own settings.
        guard !me.origins.isEmpty else { return .noLocalAddress }
        // The far side's real identity is not known until the reply names
        // it, so unlike `handleInboundPeer` this cannot snapshot a
        // per-identity generation before the round trip below — there is
        // no identity yet to key it by. Recording when THIS attempt itself
        // started, compared against `lastForgottenAt` once the identity is
        // known, catches the same race anyway: a Forget landing while this
        // round trip is in flight, whether for a peer this same attempt
        // would have re-paired or one a completely unrelated, concurrent
        // INBOUND pairing created for the identity this reply turns out to
        // name.
        let startedAt = Date()
        let counterCode = pairing.beginPairing()
        let advertisement = RemotePeerAdvertisement(serverId: me.serverId, name: me.name, origins: me.origins, counterCode: counterCode)
        switch await pairer.pair(origins: parts.origins, code: parts.code, deviceName: me.name, advertisement: advertisement) {
        case .paired(let token, let serverId, let name, let origin):
            // An origin is an address, never an identity. Standing in for a
            // missing `serverId` with one would key the record — and the
            // `/health` probe's expected id, and the device records `forget`
            // revokes — on a string no peer will ever report, so the record
            // could never be matched again or revoked. A reply with no usable
            // identity is not a peer we can hold, so refuse the add. Only the
            // display name falls back to the origin.
            guard let serverId, !serverId.isEmpty else {
                endAttempt(counterCode: counterCode)
                return .unreachable
            }
            // This identity was forgotten at or after this attempt's own
            // start: either the user forgot a peer this attempt would have
            // re-paired, or a peer a concurrent INBOUND pairing created for
            // it while this attempt's own round trip was in flight.
            // `previousState` below would find nothing and `upsert` would
            // happily recreate the peer from this now-unwanted reply,
            // silently undoing that Forget. Bail out before touching
            // `peers` at all; any reciprocal confirmation that still
            // arrives for this counter-code is caught by `endAttempt`'s
            // own orphan check, since no peer row exists for this identity
            // anymore.
            if let forgottenAt = lastForgottenAt[serverId], forgottenAt >= startedAt {
                endAttempt(counterCode: counterCode)
                return .cancelled
            }
            // Snapshot the record as it stood before this attempt, if one
            // exists. If THIS attempt's own reciprocal exchange fails, the
            // PREVIOUS relationship — untouched by anything that happens
            // here, and possibly still entirely valid — must be restored
            // rather than destroyed: `redeemPeer` never revoked the OLD
            // device this peer already held, only a failed exchange from
            // THIS attempt would revoke the NEW one it just minted.
            let previousState = peers.first(where: { $0.serverId == serverId })
            upsert(serverId: serverId, name: name ?? origin, origins: parts.origins,
                   lastOrigin: origin, token: token, localDeviceId: nil)
            // `upsert` proves OUR call to A succeeded — nothing more. Our own
            // token is valid the instant A's HTTP reply arrives, so OUR
            // outbound link would come online just fine regardless of
            // whether A's reciprocal pair-back to US ever succeeds; watching
            // our own connection state proves nothing about A's leg of the
            // exchange. The only real proof is A's reciprocal call actually
            // landing on OUR /pair endpoint and being processed —
            // `handleInboundPeer`'s initiator branch, which records that by
            // writing `localDeviceId` on this very record. If A cannot reach
            // any of our origins, that call never arrives, and A's own
            // failure is invisible to us except by its absence: A revokes
            // the device it minted for us, but sends no error our way.
            guard let peer = peers.first(where: { $0.serverId == serverId }) else { return nil }
            if await waitForReciprocalRedemption(peerId: peer.id, counterCode: counterCode) {
                return nil
            }
            // The wait gave up without finding a match, but a confirmation
            // could still land in the buffer right at that boundary, or
            // arrive even later — the far side's own retries run on their
            // own schedule and have no way to know this attempt gave up.
            // A DIFFERENT, concurrent exchange for this same identity (an
            // inbound pairing, or another outbound attempt) could also have
            // updated — or removed — this same row while this attempt's own
            // wait was running; only roll back if the row still holds
            // exactly what THIS attempt's own upsert wrote, otherwise a
            // newer exchange's genuine success would be clobbered by this
            // attempt's own, unrelated timeout.
            if peers.first(where: { $0.id == peer.id }) == peer {
                if let previousState {
                    restorePreviousState(previousState, peerId: peer.id)
                } else {
                    forget(peerId: peer.id)
                }
            }
            endAttempt(counterCode: counterCode)
            return .reciprocalPairingFailed
        case .expiredCode:
            endAttempt(counterCode: counterCode)
            return .expiredCode
        case .originRejected:
            endAttempt(counterCode: counterCode)
            return .originRejected
        case .unreachable:
            // Our own leg failing does not mean the peer's did: A's reply to
            // us can be lost on the wire after A already redeemed our
            // counter-code and paired back, authorizing a device with no
            // peer row this attempt will ever create to forget it by.
            endAttempt(counterCode: counterCode)
            return .unreachable
        }
    }

    /// Marks an attempt's counter-code as over: drops a buffered confirmation
    /// for it if one already arrived (revoking its device only if orphaned —
    /// see `revokeIfOrphaned`), and remembers the code so that one arriving
    /// LATER — the far side's own retries run on their own schedule,
    /// independent of this attempt having given up — is checked the moment
    /// it lands in `handleInboundPeer` instead of being buffered with
    /// nothing left to ever claim or sweep it.
    private func endAttempt(counterCode: String) {
        if let buffered = pendingReciprocalConfirmations.removeValue(forKey: counterCode) {
            revokeIfOrphaned(serverId: buffered.serverId, localDeviceId: buffered.localDeviceId)
        }
        endedCounterCodes[counterCode] = Date()
    }

    /// Revokes a reciprocal device grant only when no peer row exists for its
    /// identity — the only case where nothing durable is left to reach or
    /// manage it through. A peer row for this identity — pre-existing, just
    /// restored after this attempt's own failure, or otherwise — means the
    /// far side may already depend on this exact credential (e.g. its own
    /// reciprocal leg succeeded even though THIS attempt's outbound leg
    /// separately failed), and the user can always revoke it later via
    /// `forget`, so it is left standing rather than destroyed based only on
    /// this attempt's own outcome.
    private func revokeIfOrphaned(serverId: String, localDeviceId: String) {
        guard !peers.contains(where: { $0.serverId == serverId }) else { return }
        pairing.revoke(deviceId: localDeviceId)
        onRevokeDevice?(localDeviceId)
    }

    /// Records, synchronously, the current forget-generation for `serverId`
    /// at the moment a `/pair` redemption fires — the earliest point this
    /// can be observed, on the same call stack as the redeem itself, before
    /// the `onPeerPaired` → `Task { @MainActor in ... }` hop that schedules
    /// `handleInboundPeer`'s own body introduces an arbitrary delay. A
    /// Forget (or a concurrent sibling exchange for this same identity
    /// completing first) landing in exactly that gap would otherwise go
    /// unnoticed by `handleInboundPeer`'s own in-body snapshot, which only
    /// sees the world as of whenever it happens to actually start running.
    /// Keyed by `localDeviceId`, not `serverId`: see `startGenerationAtRedeem`.
    func notePeerPairingArrived(serverId: String, localDeviceId: String) {
        startGenerationAtRedeem[localDeviceId] = forgetGeneration(for: serverId)
    }

    /// The server saw another Mac redeem a code here. With a counter-code we
    /// are the responder and pair back; without one we are the initiator and
    /// only learn which local device record represents the peer.
    func handleInboundPeer(_ request: RemotePeerPairingRequest) async {
        if let counterCode = request.counterCode {
            let me = boundedIdentity()
            // `startGenerationAtRedeem`, captured synchronously at
            // redemption time by `notePeerPairingArrived`, is authoritative
            // when present — it predates even the scheduling gap before
            // this function's own body started; capturing it here too is
            // only a fallback for callers (direct test invocations) that
            // skip that earlier hook.
            let startGeneration = startGenerationAtRedeem.removeValue(forKey: request.localDeviceId)
                ?? forgetGeneration(for: request.peerServerId)
            let advertisement = RemotePeerAdvertisement(serverId: me.serverId, name: me.name, origins: me.origins, counterCode: nil)
            guard case .paired(let token, let repliedServerId, _, let origin) = await pairer.pair(
                origins: request.origins, code: counterCode, deviceName: me.name, advertisement: advertisement)
            else {
                // The peer already holds a token for this Mac: it was minted
                // before this branch ran. Returning empty-handed would leave it
                // standing access with no peer record to forget it by, so take
                // the inbound grant back and let the exchange start over.
                pairing.revoke(deviceId: request.localDeviceId)
                onRevokeDevice?(request.localDeviceId)
                return
            }
            // The reply's own identity must confirm what the ORIGINAL /pair
            // request claimed. `request.origins` is attacker-controlled, so
            // a request claiming identity X but pointing this pair-back at
            // an endpoint that answers as Y would otherwise have Y's token
            // persisted under X — misdirecting every future connection to X
            // toward Y instead.
            guard let repliedServerId, !repliedServerId.isEmpty, repliedServerId == request.peerServerId else {
                pairing.revoke(deviceId: request.localDeviceId)
                onRevokeDevice?(request.localDeviceId)
                return
            }
            // The generation changed since this exchange started: either
            // the user forgot this peer (this SAME attempt's own, or a
            // concurrent sibling's — e.g. a doubled add, or a retried
            // pair-back, for the same previously-unknown identity) while
            // this Mac was still pairing back. `forget` already revoked
            // every device carrying this identity, `request.localDeviceId`
            // included — revoked again here is a harmless no-op — but
            // `upsert` would otherwise recreate the OUTBOUND side of the
            // relationship from this now-stale reply, undoing the user's
            // revocation just as surely as resurrecting the peer row
            // itself would.
            guard forgetGeneration(for: request.peerServerId) == startGeneration else {
                pairing.revoke(deviceId: request.localDeviceId)
                onRevokeDevice?(request.localDeviceId)
                return
            }
            upsert(serverId: request.peerServerId, name: request.peerName, origins: request.origins,
                   lastOrigin: origin, token: token, localDeviceId: request.localDeviceId)
        } else {
            // We are the initiator: this is A's reciprocal call redeeming
            // OUR counter-code. Always buffer it, keyed by that code, rather
            // than writing straight to a record even when a re-pair means
            // one already exists: writing directly raced `addPeer`'s own
            // `upsert`, which resets `localDeviceId` to nil the moment it
            // runs — a confirmation landing first was silently erased the
            // instant `upsert` executed, leaving `addPeer` to wait out the
            // full timeout despite the exchange having actually succeeded.
            // Matching by `serverId` alone also accepted ANY confirmation
            // for this peer, not just the one THIS attempt's own counter-code
            // earned. Buffering unconditionally means `waitForReciprocalRedemption`
            // is the only place that ever writes `localDeviceId`, and it only
            // ever claims the entry keyed to the exact attempt that is waiting.
            // The attempt that minted this code may have already given up —
            // reported failure, or timed out waiting — before this call
            // landed. Nothing is left to claim it into a peer relationship,
            // so it is checked for revocation immediately (see
            // `revokeIfOrphaned`) rather than buffered on the chance
            // something later happens to sweep it out.
            if endedCounterCodes.removeValue(forKey: request.redeemedCode) != nil {
                revokeIfOrphaned(serverId: request.peerServerId, localDeviceId: request.localDeviceId)
                return
            }
            let now = Date()
            // Sweep anything old enough that no attempt could still
            // plausibly claim it, so an entry nobody ever consumes does not
            // accumulate indefinitely. Each swept entry is a device this Mac
            // already authorized on the far side's say-so that no attempt
            // ever turned into a real peer relationship, so it is checked
            // for revocation rather than just dropped.
            for (_, stale) in pendingReciprocalConfirmations where now.timeIntervalSince(stale.receivedAt) > reciprocalConfirmationTimeout {
                revokeIfOrphaned(serverId: stale.serverId, localDeviceId: stale.localDeviceId)
            }
            pendingReciprocalConfirmations = pendingReciprocalConfirmations.filter {
                now.timeIntervalSince($0.value.receivedAt) <= reciprocalConfirmationTimeout
            }
            // Retained for the code's full redeemable lifetime, not just the
            // confirmation wait: `RemotePairingService.codeTTL` outlives
            // `reciprocalConfirmationTimeout`, so the far side can still
            // redeem this counter-code well after this attempt's own wait
            // gave up. Pruning on the shorter window let a redemption in
            // that gap fall through as an ordinary — not ended — arrival.
            endedCounterCodes = endedCounterCodes.filter {
                now.timeIntervalSince($0.value) <= RemotePairingService.codeTTL
            }
            pendingReciprocalConfirmations[request.redeemedCode] = (
                serverId: request.peerServerId, localDeviceId: request.localDeviceId, receivedAt: now)
        }
    }

    func forget(peerId: String) {
        guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
        let peer = peers.remove(at: index)
        connections[peerId]?.disconnect()
        connections[peerId] = nil
        states[peerId] = nil
        // Bumped so any addPeer/handleInboundPeer exchange for this same
        // identity that is still in flight — including one that never
        // itself observed a peer existing, a concurrent sibling of
        // whichever attempt just created the row being forgotten here —
        // can tell its own result is now stale and must not upsert it back.
        forgetGenerationByServerId[peer.serverId, default: 0] += 1
        // Real wall-clock time — never `now()`, which tests freeze — so
        // `addPeer`'s own comparison against when it started is meaningful.
        lastForgottenAt[peer.serverId] = Date()
        // Revoke by the peer's identity rather than by the stored
        // `localDeviceId`. That id is a snapshot taken before an HTTP round
        // trip, and a peer redeem adds a device row without removing earlier
        // ones for the same `peerServerId` — so a peer that re-paired in the
        // meantime is represented by several devices, at most one of which
        // the record remembers, and revoking the remembered id alone would
        // leave live tokens behind. Sweeping the identity is also what makes
        // that additive redeem safe. The stored id is still revoked as a
        // hint, for records written before the peer's device carried a
        // `peerServerId`.
        var deviceIds = pairing.devices
            .filter { $0.kind == .alasInstance && $0.peerServerId == peer.serverId }
            .map(\.id)
        if let hint = peer.localDeviceId, !deviceIds.contains(hint) { deviceIds.append(hint) }
        for deviceId in deviceIds {
            pairing.revoke(deviceId: deviceId)
            onRevokeDevice?(deviceId)
        }
        store.save(peers)
    }

    /// Waits for A's reciprocal call to redeem THIS attempt's own
    /// `counterCode`, regardless of whether it lands before or after this
    /// record was created: `handleInboundPeer` always buffers a no-counter-code
    /// confirmation keyed by the code it redeemed, and this is the only place
    /// that ever claims one and applies it to the peer record — so a
    /// confirmation can only ever satisfy the ONE attempt whose own
    /// counter-code it actually redeemed, never a different or earlier one
    /// for the same peer. Real wall-clock deadline — checked before sleeping,
    /// so a confirmation that already landed resolves with no real wait —
    /// and runs regardless of `isActive`: this depends only on the SERVER
    /// receiving A's reciprocal call, which has nothing to do with whether
    /// this manager's own outbound links are currently being dialed.
    private func waitForReciprocalRedemption(peerId: String, counterCode: String) async -> Bool {
        let deadline = Date().addingTimeInterval(reciprocalConfirmationTimeout)
        while true {
            if let buffered = pendingReciprocalConfirmations.removeValue(forKey: counterCode) {
                guard let index = peers.firstIndex(where: { $0.id == peerId }) else {
                    // The peer was forgotten (e.g. the user clicked Forget)
                    // while this attempt was still waiting. There is no
                    // record left to apply this confirmation to, so treat it
                    // as a cancelled attempt rather than reporting success
                    // with nothing to show for it.
                    revokeIfOrphaned(serverId: buffered.serverId, localDeviceId: buffered.localDeviceId)
                    return false
                }
                // The confirmation must claim the SAME identity the
                // original reply established this record under. A peer
                // that claimed X in its reply but Y in the reciprocal
                // callback redeeming OUR counter-code has not proven it IS
                // X — it has only proven it somehow obtained our
                // counter-code. Accepting it would authorize a device
                // recorded under an identity `forget` never checks (it
                // sweeps by the record's STORED serverId), letting that
                // device survive indefinitely even after the user forgets
                // this peer.
                guard buffered.serverId == peers[index].serverId else {
                    pairing.revoke(deviceId: buffered.localDeviceId)
                    onRevokeDevice?(buffered.localDeviceId)
                    return false
                }
                peers[index].localDeviceId = buffered.localDeviceId
                store.save(peers)
                return true
            }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Reverts a failed re-pair back to the record as it stood before this
    /// attempt started, and reconnects using the RESTORED token — the new
    /// one this attempt minted is dead the moment A's failed reciprocal
    /// callback revoked it, so continuing to use it would just blip the
    /// link offline for no reason. Does not touch the peer's inbound device
    /// grants: the OLD one this restores may still be exactly what A is
    /// using to reach us, and revoking it would sever a relationship that
    /// this attempt never actually broke.
    private func restorePreviousState(_ previous: RemotePeer, peerId: String) {
        guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
        peers[index] = previous
        store.save(peers)
        if isActive { connect(previous) }
    }

    // MARK: - Links

    func connectAll() {
        isActive = true
        for peer in peers where connections[peer.id] == nil {
            connect(peer)
        }
    }

    func disconnectAll() {
        isActive = false
        for connection in connections.values { connection.disconnect() }
        connections = [:]
        states = [:]
    }

    private func connect(_ peer: RemotePeer) {
        connections[peer.id]?.disconnect()
        let id = peer.id
        let connection = makeConnection(peer) { [weak self] event in self?.handle(event, peerId: id) }
        connections[id] = connection
        connection.connect()
    }

    private func handle(_ event: RemotePeerConnection.Event, peerId: String) {
        switch event {
        case .stateChanged(let state):
            states[peerId] = state
        case .hello(_, let name, let protocolVersion, _):
            guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
            // The identity is deliberately NOT adopted from the frame. It is
            // the key everything else hangs off — the link's expected id, the
            // `/health` check, and the device records `forget` revokes — so
            // letting the far side rewrite it would mean whoever answers the
            // origin decides who this record is. The connection this manager
            // builds is handed the record's `serverId` and refuses a socket
            // reporting a different one, so in practice the frame's id
            // already matches; ignoring it here is the backstop. Name and
            // protocol version are cosmetic and safe to take from the peer.
            peers[index].name = name
            peers[index].protocolVersion = protocolVersion
            store.save(peers)
        case .originChanged(let origin):
            guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
            peers[index].lastOrigin = origin
            store.save(peers)
        case .message:
            break
        }
    }

    private func upsert(serverId: String, name: String, origins: [String], lastOrigin: String,
                        token: String, localDeviceId: String?) {
        // `localDeviceId` is resolved to exactly what the caller passed —
        // including `nil` from `addPeer`'s own call site, which must
        // actually CLEAR a re-paired record's old value: preserving it would
        // let a stale confirmation from a PREVIOUS attempt satisfy this
        // one's wait trivially, before this attempt's own reciprocal
        // exchange has had any chance to run. (A confirmation buffered
        // before this record existed is claimed separately, by
        // `waitForReciprocalRedemption`, keyed to the specific attempt that
        // earned it — not applied here.)
        let peer: RemotePeer
        if let index = peers.firstIndex(where: { $0.serverId == serverId }) {
            // The fresh advertisement goes first — it is already bounded to
            // `RemotePairingLink.maxOrigins` upstream and always includes
            // `lastOrigin`, the address this very exchange just confirmed
            // works — and only the remaining capacity is backfilled with
            // addresses from the PREVIOUS record, oldest fallbacks trimmed
            // first. Without an overall cap, repeated re-pairs across
            // network changes could accumulate an unbounded list even
            // though each individual advertisement is capped, and
            // `RemotePeerConnection` dials every one of them sequentially,
            // each with its own timeout, before ever reaching a current
            // address if the preferred one stops answering.
            var merged = origins
            for origin in peers[index].origins where !merged.contains(origin) && merged.count < RemotePairingLink.maxOrigins {
                merged.append(origin)
            }
            peers[index].name = name
            peers[index].origins = merged
            peers[index].lastOrigin = lastOrigin
            peers[index].token = token
            peers[index].localDeviceId = localDeviceId
            peer = peers[index]
        } else {
            peer = RemotePeer(id: UUID().uuidString, serverId: serverId, name: name, origins: origins,
                              lastOrigin: lastOrigin, token: token, protocolVersion: nil,
                              localDeviceId: localDeviceId, addedAt: now())
            peers.append(peer)
        }
        store.save(peers)
        if isActive { connect(peer) }
    }
}
