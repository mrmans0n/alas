import Foundation

extension SSHConfigHost {
    /// "user@hostname:port", omitting whichever parts are absent.
    var subtitle: String? {
        var base: String?
        switch (user, hostName) {
        case let (u?, h?): base = "\(u)@\(h)"
        case let (nil, h?): base = h
        case let (u?, nil): base = u
        case (nil, nil): base = nil
        }
        guard var result = base else { return nil }
        if let port { result += ":\(port)" }
        return result
    }
}

enum SSHHostSuggestions {
    static func filter(_ hosts: [SSHConfigHost], query: String) -> [SSHConfigHost] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return hosts }
        return hosts.filter {
            $0.alias.localizedCaseInsensitiveContains(q)
                || ($0.hostName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// A ready-to-paste `~/.ssh/config` stanza seeded with the typed name.
    static func snippet(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let alias = trimmed.isEmpty ? "<name>" : trimmed
        return """
        Host \(alias)
            HostName <server-address>
            User <you>
        """
    }
}
