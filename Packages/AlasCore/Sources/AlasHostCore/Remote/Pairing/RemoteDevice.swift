import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

public enum RemoteDeviceKind: String, Codable, Equatable, Sendable {
    case browser
    case alasInstance
}

/// What another Mac's agents may do on this one. Each value includes the one before it.
public enum RemoteDeviceAgentAccess: String, Codable, Sendable {
    /// No new children and no new prompts.
    case off
    /// Children run, and their permission requests wait for a person.
    case ask
    /// A child may auto-run if its parent was auto-running.
    case autoRun
}

public struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String          // UUID
    public var name: String
    public var tokenHash: String   // hex SHA-256 of the token; plaintext never stored
    public var createdAt: Date
    public var lastSeenAt: Date?
    /// Browsers and the web client are `.browser`; another Mac running Alas
    /// that paired here is `.alasInstance`.
    public var kind: RemoteDeviceKind
    /// For `.alasInstance` devices, the peer's advertised `serverId`.
    public var peerServerId: String?
    /// Whether agents on that peer may delegate work here. Consent is per
    /// device, so re-pairing starts again at `.off`.
    public var agentAccess: RemoteDeviceAgentAccess

    public init(id: String, name: String, tokenHash: String, createdAt: Date, lastSeenAt: Date?,
         kind: RemoteDeviceKind = .browser, peerServerId: String? = nil,
         agentAccess: RemoteDeviceAgentAccess = .off) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.kind = kind
        self.peerServerId = peerServerId
        self.agentAccess = agentAccess
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tokenHash, createdAt, lastSeenAt, kind, peerServerId, agentAccess
    }

    // Records written before federation have no `kind`; treat them as browsers
    // rather than failing the whole file (FileDeviceStore drops everything on error).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tokenHash = try c.decode(String.self, forKey: .tokenHash)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        kind = (try? c.decodeIfPresent(RemoteDeviceKind.self, forKey: .kind)) ?? .browser
        peerServerId = try c.decodeIfPresent(String.self, forKey: .peerServerId)
        // A missing or unrecognised value is no consent.
        agentAccess = (try? c.decodeIfPresent(RemoteDeviceAgentAccess.self, forKey: .agentAccess)) ?? .off
    }
}

/// Persistence boundary for paired devices. Production uses a JSON file under
/// Application Support (see `FileDeviceStore`); tests use an in-memory
/// implementation that lives in the test target.
public protocol RemoteDeviceStore: AnyObject {
    func load() -> [RemoteDevice]
    func save(_ devices: [RemoteDevice])
}
