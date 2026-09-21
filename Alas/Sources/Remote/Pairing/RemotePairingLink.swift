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
        var origins = [base]
        for address in addresses where !origins.contains(address.url) {
            origins.append(address.url)
        }
        let hosts = origins.map(encodeOrigin).joined(separator: ",")
        return "\(base)/?code=\(code)&hosts=\(hosts)"
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything outside RFC 3986 unreserved characters, so
    /// the comma separating origins is never ambiguous.
    static func encodeOrigin(_ origin: String) -> String {
        origin.addingPercentEncoding(withAllowedCharacters: unreserved) ?? origin
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
            guard let origin = normalizeOrigin(candidate), !origins.contains(origin) else { continue }
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
