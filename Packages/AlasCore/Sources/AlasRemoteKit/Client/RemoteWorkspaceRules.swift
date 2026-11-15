import Foundation

/// The lazy file tree behind the Files tab: the host sends one directory's
/// children at a time, and this remembers them, what is expanded, and the
/// flattened visible rows. Mirrors `file-browser.js`.
public struct RemoteFileTree: Equatable {
    /// Keyed by directory path; `""` is the root.
    public private(set) var children: [String: [RemoteFileNode]] = [:]
    public var expanded: Set<String> = []

    public init() {}

    public static func canExpand(_ node: RemoteFileNode) -> Bool {
        node.kind == "dir" && !node.isSubmodule
    }

    public mutating func apply(path: String?, nodes: [RemoteFileNode]) {
        let key = path ?? ""
        let sorted = nodes.sorted { a, b in
            if a.kind != b.kind { return a.kind == "dir" }
            let order = a.name.compare(b.name, options: .caseInsensitive)
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
        let previous = children[key]
        children[key] = sorted
        // A directory deleted or renamed since the last listing would
        // otherwise stay in `expanded` and be re-requested forever.
        let present = Set(sorted.map(\.path))
        for node in previous ?? [] where node.kind == "dir" && !present.contains(node.path) {
            forget(node.path)
        }
    }

    private mutating func forget(_ path: String) {
        expanded.remove(path)
        for node in children.removeValue(forKey: path) ?? [] where node.kind == "dir" {
            forget(node.path)
        }
    }

    public func rows() -> [(node: RemoteFileNode, depth: Int)] {
        var out: [(node: RemoteFileNode, depth: Int)] = []
        func collect(_ key: String, _ depth: Int) {
            for node in children[key] ?? [] {
                out.append((node, depth))
                if node.kind == "dir", expanded.contains(node.path) { collect(node.path, depth + 1) }
            }
        }
        collect("", 0)
        return out
    }

    /// Every expanded directory, hidden-behind-a-collapsed-parent ones
    /// included, parents first.
    public func pathsToRefresh() -> [String] {
        func depth(_ path: String) -> Int { path.split(separator: "/").count }
        return expanded.filter { !$0.isEmpty }.sorted {
            depth($0) == depth($1) ? $0 < $1 : depth($0) < depth($1)
        }
    }
}

/// Pure labels and grouping for the Changes tab (`changes-view.js`, `app.js`).
public enum RemoteChangesRules {
    public static func summary(comparisonRef: String?, fileCount: Int, add: Int, del: Int, commitCount: Int, commitsTruncated: Bool = false) -> String {
        let ref = comparisonRef.map { "vs \($0) · " } ?? ""
        let files = "\(fileCount) \(fileCount == 1 ? "file" : "files") · +\(add) −\(del)"
        let commits = commitCount > 0 ? " · \(commitCount)\(commitsTruncated ? "+" : "") \(commitCount == 1 ? "commit" : "commits")" : ""
        return ref + files + commits
    }

    /// The tab badge: the loaded count (with "+" once truncated), else the
    /// worktree summary's count. Nil when there is nothing to show.
    public static func badge(loaded: Int?, truncated: Bool, fallback: Int) -> String? {
        let count = loaded ?? fallback
        guard count > 0 else { return nil }
        return "\(count)" + (loaded != nil && truncated ? "+" : "")
    }

    /// Files grouped by directory (no trailing slash, "" for the root),
    /// directories and files sorted by path.
    public static func grouped(_ files: [RemoteChangedFile]) -> [(directory: String, files: [RemoteChangedFile])] {
        func split(_ path: String) -> (dir: String, name: String) {
            guard let slash = path.lastIndex(of: "/") else { return ("", path) }
            return (String(path[..<slash]), String(path[path.index(after: slash)...]))
        }
        let sorted = files.sorted {
            let a = split($0.path), b = split($1.path)
            return a.dir == b.dir ? a.name < b.name : a.dir < b.dir
        }
        var groups: [(directory: String, files: [RemoteChangedFile])] = []
        for file in sorted {
            let dir = split(file.path).dir
            if groups.last?.directory == dir {
                groups[groups.count - 1].files.append(file)
            } else {
                groups.append((dir, [file]))
            }
        }
        return groups
    }

    public static func accessMessage(_ reason: RemoteFileAccessReason, message: String?, byteSize: Int?) -> String {
        switch reason {
        case .binary: return "Binary file — not shown."
        case .tooLarge:
            guard let byteSize, byteSize > 0 else { return "File is too large to view." }
            return "File is \((byteSize + 512) / 1024) KB — too large to view."
        case .pathRejected: return "That path is outside this worktree."
        case .notFound: return "File not found."
        case .worktreeUnavailable: return "This session's worktree is unavailable."
        case .sessionUnknown: return "This session is no longer open on the host."
        case .gitFailed, .unknown:
            if let message, !message.isEmpty { return message }
            return "Could not read this file."
        }
    }
}
