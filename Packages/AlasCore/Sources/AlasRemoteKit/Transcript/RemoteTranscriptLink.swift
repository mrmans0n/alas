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
        } else if !url.absoluteString.contains("://"),
                  !systemSchemes.contains(url.scheme?.lowercased() ?? "") {
            // `Package.swift:2` parses as a scheme; `mailto:` and friends have no line number.
            path = trimmingPeriod(url.absoluteString.removingPercentEncoding ?? url.absoluteString)
            guard splitLine(path) != nil else { return .system }
        } else {
            return .system
        }
        path = trimmingPeriod(path)
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

    /// Schemes whose destination can be all digits, so `tel:123` is not read as file `tel`, line 123.
    private static let systemSchemes: Set<String> = ["tel", "sms", "facetime", "facetime-audio", "mailto", "maps"]

    /// Sentence punctuation can end up inside a link destination.
    private static func trimmingPeriod(_ value: String) -> String {
        value.hasSuffix(".") && value.count > 1 ? String(value.dropLast()) : value
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

public extension RemoteTranscriptLink {
    /// A markdown image source from a document at worktree path `file`: a relative one, its URL
    /// escapes decoded, taken from the document's folder; an absolute one or a URL left alone.
    static func imageSource(_ source: String, besideFile file: String) -> String {
        guard !source.hasPrefix("/"), URL(string: source)?.scheme == nil else { return source }
        return worktreePath(source.removingPercentEncoding ?? source, besideFile: file)
    }

    /// `relative`, a decoded path from a document at worktree path `file`, as a worktree path taken
    /// from the document's folder. `.` and `..` are folded; a path that climbs out of the worktree
    /// keeps its leading `..`, for the host to refuse.
    static func worktreePath(_ relative: String, besideFile file: String) -> String {
        var parts: [Substring] = []
        for part in (file.split(separator: "/").dropLast() + relative.split(separator: "/")) where part != "." {
            if part == "..", let last = parts.last, last != ".." {
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }
}
