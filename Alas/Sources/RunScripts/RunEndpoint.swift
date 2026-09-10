import Darwin
import Foundation

/// What clicking a run's endpoint should do. Resolved before anything is
/// opened so a remote run can never quietly hand the user a local service.
enum RunEndpointAction: Equatable {
    case open(URL)
    /// The command runs on another machine but its URL points at loopback —
    /// opening it would hit whatever happens to listen on this Mac.
    case blockedRemoteLoopback(host: String, url: URL)
}

enum RunEndpointPolicy {
    private static let loopbackHosts: Set<String> = [
        "localhost", "127.0.0.1", "0.0.0.0", "::1", "0:0:0:0:0:0:0:1", "::",
    ]

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        if let zoneSeparator = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<zoneSeparator])
        }
        if isIPv6LoopbackLiteral(normalized) { return true }
        if isIPv6UnspecifiedLiteral(normalized) { return true }
        if isIPv4MappedIPv6LoopbackLiteral(normalized) { return true }
        if isIPv4LoopbackLiteral(normalized) { return true }
        if isIPv4UnspecifiedLiteral(normalized) { return true }
        return loopbackHosts.contains(normalized)
    }

    private static func isIPv6LoopbackLiteral(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        return bytes.count == 16
            && bytes[0..<15].allSatisfy { $0 == 0 }
            && bytes[15] == 1
    }

    private static func isIPv6UnspecifiedLiteral(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        return bytes.count == 16 && bytes.allSatisfy { $0 == 0 }
    }

    private static func isIPv4MappedIPv6LoopbackLiteral(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count == 16,
              bytes[0..<10].allSatisfy({ $0 == 0 }),
              bytes[10] == 0xff,
              bytes[11] == 0xff
        else { return false }
        return bytes[12] == 127
    }

    private static func isIPv4LoopbackLiteral(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return false }
        let ipv4 = UInt32(bigEndian: address.s_addr)
        return (ipv4 >> 24) == 127
    }

    private static func isIPv4UnspecifiedLiteral(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return false }
        return UInt32(bigEndian: address.s_addr) == 0
    }

    static func action(for url: URL, target: RunExecutionTarget) -> RunEndpointAction {
        guard let host = target.host else { return .open(url) }
        guard isLoopback(url) else { return .open(url) }
        return .blockedRemoteLoopback(host: host, url: url)
    }

    /// Only absolute http(s) URLs are treated as endpoints. A malformed
    /// `alas-url` header is ignored rather than hiding the script.
    static func endpoint(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

enum RunPortProbe {
    /// True when something on this Mac already holds `port`. Implemented as a
    /// bind attempt: it observes the collision without touching whatever owns
    /// the port.
    static func isLocalPortInUse(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        return isIPv4PortInUse(port) || isIPv6PortInUse(port)
    }

    private static func isIPv4PortInUse(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && errno == EADDRINUSE
    }

    private static func isIPv6PortInUse(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(port).bigEndian
        address.sin6_addr = in6addr_any
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return result != 0 && errno == EADDRINUSE
    }
}
