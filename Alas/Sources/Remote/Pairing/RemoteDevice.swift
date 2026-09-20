import Foundation

enum RemoteDeviceKind: String, Codable, Equatable, Sendable {
    case browser
    case alasInstance
}

struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    let id: String          // UUID
    var name: String
    var tokenHash: String   // hex SHA-256 of the token; plaintext never stored
    var createdAt: Date
    var lastSeenAt: Date?
    /// Browsers and the web client are `.browser`; another Mac running Alas
    /// that paired here is `.alasInstance`.
    var kind: RemoteDeviceKind
    /// For `.alasInstance` devices, the peer's advertised `serverId`.
    var peerServerId: String?

    init(id: String, name: String, tokenHash: String, createdAt: Date, lastSeenAt: Date?,
         kind: RemoteDeviceKind = .browser, peerServerId: String? = nil) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.kind = kind
        self.peerServerId = peerServerId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tokenHash, createdAt, lastSeenAt, kind, peerServerId
    }

    // Records written before federation have no `kind`; treat them as browsers
    // rather than failing the whole file (FileDeviceStore drops everything on error).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tokenHash = try c.decode(String.self, forKey: .tokenHash)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        kind = (try? c.decodeIfPresent(RemoteDeviceKind.self, forKey: .kind)) ?? .browser
        peerServerId = try c.decodeIfPresent(String.self, forKey: .peerServerId)
    }
}

/// Persistence boundary for paired devices. Production uses a JSON file under
/// Application Support (see `FileDeviceStore`); tests use an in-memory
/// implementation that lives in the test target.
protocol RemoteDeviceStore: AnyObject {
    func load() -> [RemoteDevice]
    func save(_ devices: [RemoteDevice])
}
