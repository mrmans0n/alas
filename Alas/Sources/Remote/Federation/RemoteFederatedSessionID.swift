import Foundation

/// The id scheme for sessions a gateway forwards from a peer.
///
/// `"<serverId>:<sessionId>"`. Session ids are only unique per Mac, so a
/// federated surface has to say whose they are. The scheme lives here and in
/// `FederatedSessionsProvider` only: a gateway prefixes on the way out and
/// strips on the way in, and every client treats the whole string as opaque.
///
/// A `serverId` is a UUID string and never contains `:`, which is what makes
/// splitting on the first colon unambiguous. The prefix is treated as a peer
/// only when the caller says that peer exists; anything else is a local id
/// that happens to contain a colon.
enum RemoteFederatedSessionID {
    static func compose(serverId: String, sessionId: String) -> String {
        "\(serverId):\(sessionId)"
    }

    static func parse(_ id: String, peers: Set<String>) -> (serverId: String, sessionId: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let serverId = String(id[..<colon])
        let sessionId = String(id[id.index(after: colon)...])
        guard !serverId.isEmpty, !sessionId.isEmpty, peers.contains(serverId) else { return nil }
        return (serverId, sessionId)
    }
}
