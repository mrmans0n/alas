import Foundation

/// Which symbol mentions in a draft can no longer be found. A mention counts as
/// missing exactly when sending would mark it `not found when sent`: the same
/// read and the same `ACPSymbolReference.resolve`, so the badge and the send
/// cannot disagree.
enum ACPSymbolPresence {
    /// The URIs among `uris` that are symbol links whose declaration is gone.
    /// Anything else (files, sessions, malformed links) is ignored. `read`
    /// returns a file's text by worktree-relative path, or nil when it cannot
    /// be read; it runs once per distinct path.
    static func missing(among uris: [String], read: (String) async -> String?) async -> Set<String> {
        var targets: [String: ACPSymbolReference.Target] = [:]
        for uri in uris where targets[uri] == nil {
            if let target = ACPSymbolReference.target(fromURI: uri) { targets[uri] = target }
        }
        var sources: [String: String] = [:]
        for path in Set(targets.values.map(\.path)) {
            if let text = await read(path) { sources[path] = text }
        }
        return Set(targets.filter {
            !ACPSymbolReference.resolve($0.value, source: sources[$0.value.path]).found
        }.keys)
    }

    static func missing(among uris: [String], worktreeRoot: URL) async -> Set<String> {
        await missing(among: uris) { await SymbolSource.read(root: worktreeRoot, relativePath: $0) }
    }
}
