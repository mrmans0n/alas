import Foundation

/// Another Mac running Alas that this Mac holds a token for. The Swift twin
/// of one entry in the web client's `alas.remote.hub` registry.
public struct RemotePeer: Codable, Equatable, Identifiable, Sendable {
    public let id: String                 // local UUID, stable across renames
    public var serverId: String           // the peer's advertised identity
    public var name: String
    public var origins: [String]          // full origins, preferred first
    public var lastOrigin: String?        // the origin that last answered
    public var token: String              // bearer token the peer issued to us
    /// Base64 of the Ed25519 public key this record is PINNED to: the peer
    /// proved possession of the matching private key at pairing time, and
    /// every socket afterwards has to prove it again before the link goes
    /// online. Nil for a record paired before verification shipped — see
    /// `isVerified`. Never adopted from a running link; only a pairing
    /// exchange the user initiated can set it.
    public var publicKey: String?
    public var protocolVersion: Int?
    /// The `RemoteDevice.id` on this Mac that the peer uses to reach us, so
    /// forgetting the peer can revoke its inbound token too.
    public var localDeviceId: String?
    public var addedAt: Date

    /// Whether this record is bound to key material at all.
    ///
    /// A record paired before verification shipped has none: nothing ties it
    /// to anything its peer had to possess, so it is exactly as strong as the
    /// address it was paired over. Such a link is still dialled — breaking
    /// every existing pairing on upgrade would be worse than the gap — but it
    /// is shown as unverified, and session aggregation must refuse to carry
    /// real session data over it. Re-pairing is what upgrades it.
    public var isVerified: Bool { publicKey?.isEmpty == false }

    public init(id: String, serverId: String, name: String, origins: [String], lastOrigin: String? = nil, token: String, publicKey: String? = nil, protocolVersion: Int? = nil, localDeviceId: String? = nil, addedAt: Date) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.origins = origins
        self.lastOrigin = lastOrigin
        self.token = token
        self.publicKey = publicKey
        self.protocolVersion = protocolVersion
        self.localDeviceId = localDeviceId
        self.addedAt = addedAt
    }
}

public protocol RemotePeerStore: AnyObject {
    func load() -> [RemotePeer]
    func save(_ peers: [RemotePeer])
}

/// Peer records on disk, with their bearer tokens held separately in the
/// Keychain.
///
/// A peer's token is an outbound credential: it is what this Mac presents to
/// reach another one. Keeping it in the same plain JSON as the addresses and
/// names that reference it meant a file copied off this Mac was enough to
/// impersonate it to every peer. The records still describe themselves fully;
/// only the secret moves.
public final class FilePeerStore: RemotePeerStore {
    /// Account the whole token map is stored under — one secret rather than
    /// one per peer, so a save is a single atomic write no matter how the
    /// peer list changed.
    public static let tokensAccount = "peer-tokens"

    private let store: any PersistenceStoreProtocol
    private let url: URL
    private let secrets: any RemoteSecretStore

    public init(store: any PersistenceStoreProtocol = PersistenceStore(),
         url: URL = Paths.remotePeersFile,
         secrets: any RemoteSecretStore = RemoteSecretStores.makeDefault()) {
        self.store = store
        self.url = url
        self.secrets = secrets
    }

    public func load() -> [RemotePeer] {
        var peers = (try? store.readIfExists([RemotePeer].self, from: url)) ?? []
        let tokens = storedTokens()
        for index in peers.indices {
            // A record written before the move still carries its token
            // inline; the next `save` migrates it. A record written after
            // carries an empty string and takes the real one from here.
            if peers[index].token.isEmpty, let token = tokens[peers[index].id] {
                peers[index].token = token
            }
        }
        return peers
    }

    public func save(_ peers: [RemotePeer]) {
        var tokens: [String: String] = [:]
        for peer in peers where !peer.token.isEmpty {
            tokens[peer.id] = peer.token
        }
        let encoded = (try? JSONEncoder().encode(tokens)) ?? Data()
        let stored = !encoded.isEmpty && secrets.setSecret(encoded, for: Self.tokensAccount)
        var records = peers
        if stored {
            for index in records.indices { records[index].token = "" }
        }
        // Written either way. When nothing would take the tokens, they stay
        // inline in the record rather than being stripped: dropping them for
        // tidiness would silently log this Mac out of every peer it has,
        // which is far worse than writing the file the previous build wrote.
        try? store.write(records, to: url)
    }

    private func storedTokens() -> [String: String] {
        guard let data = secrets.secret(for: Self.tokensAccount),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tokens
    }
}
