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

/// What a device's token may do here.
public enum RemoteDeviceScope: String, Codable, Equatable, Sendable {
    /// Everything this Mac serves a paired device.
    case full
    /// Only the delegation verbs, and the events that say delegated work
    /// waits to be collected. A headless host asks for this: its token sits
    /// in a file its own agents can read.
    case delegation

    /// The capability a responder advertises in `/health` once it honours
    /// a `scope` in `POST /pair`.
    public static let pairCapability = "pair.delegation-scope.v1"
}

/// Where a host posts a phone's attention pings, and the token that relay
/// issued for that phone. A token opens only at its own relay, so the phone
/// supplies both.
public struct RemotePushRelay: Codable, Equatable, Sendable {
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    public static let maxURLBytes = 512
    public static let maxTokenBytes = 1024

    /// The relay a `pushRegistration` names, or nil when it is not an `https`
    /// URL within the caps or has no token.
    public static func validated(url: String, token: String?) -> RemotePushRelay? {
        guard url.utf8.count <= maxURLBytes, let token, !token.isEmpty, token.utf8.count <= maxTokenBytes,
              let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host?.isEmpty == false
        else { return nil }
        return RemotePushRelay(url: parsed, token: token)
    }
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
    /// The identity key that peer proved it holds, at redeem or by the
    /// pair-back. Nil when nothing proved it, and then `peerServerId` is only
    /// a claim: anyone holding a live pairing code could have sent it.
    public var peerPublicKey: String?
    /// Whether agents on that peer may delegate work here. Consent is per
    /// device, so re-pairing starts again at `.off`.
    public var agentAccess: RemoteDeviceAgentAccess
    /// What the token may do. Only a redeemer that proved its key gets
    /// anything but `.full`.
    public var scope: RemoteDeviceScope
    /// The push relay this phone registered; nil when it has none.
    public var pushRelay: RemotePushRelay?

    public init(id: String, name: String, tokenHash: String, createdAt: Date, lastSeenAt: Date?,
         kind: RemoteDeviceKind = .browser, peerServerId: String? = nil,
         agentAccess: RemoteDeviceAgentAccess = .off, peerPublicKey: String? = nil, scope: RemoteDeviceScope = .full) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.kind = kind
        self.peerServerId = peerServerId
        self.agentAccess = agentAccess
        self.peerPublicKey = peerPublicKey
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tokenHash, createdAt, lastSeenAt, kind, peerServerId, agentAccess, peerPublicKey, scope, pushRelay
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
        peerPublicKey = (try? c.decodeIfPresent(String.self, forKey: .peerPublicKey)) ?? nil
        // Records from before scopes were all full. An unrecognised value
        // comes from a newer build, which only ever narrows a token.
        if c.contains(.scope) {
            scope = (try? c.decode(RemoteDeviceScope.self, forKey: .scope)) ?? .delegation
        } else {
            scope = .full
        }
        pushRelay = try? c.decodeIfPresent(RemotePushRelay.self, forKey: .pushRelay)
    }
}

/// Persistence boundary for paired devices. Production uses a JSON file under
/// Application Support (see `FileDeviceStore`); tests use an in-memory
/// implementation that lives in the test target.
public protocol RemoteDeviceStore: AnyObject {
    func load() -> [RemoteDevice]
    func save(_ devices: [RemoteDevice])
}
