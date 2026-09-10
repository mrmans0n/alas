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
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isIPv4LoopbackLiteral(normalized) { return true }
        return loopbackHosts.contains(normalized)
    }

    private static func isIPv4LoopbackLiteral(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return false }
            octets.append(value)
        }
        return octets.first == 127
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
}
