import AlasCore
import Foundation

extension AppState {
    /// The icon a paired Mac chose, by its server id. Nil or unknown ids get
    /// a laptop, as does a peer from a build that advertises none.
    func peerIcon(serverId: String?) -> PeerIcon {
        guard let serverId else { return .laptop }
        if let page = nativePeerSessions?.peerPages.first(where: { $0.serverId == serverId }) {
            return page.icon
        }
        // Only reach for the lazy manager when a server is up, as
        // `remoteServerIdentity()` does.
        guard remoteServer != nil else { return .laptop }
        return remotePeers.peers.first { $0.serverId == serverId }?.displayIcon ?? .laptop
    }

    /// For sites that only carry a Mac's name, such as delegation labels a
    /// host reports: the first peer with that name, this Mac's own icon when
    /// the name is its own, else a laptop.
    func peerIcon(named name: String) -> PeerIcon {
        if let page = nativePeerSessions?.peerPages.first(where: { $0.name == name }) {
            return page.icon
        }
        if remoteServer != nil, let peer = remotePeers.peers.first(where: { $0.name == name }) {
            return peer.displayIcon ?? .laptop
        }
        return name == remoteDisplayName ? remoteIcon : .laptop
    }

    /// The icon of the paired Mac that delegated a local session.
    func delegatedFromIcon(of sessionId: String?) -> PeerIcon {
        peerIcon(serverId: sessionId.flatMap { core.delegatedPeerOrigins[$0] })
    }

    /// Every peer page's icon by server id, for views that take a lookup
    /// table instead of the app state.
    var peerIconsByServerId: [String: PeerIcon] {
        Dictionary(
            (nativePeerSessions?.peerPages ?? []).map { ($0.serverId, $0.icon) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
