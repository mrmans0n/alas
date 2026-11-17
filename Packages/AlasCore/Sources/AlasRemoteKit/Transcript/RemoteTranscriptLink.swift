import Foundation

/// Where a tapped transcript link goes on a peer, which reads files only inside the session's worktree.
/// Mirrors the Mac's `transcriptLinkRoute` parsing without its disk probes.
public enum RemoteTranscriptLink: Equatable, Sendable {
    /// A worktree-relative file to open.
    case file(String)
    /// Not a local path: the system's default action opens it.
    case system
    /// A local path outside the worktree: nothing opens.
    case discard

    public static func route(_ url: URL, worktreeRoot: String?) -> RemoteTranscriptLink {
        var path: String
        if url.isFileURL {
            // `file://server/share` names a network volume, not a local path.
            guard url.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true else { return .system }
            path = url.path
        } else if url.scheme == nil {
            // `//host/path` names an authority, not a local path.
            guard url.host == nil else { return .system }
            path = url.path.removingPercentEncoding ?? url.path
        } else if !url.absoluteString.contains("://") {
            // `Package.swift:2` parses as a scheme; `mailto:` and friends have no line number.
            path = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            guard splitLine(path) != nil else { return .system }
        } else {
            return .system
        }
        // Sentence punctuation can end up inside a link destination.
        if path.hasSuffix("."), path.count > 1 { path.removeLast() }
        // `:line` or `:line:column`; the file viewer has no position to reveal.
        if let line = splitLine(path) { path = splitLine(line) ?? line }
        guard !path.isEmpty else { return .system }

        if path.hasPrefix("/") {
            guard let root = worktreeRoot.map({ $0.hasSuffix("/") ? $0 : $0 + "/" }), path.hasPrefix(root) else {
                return .discard
            }
            path.removeFirst(root.count)
            // `root//x` names `root/x`, as a standardized file URL would.
            while path.hasPrefix("/") { path.removeFirst() }
        }
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return .discard }
        return .file(path)
    }

    /// `value` without a trailing `:N` (N > 0), or nil when it has none.
    private static func splitLine(_ value: String) -> String? {
        guard let colon = value.lastIndex(of: ":") else { return nil }
        let suffix = value[value.index(after: colon)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber), Int(suffix) ?? 0 > 0,
              colon != value.startIndex else { return nil }
        return String(value[..<colon])
    }
}
