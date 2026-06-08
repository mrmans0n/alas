import Foundation

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
            guard suffix.isEmpty || (suffix.hasPrefix(":") && !port.isEmpty && port.allSatisfy(\.isNumber)) else {
                return nil
            }
            let inside = raw[raw.index(after: raw.startIndex)..<close]
            return String(inside)
        }

        let colonCount = raw.filter { $0 == ":" }.count
        if colonCount == 1, let colon = raw.lastIndex(of: ":") {
            return String(raw[..<colon])
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
