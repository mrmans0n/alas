import Foundation

/// Serves the delegation requests a paired host sends back over this Mac's
/// own link to it (`HostProtocolCapability.delegationReverseV1`): a host this
/// Mac paired with that never paired back, so it cannot dial this Mac.
///
/// Served as a delegation-only token is, one host-protocol connection per
/// link, under the consent the peer's record holds. A request from a link
/// that may not use the route gets a refusal, not silence.
@MainActor
public final class PeerRouteHost {
    nonisolated static let refusal = "This Mac does not take requests over this link."

    private let links: RemotePeerManager
    private let server: HostProtocolServer
    /// By peer id, while its link is up.
    private var connections: [String: Route] = [:]

    private struct Route {
        let connection: HostProtocolConnection
        let replies: Replies
    }

    /// Whether a connection's answers may still go out. A request still being
    /// served when its link drops is never answered over the link that comes
    /// back: request ids start again there, so it would answer another one.
    private final class Replies {
        var open = true
    }

    /// Takes `links`' `onPeerHostRequest` and `onLinkChanged`.
    public init(links: RemotePeerManager, server: HostProtocolServer) {
        self.links = links
        self.server = server
        links.onPeerHostRequest = { [weak self] peerId, request in self?.receive(request, peerId: peerId) }
        links.onLinkChanged = { [weak self] peerId in self?.linkChanged(peerId) }
    }

    /// The device a host's requests act as: what a delegation-only token
    /// paired by that host would be, with the consent its record holds. The
    /// id cannot match a device paired here.
    static func device(for peer: RemotePeer) -> RemoteDevice {
        RemoteDevice(
            id: "peer-route:\(peer.id)", name: peer.name, tokenHash: "", createdAt: peer.addedAt, lastSeenAt: nil,
            kind: .alasInstance, peerServerId: peer.serverId, agentAccess: peer.agentAccess ?? .off,
            peerPublicKey: peer.publicKey, scope: .delegation
        )
    }

    private func receive(_ request: HostClientMessage, peerId: String) {
        guard let peer = links.servesPeerHost(peerId: peerId) else {
            let serverId = links.peers.first { $0.id == peerId }?.serverId
            if let serverId {
                links.sendToPeer(.peerHost(.response(id: request.id, result: .failure(error: .invalidRequest(
                    reason: Self.refusal)))), serverId: serverId)
            }
            return
        }
        let connection = connections[peerId]?.connection ?? open(peer)
        Task { await connection.receive(request) }
    }

    private func open(_ peer: RemotePeer) -> HostProtocolConnection {
        let peerId = peer.id
        let serverId = peer.serverId
        let replies = Replies()
        let connection = server.connect(
            caller: .remotePeer(deviceID: Self.device(for: peer).id),
            device: { [weak links] in
                // Read anew on each request, so consent applies at once.
                links?.servesPeerHost(peerId: peerId).map(Self.device(for:))
            },
            send: { [weak links] reply in
                guard replies.open else { return }
                links?.sendToPeer(.peerHost(reply), serverId: serverId)
            }
        )
        connections[peerId] = Route(connection: connection, replies: replies)
        return connection
    }

    private func linkChanged(_ peerId: String) {
        guard links.servesPeerHost(peerId: peerId) == nil, let route = connections.removeValue(forKey: peerId) else { return }
        Self.end(route)
    }

    /// Ends every connection.
    public func stop() {
        links.onPeerHostRequest = nil
        links.onLinkChanged = nil
        for route in connections.values { Self.end(route) }
        connections = [:]
    }

    private static func end(_ route: Route) {
        route.replies.open = false
        route.connection.close()
    }
}
