import Foundation

/// What two clones of a repository have in common whatever their transport.
public enum GitRemoteIdentity {
    private static let networkSchemes: Set<String> = ["http", "https", "ssh", "git", "git+ssh"]

    /// `host/owner/repo`, without credentials, scheme, port or `.git`; nil for
    /// a local path or anything else that names no repository on a host.
    public static func normalized(_ url: String) -> String? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (host, path) = url.contains("://") ? urlParts(url) : scpParts(url) else { return nil }
        var repository = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        guard !host.isEmpty, !repository.isEmpty else { return nil }
        return "\(host.lowercased())/\(repository)"
    }

    private static func urlParts(_ url: String) -> (host: String, path: String)? {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              networkSchemes.contains(scheme), let host = components.host
        else { return nil }
        return (host, components.path)
    }

    /// `[user[:token]@]host:path`. As for git, a slash before the colon makes it a path.
    private static func scpParts(_ url: String) -> (host: String, path: String)? {
        let firstSegment = url.prefix { $0 != "/" }
        let address = firstSegment.firstIndex(of: "@").map { url[url.index(after: $0)...] } ?? url[...]
        guard let colon = address.firstIndex(of: ":"), !address[..<colon].contains("/") else { return nil }
        return (String(address[..<colon]), String(address[address.index(after: colon)...]))
    }
}
