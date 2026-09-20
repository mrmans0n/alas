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

    /// Pastes another Mac's pairing link: redeems its code there while
    /// offering a counter-code so that Mac pairs back with us.
    func addPeer(link: String) async -> AddError? {
        guard let parts = RemotePairingLink.parse(link) else { return .invalidLink }
        let me = localIdentity()
        // With no advertisable address the counter-code is unusable: the far
        // side's pair-back finds nothing to dial, gives up, and revokes the
        // device it just minted for us. Reporting success here and failing
        // moments later on "revoked" would blame the wrong machine, so refuse
        // before minting a code and point the user at their own settings.
        guard !me.origins.isEmpty else { return .noLocalAddress }
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
            guard let serverId, !serverId.isEmpty else { return .unreachable }
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
            if let previousState {
                restorePreviousState(previousState, peerId: peer.id)
            } else {
                forget(peerId: peer.id)
            }
            return .reciprocalPairingFailed
        case .expiredCode: return .expiredCode
        case .originRejected: return .originRejected
        case .unreachable: return .unreachable
        }
    }

    /// The server saw another Mac redeem a code here. With a counter-code we
    /// are the responder and pair back; without one we are the initiator and
    /// only learn which local device record represents the peer.
    func handleInboundPeer(_ request: RemotePeerPairingRequest) async {
        if let counterCode = request.counterCode {
            let me = localIdentity()
            let advertisement = RemotePeerAdvertisement(serverId: me.serverId, name: me.name, origins: me.origins, counterCode: nil)
            guard case .paired(let token, _, _, let origin) = await pairer.pair(
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
            upsert(serverId: request.peerServerId, name: request.peerName, origins: request.origins,
                   lastOrigin: origin, token: token, localDeviceId: request.localDeviceId)
        } else if let index = peers.firstIndex(where: { $0.serverId == request.peerServerId }) {
            peers[index].localDeviceId = request.localDeviceId
            store.save(peers)
        } else {
            // Our own `addPeer` for this peer hasn't created the record yet —
            // A's reciprocal call arrived first. Buffer it, keyed by the code
            // it just redeemed, so the matching `addPeer` attempt (the one
            // whose own counter-code this is) can claim it the moment it
            // starts waiting, rather than losing the only confirmation that
            // attempt will get.
            let now = Date()
            // Sweep anything old enough that no attempt could still
            // plausibly claim it, so an entry nobody ever consumes does not
            // accumulate indefinitely.
            pendingReciprocalConfirmations = pendingReciprocalConfirmations.filter {
                now.timeIntervalSince($0.value.receivedAt) <= reciprocalConfirmationTimeout
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
    /// `counterCode` — checked two ways, since the confirmation can arrive
    /// either before or after this record existed:
    /// - `peers[peerId].localDeviceId` becoming non-nil: the record already
    ///   existed when A's call landed (a re-pair), so
    ///   `handleInboundPeer`'s "record already exists" branch wrote it
    ///   directly.
    /// - `pendingReciprocalConfirmations[counterCode]`: the record did not
    ///   exist yet, so the confirmation was buffered; claimed here and
    ///   applied to the record the moment it appears.
    /// Real wall-clock deadline — checked before sleeping, so a confirmation
    /// that already landed resolves with no real wait — and runs regardless
    /// of `isActive`: this depends only on the SERVER receiving A's
    /// reciprocal call, which has nothing to do with whether this manager's
    /// own outbound links are currently being dialed.
    private func waitForReciprocalRedemption(peerId: String, counterCode: String) async -> Bool {
        let deadline = Date().addingTimeInterval(reciprocalConfirmationTimeout)
        while true {
            if peers.first(where: { $0.id == peerId })?.localDeviceId != nil { return true }
            if let buffered = pendingReciprocalConfirmations.removeValue(forKey: counterCode) {
                if let index = peers.firstIndex(where: { $0.id == peerId }) {
                    peers[index].localDeviceId = buffered.localDeviceId
                    store.save(peers)
                }
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
            var merged = peers[index].origins
            for origin in origins where !merged.contains(origin) { merged.append(origin) }
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
