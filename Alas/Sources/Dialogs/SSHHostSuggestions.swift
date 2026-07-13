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
    /// A `user@host` entry is split into `User`/`Host`, since OpenSSH matches
    /// `Host` against the host part only and takes the user separately.
    static func snippet(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var user: String?
        var host = trimmed
        if let at = trimmed.firstIndex(of: "@") {
            let hostPart = String(trimmed[trimmed.index(after: at)...])
            if !hostPart.isEmpty {
                let userPart = String(trimmed[..<at])
                if !userPart.isEmpty { user = userPart }
                host = hostPart
            }
        }
        let hostLine = host.isEmpty ? "<name>" : host
        let userLine = user ?? "<you>"
        return """
        Host \(hostLine)
            HostName <server-address>
            User \(userLine)
        """
    }
}
