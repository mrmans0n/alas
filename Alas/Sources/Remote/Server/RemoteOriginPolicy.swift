import Foundation

/// Decides whether a browser `Origin` may pair with, probe, or open a socket
/// to this Mac. An absent Origin (non-browser clients, same-origin
/// navigations) is allowed. A present Origin must be a private-network or
/// `.local` host, a host the `RemoteAccessPolicy` allowlist already trusts,
/// or an explicitly configured origin. Applied alongside the Host check,
/// never instead of it.
struct RemoteOriginPolicy: Equatable, Sendable {
    struct ParsedOrigin: Equatable, Sendable {
        let scheme: String
        let host: String      // lowercased, no brackets
        let port: Int?

        /// `scheme://host[:port]` with IPv6 hosts bracketed.
        var normalized: String {
            "\(scheme)://\(hostHeader)" + (port.map { ":\($0)" } ?? "")
        }

        /// The shape `RemoteAccessPolicy.allows(hostHeader:)` expects.
        var hostHeader: String { host.contains(":") ? "[\(host)]" : host }
    }

    private let hostPolicy: RemoteAccessPolicy
    private let allowedOrigins: Set<String>

    init(hostPolicy: RemoteAccessPolicy, allowedOrigins: [String]) {
        self.hostPolicy = hostPolicy
        self.allowedOrigins = Set(allowedOrigins.compactMap { Self.parse($0)?.normalized })
    }

    static let loopback = RemoteOriginPolicy(hostPolicy: .loopback, allowedOrigins: [])

    func allows(originHeader: String?) -> Bool {
        guard let raw = originHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return true
        }
        guard let origin = Self.parse(raw) else { return false }
        if allowedOrigins.contains(origin.normalized) { return true }
        if hostPolicy.allows(hostHeader: origin.hostHeader) { return true }
        if RemoteNetwork.isPrivateOrLocalHost(origin.host) { return true }
        return origin.host.hasSuffix(".local")
    }

    /// Accepts only a bare origin: http(s) scheme, host, optional port, and
    /// nothing else (no path, query, fragment, or credentials).
    static func parse(_ raw: String) -> ParsedOrigin? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else { return nil }
        let host = RemoteNetwork.normalizedHost(rawHost)
        guard !host.isEmpty else { return nil }
        // A browser's Origin header never carries a scheme-default port, so
        // an allowlist entry typed or pasted with one (https://host:443,
        // http://host:80) must canonicalize the same way or it can never
        // match the request it was meant to allow.
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port == defaultPort ? nil : components.port
        return ParsedOrigin(scheme: scheme, host: host, port: port)
    }
}
