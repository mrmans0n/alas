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

    /// The staged and unstaged lists as one entry per path, as the Mac's working tree shows them:
    /// the unstaged side names the status, and the counts are the larger of the two sides.
    public static func workingTree(staged: [RemoteChangedFile], unstaged: [RemoteChangedFile]) -> [RemoteWorkingTreeFile] {
        let stagedByPath = Dictionary(staged.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let unstagedPaths = Set(unstaged.map(\.path))
        let merged = unstaged.map { file -> RemoteWorkingTreeFile in
            guard let other = stagedByPath[file.path] else { return RemoteWorkingTreeFile(file: file, stage: .unstaged) }
            return RemoteWorkingTreeFile(
                file: RemoteChangedFile(path: file.path, status: file.status, add: max(file.add, other.add),
                                        del: max(file.del, other.del), conflict: file.conflict ?? other.conflict,
                                        renameFrom: file.renameFrom ?? other.renameFrom),
                stage: .mixed)
        }
        return merged + staged.filter { !unstagedPaths.contains($0.path) }.map { RemoteWorkingTreeFile(file: $0, stage: .staged) }
    }

    /// Files as a folder tree flattened to rows: folders before files, each in Finder order, a folder whose
    /// only child is a folder merged into it ("Sources/App"), and the contents of `collapsed` folders left out.
    public static func tree<Item>(_ items: [Item], path: (Item) -> String,
                                  collapsed: Set<String> = []) -> [RemoteChangeTreeRow<Item>] {
        let root = TreeNode<Item>()
        for item in items {
            let parts = path(item).split(separator: "/").map(String.init)
            var node = root
            for part in parts.dropLast() {
                let next = node.dirs[part] ?? TreeNode()
                node.dirs[part] = next
                node = next
                node.items.append(item)
            }
            node.files.append((parts.last ?? path(item), item))
        }
        func before(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        var rows: [RemoteChangeTreeRow<Item>] = []
        func walk(_ node: TreeNode<Item>, prefix: String, depth: Int) {
            for name in node.dirs.keys.sorted(by: before) {
                var dir = node.dirs[name]!
                var label = name
                var full = prefix.isEmpty ? name : "\(prefix)/\(name)"
                while dir.files.isEmpty, dir.dirs.count == 1, let (child, next) = dir.dirs.first {
                    label += "/\(child)"
                    full += "/\(child)"
                    dir = next
                }
                rows.append(RemoteChangeTreeRow(name: label, path: full, depth: depth, isDirectory: true, items: dir.items))
                if !collapsed.contains(full) { walk(dir, prefix: full, depth: depth + 1) }
            }
            for (name, item) in node.files.sorted(by: { before($0.0, $1.0) }) {
                rows.append(RemoteChangeTreeRow(name: name, path: path(item), depth: depth, isDirectory: false, items: [item]))
            }
        }
        walk(root, prefix: "", depth: 0)
        return rows
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

/// How much of a working-tree file, or of a folder's files, is staged.
public enum RemoteStageState: Equatable, Sendable {
    case unstaged, staged, mixed

    /// Staged only when every file is, unstaged only when none is.
    public init(_ states: some Sequence<RemoteStageState>) {
        var staged = false, unstaged = false
        for state in states {
            staged = staged || state != .unstaged
            unstaged = unstaged || state != .staged
        }
        self = staged && unstaged ? .mixed : staged ? .staged : .unstaged
    }
}

/// One path of the working tree, its staged and unstaged sides merged.
public struct RemoteWorkingTreeFile: Equatable, Sendable {
    public let file: RemoteChangedFile
    public let stage: RemoteStageState

    public init(file: RemoteChangedFile, stage: RemoteStageState) {
        self.file = file
        self.stage = stage
    }
}

/// A folder or file row of `RemoteChangesRules.tree`; a folder's `items` are every file under it.
public struct RemoteChangeTreeRow<Item> {
    public let name: String
    public let path: String
    public let depth: Int
    public let isDirectory: Bool
    public let items: [Item]

    public var id: String { (isDirectory ? "dir:" : "file:") + path }
}

extension RemoteChangeTreeRow: Sendable where Item: Sendable {}

private final class TreeNode<Item> {
    var dirs: [String: TreeNode] = [:]
    var files: [(String, Item)] = []
    var items: [Item] = []
}
