import Foundation

/// A peer as `FederatedSessionsProvider` sees it: the identity its rows are
/// tagged with and the name a client groups them under.
struct FederatedPeerInfo: Equatable, Hashable, Sendable {
    let serverId: String
    let name: String
}

enum FederatedPeerLinkEvent {
    /// Whether `serverId` carries sessions may have changed: its link went
    /// up or down, its record was forgotten, or every link was torn down.
    /// The consumer re-reads `sessionCarryingPeers` rather than trusting the
    /// event to say which way it went.
    case availabilityChanged(serverId: String)
    /// A frame that arrived over a link that carries sessions. Frames on any
    /// other link are dropped before they get here.
    case message(serverId: String, RemoteServerMessage)
}

/// What `FederatedSessionsProvider` needs from the peer links, kept apart
/// from `RemotePeerManager` so the provider's tests drive it with a fake.
@MainActor
protocol FederatedPeerLinks: AnyObject {
    /// Peers whose records are pinned to a proven key and whose socket is
    /// online right now. Only these may carry session traffic.
    var sessionCarryingPeers: [FederatedPeerInfo] { get }
    var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)? { get set }
    /// Sends over `serverId`'s link. Silently dropped unless that peer
    /// currently carries sessions: the gate is enforced here, on every send,
    /// not only when a route was first chosen.
    func sendToPeer(_ message: RemoteClientMessage, serverId: String)
}
