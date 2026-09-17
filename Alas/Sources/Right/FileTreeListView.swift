import SwiftUI

/// Everything a file-tree row needs that is identical for the Files tab's main
/// tree and for the bookmarks drawer below it. Built once per tab render and
/// handed to each `FileTreeListView`.
struct FileTreeContext {
    let worktreePath: URL
    /// Root of the worktree the tree belongs to. Nil disables dragging for the
    /// whole tree; payload resolution rejects remote roots on its own.
    let worktreeRoot: URL?
    let fileTreeGeneration: Int
    let fileTreeRefreshRevision: Int
    let showIgnored: Bool
    /// Repo-level bookmarked paths, for the context menu's add/remove wording.
    let bookmarks: [String]
    let onSelectFile: (FileTreeNode) -> Void
    let onFileHistory: (FileTreeNode) -> Void
    let onCreateFile: (String) -> Void
    let onCreateFolder: (String) -> Void
    let shouldAutoLoadChildren: (String, DirectoryChildrenState) -> Bool
    let onLoadChildren: (String) -> Void
    let onToggleBookmark: (FileTreeNode) -> Void
    let onRemoveBookmark: (String) -> Void
}

/// Renders a file tree as indented rows. Used twice by `FilesTabView`: once for
/// the worktree tree, once for the subtrees under each bookmark.
struct FileTreeListView: View {
    let nodes: [FileTreeNode]
    let context: FileTreeContext
    @Binding var openPaths: Set<String>
    var revealPath: String? = nil
    /// Namespaces the scroll ids. The bookmarks drawer renders nodes that are
    /// also in the main tree, so without a prefix both rows would answer to the
    /// same `scrollTo` anchor.
    var idPrefix: String = ""
    /// Indentation offset, so a bookmark's children line up one level in from
    /// the bookmark row that owns them.
    var baseDepth: Int = 0
    /// Paths rendered as bookmark roots: they show the parent directory as a
    /// dimmed hint, gain an inline remove button, and never merge into a
    /// compacted chain — a bookmark's identity is the path the user pinned.
    var bookmarkRootPaths: Set<String> = []
    /// Whether the `showIgnored` filter applies to `nodes` themselves. The
    /// bookmarks drawer sets this false so an explicitly pinned path stays
    /// visible; its children still honor the setting.
    var filtersRootNodes: Bool = true

    @Environment(\.theme) private var theme

    nonisolated static func rowLeadingPadding(depth: Int) -> CGFloat {
        12 + CGFloat(depth * 14)
    }

    nonisolated static func messageLeadingPadding(depth: Int) -> CGFloat {
        rowLeadingPadding(depth: depth)
    }

    var body: some View {
        ForEach(filtersRootNodes ? Self.filteredNodes(nodes, showIgnored: context.showIgnored) : nodes) { node in
            renderNode(node, depth: baseDepth)
        }
    }

    private func renderNode(_ node: FileTreeNode, depth: Int) -> AnyView {
        if node.kind == .dir {
            let chain = bookmarkRootPaths.contains(node.path)
                ? (displayName: node.name, chainPaths: [node.path], terminal: node)
                : Self.compactChain(from: node)
            let terminal = chain.terminal
            let open = Self.isOpen(chainPaths: chain.chainPaths, openPaths: openPaths)
            let canExpand = !terminal.isSubmodule
            let isBookmarkRoot = bookmarkRootPaths.contains(node.path)
            return AnyView(
                Group {
                    HStack(spacing: 0) {
                    Button {
                        guard canExpand else { return }
                        if open {
                            for p in chain.chainPaths { openPaths.remove(p) }
                        } else {
                            for p in chain.chainPaths {
                                openPaths.insert(p)
                                context.onLoadChildren(p)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            FolderIconView(
                                name: terminal.name,
                                path: terminal.path,
                                open: open,
                                fallbackColor: folderColor(for: terminal, open: open)
                            )
                            Text(chain.displayName)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(rowForeground(for: terminal))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            parentHint(for: node)
                            Spacer()
                            if terminal.isSubmodule {
                                submodulePill
                            }
                            if let badge = terminal.badge {
                                StatusBadge(status: badge)
                            }
                            if isOffGit(terminal) {
                                visibilityPill(terminal)
                            }
                            if Self.showsInlineLoadingIndicator(for: terminal, open: open, canExpand: canExpand) {
                                Spinner(lineWidth: 1.5, duration: 0.7)
                                    .frame(width: 12, height: 12)
                                    .accessibilityLabel("Loading \(terminal.name)")
                            }
                        }
                        .padding(.leading, Self.rowLeadingPadding(depth: depth))
                        .padding(.trailing, isBookmarkRoot ? 4 : 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isOffGit(terminal) ? 0.72 : 1.0)
                        .overlay(alignment: .leading) {
                            if isOffGit(terminal) {
                                ghostRail(depth: depth)
                            }
                        }
                        .contentShape(Rectangle())
                        .background(chain.chainPaths.contains(revealPath ?? "") ? theme.color("bg-hover") : Color.clear)
                        // Key the row on the chain's root (stable) rather than its
                        // terminal, which moves deeper as levels load. A stable id
                        // lets SwiftUI update the label in place while the chain
                        // compacts instead of tearing the row down and rebuilding
                        // it (a visible flash). Remaining chain paths get zero-size
                        // anchors so scroll-to-reveal still works for any of them.
                        .id("\(idPrefix)dir:\(node.path)")
                        .overlay(alignment: .top) {
                            ForEach(chain.chainPaths.dropFirst(), id: \.self) { p in
                                Color.clear.frame(width: 0, height: 0).id("\(idPrefix)dir:\(p)")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    if isBookmarkRoot {
                        removeBookmarkButton(for: node)
                            .padding(.trailing, 12)
                    }
                    }
                    .contextMenu { contextMenu(for: terminal) }
                    .dragOut {
                        context.worktreeRoot.map {
                            DragOutPayload.workingTreeFile(
                                worktreePath: $0,
                                relativePath: terminal.path
                            )
                        }
                    }
                    if open && canExpand {
                        switch terminal.childrenState {
                        case .loading, .loaded:
                            renderChildren(of: terminal, depth: depth + 1)
                        case .failed:
                            treeMessage("Could not load children", depth: depth + 1)
                            renderChildren(of: terminal, depth: depth + 1)
                        case .notLoaded:
                            EmptyView()
                        }
                    }
                }
                .task(id: loadTaskID(for: terminal, open: open)) {
                    if shouldAutoLoadChildren(for: terminal, open: open) {
                        for p in chain.chainPaths { context.onLoadChildren(p) }
                    }
                }
            )
        } else {
            let isBookmarkRoot = bookmarkRootPaths.contains(node.path)
            return AnyView(
                HStack(spacing: 0) {
                Button { context.onSelectFile(node) } label: {
                    HStack(spacing: 6) {
                        FileTypeIconView(filename: node.name, size: 18)
                        Text(node.name)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(rowForeground(for: node))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        parentHint(for: node)
                        Spacer()
                        if isOffGit(node) {
                            visibilityPill(node)
                        }
                        if let badge = node.badge {
                            StatusBadge(status: badge)
                        }
                    }
                    .padding(.leading, Self.rowLeadingPadding(depth: depth))
                    .padding(.trailing, isBookmarkRoot ? 4 : 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isOffGit(node) ? 0.72 : 1.0)
                    .overlay(alignment: .leading) {
                        if isOffGit(node) {
                            ghostRail(depth: depth)
                        }
                    }
                    .contentShape(Rectangle())
                    .background(node.path == revealPath ? theme.color("bg-hover") : Color.clear)
                    .id("\(idPrefix)\(node.id)")
                }
                .buttonStyle(.plain)
                if isBookmarkRoot {
                    removeBookmarkButton(for: node)
                        .padding(.trailing, 12)
                }
                }
                .contextMenu { contextMenu(for: node) }
                .dragOut {
                    context.worktreeRoot.map {
                        DragOutPayload.workingTreeFile(
                            worktreePath: $0,
                            relativePath: node.path
                        )
                    }
                }
            )
        }
    }

    // MARK: - Bookmark root decoration

    /// The directory a bookmark lives in, so two bookmarks with the same leaf
    /// name stay distinguishable.
    @ViewBuilder private func parentHint(for node: FileTreeNode) -> some View {
        if bookmarkRootPaths.contains(node.path) {
            let parent = node.path.split(separator: "/").dropLast().joined(separator: "/")
            if !parent.isEmpty {
                Text(parent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func removeBookmarkButton(for node: FileTreeNode) -> some View {
        Button {
            context.onRemoveBookmark(
                FileBookmarks.bookmarkValue(for: node, in: context.bookmarks) ?? FileBookmarks.identity(for: node)
            )
        } label: {
            Icon(name: "x", size: 9, color: theme.color("fg-faint"))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Remove \(node.name) from bookmarks")
        .help("Remove from Bookmarks")
    }

    // MARK: - Context menu

    @ViewBuilder private func contextMenu(for node: FileTreeNode) -> some View {
        let target = FileContextMenuTarget.resolve(
            kind: node.kind,
            worktreePath: context.worktreePath,
            relativePath: node.path
        )
        FileContextMenuActions(
            configuration: .filesTab(
                target: target,
                isBookmarked: FileBookmarks.contains(node, in: context.bookmarks)
            ),
            onNewFile: node.kind == .dir ? {
                openPaths.insert(node.path)
                context.onCreateFile(node.path)
            } : nil,
            onNewFolder: node.kind == .dir ? {
                openPaths.insert(node.path)
                context.onCreateFolder(node.path)
            } : nil,
            onOpenInAlas: node.kind == .file ? { context.onSelectFile(node) } : nil,
            onFileHistory: node.kind == .file ? { context.onFileHistory(node) } : nil,
            onCopyRelativePath: { Clipboard.copy(node.path) },
            onCopyFullPath: { Clipboard.copy(context.worktreePath.appendingPathComponent(node.path).path) },
            onToggleBookmark: { context.onToggleBookmark(node) }
        )
    }

    // MARK: - Helpers

    private func loadTaskID(for node: FileTreeNode, open: Bool) -> String {
        Self.loadTaskID(
            fileTreeGeneration: context.fileTreeGeneration,
            fileTreeRefreshRevision: context.fileTreeRefreshRevision,
            path: node.path,
            open: open,
            childrenState: node.childrenState
        )
    }

    nonisolated static func loadTaskID(
        fileTreeGeneration: Int,
        fileTreeRefreshRevision: Int,
        path: String,
        open: Bool,
        childrenState: DirectoryChildrenState
    ) -> String {
        "\(fileTreeGeneration):\(fileTreeRefreshRevision):\(path):\(open):\(childrenState.rawValue)"
    }

    private func shouldAutoLoadChildren(for node: FileTreeNode, open: Bool) -> Bool {
        open && context.shouldAutoLoadChildren(node.path, node.childrenState)
    }

    nonisolated static func showsInlineLoadingIndicator(
        for node: FileTreeNode,
        open: Bool,
        canExpand: Bool
    ) -> Bool {
        open && canExpand && node.kind == .dir && node.childrenState == .loading
    }

    private func renderChildren(of node: FileTreeNode, depth: Int) -> some View {
        Group {
            if let kids = node.children {
                ForEach(Self.filteredNodes(kids, showIgnored: context.showIgnored)) {
                    renderNode($0, depth: depth)
                }
            }
        }
    }

    nonisolated static func filteredNodes(
        _ nodes: [FileTreeNode],
        showIgnored: Bool
    ) -> [FileTreeNode] {
        guard !showIgnored else { return nodes }
        // Directories: filter children first. An ignored directory may
        // still contain tracked descendants (gitignore rules don't
        // un-track a path that's already in the index), so we only drop
        // the directory if it has no visible children left. Shared with
        // `AppState.remoteFileNodes`, which needs the exact same
        // recursive keep-if-has-visible-children behavior at the remote
        // wire boundary.
        return FileTreeNode.filteredKeepingVisibleDescendants(nodes)
    }

    nonisolated static func revealDisplayName(for path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    nonisolated static func compactChain(
        from node: FileTreeNode
    ) -> (displayName: String, chainPaths: [String], terminal: FileTreeNode) {
        var displayParts = [node.name]
        var chainPaths = [node.path]
        var current = node
        while true {
            guard
                current.kind == .dir,
                !current.isSubmodule,
                current.childrenState == .loaded,
                let children = current.children,
                children.count == 1,
                children[0].kind == .dir,
                !children[0].isSubmodule,
                children[0].childrenState == .loaded,
                children[0].visibility == current.visibility
            else { break }
            let next = children[0]
            displayParts.append(next.name)
            chainPaths.append(next.path)
            current = next
        }
        return (displayParts.joined(separator: "/"), chainPaths, current)
    }

    /// A compacted row may gain a deeper terminal as lazy child listings
    /// arrive. Its expansion belongs to the displayed chain, not only to
    /// whichever directory is currently the terminal.
    nonisolated static func isOpen(chainPaths: [String], openPaths: Set<String>) -> Bool {
        chainPaths.contains { openPaths.contains($0) }
    }

    private func isOffGit(_ node: FileTreeNode) -> Bool {
        node.visibility == .ignored || node.visibility == .excluded
    }

    private func rowForeground(for node: FileTreeNode) -> Color {
        isOffGit(node) ? theme.color("fg-dim") : theme.color("fg")
    }

    private func folderColor(for node: FileTreeNode, open: Bool) -> Color {
        if isOffGit(node) {
            return theme.color("fg-dim")
        }
        return open ? theme.color("accent") : theme.color("fg-dim")
    }

    private func visibilityPill(_ node: FileTreeNode) -> some View {
        Text(node.visibility.rawValue)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.color("bg-4").opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var submodulePill: some View {
        Text("submodule")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.color("submodule"))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.color("submodule").opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func ghostRail(depth: Int) -> some View {
        Rectangle()
            .fill(theme.color("fg-faint").opacity(0.55))
            .frame(width: 2)
            .padding(.leading, CGFloat(8 + depth * 14))
            .padding(.vertical, 4)
    }

    private func treeMessage(_ text: String, depth: Int) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.leading, Self.messageLeadingPadding(depth: depth))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
