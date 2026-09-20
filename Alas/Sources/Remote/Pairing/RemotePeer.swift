import Foundation

/// Another Mac running Alas that this Mac holds a token for. The Swift twin
/// of one entry in the web client's `alas.remote.hub` registry.
struct RemotePeer: Codable, Equatable, Identifiable, Sendable {
    let id: String                 // local UUID, stable across renames
    var serverId: String           // the peer's advertised identity
    var name: String
    var origins: [String]          // full origins, preferred first
    var lastOrigin: String?        // the origin that last answered
    var token: String              // bearer token the peer issued to us
    var protocolVersion: Int?
    /// The `RemoteDevice.id` on this Mac that the peer uses to reach us, so
    /// forgetting the peer can revoke its inbound token too.
    var localDeviceId: String?
    var addedAt: Date
}

protocol RemotePeerStore: AnyObject {
    func load() -> [RemotePeer]
    func save(_ peers: [RemotePeer])
}

final class FilePeerStore: RemotePeerStore {
    private let store: any PersistenceStoreProtocol
    private let url: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), url: URL = Paths.remotePeersFile) {
        self.store = store
        self.url = url
    }

    func load() -> [RemotePeer] {
        (try? store.readIfExists([RemotePeer].self, from: url)) ?? []
    }

    func save(_ peers: [RemotePeer]) {
        try? store.write(peers, to: url)
    }
}
