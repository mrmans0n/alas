import Foundation

/// Repo-level Files-tab bookmarks: the path bookkeeping plus the walk that
/// locates a bookmarked path inside the lazily loaded file tree.
///
/// Bookmarks live on `ProjectConfig`, so every worktree of a repo shares one
/// list. A path stored there may therefore be absent from the worktree the
/// Files tab is currently showing (a different branch, a deleted directory),
/// which is what `Resolution.missing` reports.
enum FileBookmarks {
    private static let kindSeparator = "\u{0}"

    /// Where a bookmarked path currently stands in the file tree.
    enum Resolution: Equatable {
        /// The node is in the tree and can be rendered.
        case resolved(FileTreeNode)
        /// An ancestor has not listed its children yet. Ask again once the
        /// tree changes; `pendingLoadPath(for:in:)` names what to load.
        case loading
        /// An ancestor directory could not be listed. The UI keeps this
        /// distinct from a missing path and offers an explicit retry.
        case failed(String)
        /// A loaded ancestor does not contain the path — it is not in this
        /// worktree.
        case missing
    }

    /// Canonical storage form of a worktree-relative path, or nil when the
    /// path cannot be bookmarked (blank, or the worktree root itself).
    static func normalized(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var normalized = path
        while normalized.hasPrefix("/") { normalized.removeFirst() }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        guard !normalized.isEmpty, normalized != ".", normalized != ".." else { return nil }
        return normalized
    }

    static func contains(_ path: String, in bookmarks: [String]) -> Bool {
        guard let path = normalized(path) else { return false }
        return bookmarks.contains(path)
    }

    static func contains(_ node: FileTreeNode, in bookmarks: [String]) -> Bool {
        bookmarkValue(for: node, in: bookmarks) != nil
    }

    static func bookmarkValue(for node: FileTreeNode, in bookmarks: [String]) -> String? {
        let bookmark = identity(for: node)
        if bookmarks.contains(bookmark) { return bookmark }
        guard let path = normalized(node.path), bookmarks.contains(path) else { return nil }
        return path
    }

    /// Adds `path` to the end of the list, or drops it when already present.
    /// A path that cannot be bookmarked leaves the list untouched.
    static func toggled(_ path: String, in bookmarks: [String]) -> [String] {
        guard let path = normalized(path) else { return bookmarks }
        guard bookmarks.contains(path) else { return bookmarks + [path] }
        return bookmarks.filter { $0 != path }
    }

    static func toggled(_ node: FileTreeNode, in bookmarks: [String]) -> [String] {
        let bookmark = identity(for: node)
        guard !bookmarks.contains(bookmark) else { return bookmarks.filter { $0 != bookmark } }
        if let path = normalized(node.path), bookmarks.contains(path) {
            return bookmarks.filter { $0 != path }
        }
        return bookmarks + [bookmark]
    }

    static func removing(_ path: String, from bookmarks: [String]) -> [String] {
        guard let path = normalized(path) else { return bookmarks }
        return bookmarks.filter { $0 != path }
    }

    static func removing(_ node: FileTreeNode, from bookmarks: [String]) -> [String] {
        let bookmark = identity(for: node)
        guard let path = normalized(node.path) else { return bookmarks.filter { $0 != bookmark } }
        return bookmarks.filter { $0 != bookmark && $0 != path }
    }

    static func removingBookmark(_ bookmark: String, from bookmarks: [String]) -> [String] {
        bookmarks.filter { $0 != bookmark }
    }

    static func identity(for node: FileTreeNode) -> String {
        guard let path = normalized(node.path) else { return node.path }
        return "\(path)\(kindSeparator)\(node.kind.rawValue)"
    }

    static func path(for bookmark: String) -> String {
        bookmark.split(separator: Character(kindSeparator), maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? bookmark
    }

    static func kind(for bookmark: String) -> FileTreeNode.Kind? {
        let parts = bookmark.split(separator: Character(kindSeparator), maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return FileTreeNode.Kind(rawValue: String(parts[1]))
    }

    static func resolve(path: String, in nodes: [FileTreeNode]) -> Resolution {
        walk(path: path, kind: nil, in: nodes).resolution
    }

    static func resolve(bookmark: String, in nodes: [FileTreeNode]) -> Resolution {
        walk(path: path(for: bookmark), kind: kind(for: bookmark), in: nodes).resolution
    }

    /// The ancestor directory whose children must load next before `path` can
    /// resolve. Nil when the walk is already settled — resolved, missing,
    /// failed, or waiting on a load that is in flight.
    static func pendingLoadPath(for path: String, in nodes: [FileTreeNode]) -> String? {
        walk(path: path, kind: nil, in: nodes).pendingLoad
    }

    static func pendingLoadPath(forBookmark bookmark: String, in nodes: [FileTreeNode]) -> String? {
        walk(path: path(for: bookmark), kind: kind(for: bookmark), in: nodes).pendingLoad
    }

    /// Descends the tree one path component at a time. A directory's own
    /// `childrenState` decides whether its listing is authoritative, so the
    /// walk never consults the loaded-paths bookkeeping in `RightPaneState` —
    /// levels the initial eager build filled in are already `.loaded` there
    /// without ever passing through `loadFileTreeChildren`.
    private static func walk(
        path: String,
        kind: FileTreeNode.Kind?,
        in nodes: [FileTreeNode]
    ) -> (resolution: Resolution, pendingLoad: String?) {
        guard let normalized = normalized(path) else { return (.missing, nil) }
        let parts = normalized.split(separator: "/").map(String.init)
        var siblings = nodes
        for (index, part) in parts.enumerated() {
            let isLeaf = index == parts.count - 1
            guard let node = siblings.first(where: { node in
                node.name == part && (!isLeaf || kind == nil || node.kind == kind)
            }) else {
                // The parent listing is loaded and does not hold this name.
                return (.missing, nil)
            }
            if isLeaf { return (.resolved(node), nil) }
            guard node.kind == .dir else { return (.missing, nil) }
            switch node.childrenState {
            case .loaded:
                siblings = node.children ?? []
            case .notLoaded:
                return (.loading, node.path)
            case .loading:
                return (.loading, nil)
            case .failed:
                return (.failed(node.path), nil)
            }
        }
        return (.missing, nil)
    }
}
