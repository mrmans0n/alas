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
    }

    typealias MakeConnection = @MainActor (RemotePeer, @escaping @MainActor (RemotePeerConnection.Event) -> Void) -> any RemotePeerConnecting

    private(set) var peers: [RemotePeer]
    private(set) var states: [String: RemotePeerConnection.State] = [:]
    /// Called with a `RemoteDevice.id` when forgetting a peer should also cut
    /// its live inbound socket. Nothing sets it yet; the owner that adopts this
    /// manager is expected to point it at `RemoteServer.disconnectDevice`,
    /// since revoking the device record alone leaves an open socket authorized.
    @ObservationIgnored var onRevokeDevice: (@MainActor (String) -> Void)?

    private let store: RemotePeerStore
    private let pairing: RemotePairingService
    private let pairer: RemotePeerPairer
    private let localIdentity: @MainActor () -> LocalIdentity
    private let makeConnection: MakeConnection
    private let now: () -> Date
    @ObservationIgnored private var connections: [String: any RemotePeerConnecting] = [:]
    @ObservationIgnored private var isActive = false

    init(store: RemotePeerStore,
         pairing: RemotePairingService,
         pairer: RemotePeerPairer = .live,
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
            upsert(serverId: serverId, name: name ?? origin, origins: parts.origins,
                   lastOrigin: origin, token: token, localDeviceId: nil)
            return nil
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
        let peer: RemotePeer
        if let index = peers.firstIndex(where: { $0.serverId == serverId }) {
            var merged = peers[index].origins
            for origin in origins where !merged.contains(origin) { merged.append(origin) }
            peers[index].name = name
            peers[index].origins = merged
            peers[index].lastOrigin = lastOrigin
            peers[index].token = token
            if let localDeviceId { peers[index].localDeviceId = localDeviceId }
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
