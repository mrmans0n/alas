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

    /// The inverse of `build`. Origins come back in `hosts` order with the
    /// link's own origin appended as the last fallback; duplicates keep their
    /// first position. Nil when `text` is not an http(s) URL with a `code`.
    public static func parse(_ text: String) -> RemotePairingLinkParts? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value?
                  .trimmingCharacters(in: .whitespaces),
              !code.isEmpty
        else { return nil }
        var candidates: [String] = []
        // Split the RAW, still-encoded value. `build` percent-encodes each
        // origin individually before joining on ",", so a comma inside an
        // origin arrives as %2C. Letting URLComponents decode the whole value
        // first turns that back into a literal comma, which would both tear
        // the origin in two and manufacture an origin nobody advertised.
        if let encodedHosts = components.percentEncodedQueryItems?
            .first(where: { $0.name == "hosts" })?.value {
            candidates.append(contentsOf: encodedHosts
                .split(separator: ",")
                .compactMap { String($0).removingPercentEncoding })
        }
        candidates.append(trimmed)
        var origins: [String] = []
        for candidate in candidates {
            guard origins.count < maxOrigins else { break }
            guard let origin = normalizeOrigin(candidate), !origins.contains(origin) else { continue }
            origins.append(origin)
        }
        return origins.isEmpty ? nil : RemotePairingLinkParts(origins: origins, code: code)
    }
}

public struct RemotePairingLinkParts: Equatable, Sendable {
    public let origins: [String]
    public let code: String

    public init(origins: [String], code: String) {
        self.origins = origins
        self.code = code
    }
}
