import Foundation

/// Where the headless `alas-host` listens. Host-only: the app never reads it.
public enum HostReachability: String, Codable, CaseIterable, Sendable {
    // Ordered so cycling through the choices reaches LAN last.
    case off, loopback, tailscale, lan
}

/// Host-only overrides. Nil fields are derived from the shared `remote` section.
public struct HostSettings: Codable, Equatable, Sendable {
    public var reachability: HostReachability?
    public var port: UInt16?

    public init(reachability: HostReachability? = nil, port: UInt16? = nil) {
        self.reachability = reachability
        self.port = port
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reachability = try? c.decodeIfPresent(HostReachability.self, forKey: .reachability)
        port = try? c.decodeIfPresent(UInt16.self, forKey: .port)
    }
}

public struct HostRemoteListen: Equatable, Sendable {
    public var port: UInt16
    public var loopbackOnly: Bool
    public var tailscaleServe: Bool

    public init(port: UInt16, loopbackOnly: Bool, tailscaleServe: Bool) {
        self.port = port
        self.loopbackOnly = loopbackOnly
        self.tailscaleServe = tailscaleServe
    }
}

extension AppConfig {
    public var hostReachability: HostReachability {
        host.reachability ?? (remote.enabled ? (remote.tailscaleServe ? .tailscale : .loopback) : .off)
    }

    public var hostPort: UInt16 { host.port ?? remote.preferredPort }

    public var hostRemoteListen: HostRemoteListen? {
        let reachability = hostReachability
        guard reachability != .off else { return nil }
        return HostRemoteListen(
            port: hostPort,
            loopbackOnly: reachability != .lan,
            tailscaleServe: reachability == .tailscale
        )
    }
}
