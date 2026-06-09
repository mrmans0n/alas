import Foundation
import Darwin

struct RemoteAccessPolicy: Equatable, Sendable {
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) {
        self.allowedHosts = Set(allowedHosts.map(RemoteNetwork.normalizedHost).filter { !$0.isEmpty })
    }

    init(allowedHosts: [String]) {
        self.init(allowedHosts: Set(allowedHosts))
    }

    static let loopback = RemoteAccessPolicy(allowedHosts: ["localhost", "127.0.0.1", "::1"])

    func allows(hostHeader: String?) -> Bool {
        guard let normalized = Self.normalizedHost(from: hostHeader) else { return false }
        return allowedHosts.contains(normalized)
    }

    static func normalizedHost(from hostHeader: String?) -> String? {
        guard var raw = hostHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        raw = raw.lowercased()

        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]") else { return nil }
            let suffix = raw[raw.index(after: close)...]
            let port = suffix.dropFirst()
            guard suffix.isEmpty || (suffix.hasPrefix(":") && Self.isASCIIPort(port)) else {
                return nil
            }
            let inside = raw[raw.index(after: raw.startIndex)..<close]
            let host = String(inside)
            guard Self.isIPv6Literal(host) else { return nil }
            return host
        }

        guard !raw.contains("[") && !raw.contains("]") else { return nil }

        let colonCount = raw.filter { $0 == ":" }.count
        if colonCount == 1, let colon = raw.lastIndex(of: ":") {
            let port = raw[raw.index(after: colon)...]
            guard Self.isASCIIPort(port) else { return nil }
            let host = String(raw[..<colon])
            return host.isEmpty ? nil : host
        }
        return raw
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    private static func isASCIIPort<S: StringProtocol>(_ port: S) -> Bool {
        !port.isEmpty && port.utf8.allSatisfy { byte in
            byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!
        }
    }
}
