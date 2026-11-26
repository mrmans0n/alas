import Foundation

/// How a paired Mac is reached, read from the origin it last answered on.
public enum PeerConnectionKind: Equatable, Sendable {
    case tailscale
    case lan
    /// Anything else, by host name or address.
    case host(String)

    public var label: String {
        switch self {
        case .tailscale: "Tailscale"
        case .lan: "LAN"
        case .host(let host): host
        }
    }

    public static func of(origin: String?) -> PeerConnectionKind? {
        guard let origin, let raw = URL(string: origin)?.host, !raw.isEmpty else { return nil }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host.hasSuffix(".ts.net") { return .tailscale }
        if host.hasSuffix(".local") { return .lan }
        if host.contains(":") {
            return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") ? .lan : .host(host)
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return .host(host) }
        switch (octets[0], octets[1]) {
        case (100, 64...127): return .tailscale // CGNAT range Tailscale assigns from
        case (10, _), (192, 168), (172, 16...31), (169, 254): return .lan
        default: return .host(host)
        }
    }
}
