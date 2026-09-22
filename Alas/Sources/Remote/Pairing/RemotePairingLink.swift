import Foundation

struct RemotePairingLinkParts: Equatable, Sendable {
    let origins: [String]
    let code: String
}

/// The string encoded in the pairing QR and copied by "Copy pairing link":
///
///     http://<preferred-host>:<port>/?code=<CODE>&hosts=<origin1>,<origin2>,…
///
/// A fresh phone scanning it lands on `base` and pairs as before; a hub
/// pastes it and tries every origin in `hosts` in order, preferred first.
enum RemotePairingLink {
    /// Cap on origins accepted from any source — a pasted link or an inbound
    /// peer advertisement. A real Mac advertises a handful (tailnet, LAN, a
    /// couple of interfaces); anything beyond this is a malformed or hostile
    /// list, not a peer. `RemotePeerPairer` dials each one sequentially with
    /// its own multi-second timeout, so an unbounded list from a pasted link
    /// could stall an Add attempt — and its disabled UI — for minutes.
    static let maxOrigins = 8

    static func build(base: String, code: String, addresses: [RemoteAdvertisedAddress]) -> String {
        var kindByURL: [String: RemoteAdvertisedAddress.Kind] = [:]
        for address in addresses { kindByURL[address.url] = address.kind }
        var origins = [base]
        for address in addresses where !origins.contains(address.url) {
            origins.append(address.url)
        }
        let hosts = origins.map { encodeOrigin(token(origin: $0, kind: kindByURL[$0])) }.joined(separator: ",")
        return "\(base)/?code=\(code)&hosts=\(hosts)"
    }

    /// Prefixes an origin with its advertised-address kind
    /// ("tailnet|http://…"), so `parsePairingLink` on the browser side can
    /// tell a live LAN/tailnet address — derived from current interfaces —
    /// apart from a static, user-configured custom host (a reverse proxy,
    /// or this Mac's own .local Bonjour name) or the loopback placeholder.
    /// Either of those can go stale, or answer for an unrelated Mac, after
    /// the link was generated; only a LAN/tailnet 401/403 is trusted as the
    /// real target's final answer (see hub-links.js's `pair`). Nil `kind`
    /// (no matching advertised address, e.g. `base` falling back to a bare
    /// "localhost" URL) leaves the origin unprefixed, matching every link
    /// built before this encoding existed.
    private static func token(origin: String, kind: RemoteAdvertisedAddress.Kind?) -> String {
        guard let kind else { return origin }
        return "\(kind.rawValue)|\(origin)"
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything outside RFC 3986 unreserved characters, so
    /// the comma separating origins is never ambiguous.
    static func encodeOrigin(_ origin: String) -> String {
        origin.addingPercentEncoding(withAllowedCharacters: unreserved) ?? origin
    }

    /// The inverse of `token(origin:kind:)`. A `hosts` entry may carry a
    /// leading `"<kind>|"` this client has no use for — kind only matters
    /// to the browser pairing client's own `parsePairingLink`. Stripped
    /// rather than parsed: an unrecognized prefix, or none at all (every
    /// link built before this encoding existed), passes the token through
    /// unchanged.
    private static func stripKindPrefix(_ token: String) -> String {
        guard let separator = token.firstIndex(of: "|"),
              RemoteAdvertisedAddress.Kind(rawValue: String(token[token.startIndex..<separator])) != nil
        else { return token }
        return String(token[token.index(after: separator)...])
    }

    /// The inverse of `build`. Origins come back in `hosts` order with the
    /// link's own origin appended as the last fallback; duplicates keep their
    /// first position. Nil when `text` is not an http(s) URL with a `code`.
    static func parse(_ text: String) -> RemotePairingLinkParts? {
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
            guard let origin = normalizeOrigin(stripKindPrefix(candidate)), !origins.contains(origin) else { continue }
            origins.append(origin)
        }
        return origins.isEmpty ? nil : RemotePairingLinkParts(origins: origins, code: code)
    }

    /// `scheme://host[:port]` for an http(s) URL, IPv6 hosts bracketed.
    static func normalizeOrigin(_ text: String) -> String? {
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
