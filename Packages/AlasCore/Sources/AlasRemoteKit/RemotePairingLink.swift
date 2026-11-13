import Foundation

public enum RemotePairingLink: Sendable {
    /// Cap on origins accepted from any source — a pasted link or an inbound
    /// peer advertisement. A real Mac advertises a handful (tailnet, LAN, a
    /// couple of interfaces); anything beyond this is a malformed or hostile
    /// list, not a peer. `RemotePeerPairer` dials each one sequentially with
    /// its own multi-second timeout, so an unbounded list from a pasted link
    /// could stall an Add attempt — and its disabled UI — for minutes.
    public static let maxOrigins = 8

    /// `scheme://host[:port]` for an http(s) URL, IPv6 hosts bracketed.
    public static func normalizeOrigin(_ text: String) -> String? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = components.host, !rawHost.isEmpty
        else { return nil }
        // Foundation versions differ on whether an IPv6 host keeps its brackets; normalise both ways.
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let bracketed = host.contains(":") ? "[\(host)]" : host
        if let port = components.port {
            return "\(scheme)://\(bracketed):\(port)"
        }
        return "\(scheme)://\(bracketed)"
    }
}
