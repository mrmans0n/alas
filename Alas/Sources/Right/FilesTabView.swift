import SwiftUI

struct FilesTabView: View {
    let nodes: [FileTreeNode]
    let fileTreeGeneration: Int
    let worktreePath: URL
    @Binding var openPaths: Set<String>
    let onSelectFile: (FileTreeNode) -> Void
    let onFileHistory: (FileTreeNode) -> Void
    let onCreateFile: (String) -> Void
    let onCreateFolder: (String) -> Void
    let shouldAutoLoadChildren: (String, DirectoryChildrenState) -> Bool
    let onLoadChildren: (String) -> Void
    let showIgnored: Bool
    let revealPath: String?
    let revealTick: Int
    let onClearReveal: () -> Void

    /// Root of the worktree the tree belongs to. Nil disables dragging for the
    /// whole tree; payload resolution rejects remote roots on its own.
    var worktreeRoot: URL? = nil

    /// Repo-level bookmarks. Empty hides the drawer entirely.
    var bookmarks: [String] = []
    var onToggleBookmark: (FileTreeNode) -> Void = { _ in }
    var onRemoveBookmark: (String) -> Void = { _ in }
    /// Expansion state for the drawer, kept apart from `openPaths` so
    /// expanding a bookmark doesn't move the tree above it.
    @Binding var bookmarkOpenPaths: Set<String>
    /// Persisted drawer height; nil until the user drags the divider.
    var bookmarksPaneHeight: Double? = nil
    var onSetBookmarksPaneHeight: (Double) -> Void = { _ in }
    /// Called once the divider is released, so the height is persisted once
    /// rather than on every drag frame.
    var onCommitBookmarksPaneHeight: () -> Void = {}
    var bookmarksCollapsed: Bool = false
    var onToggleBookmarksCollapsed: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                treePane
                if !bookmarks.isEmpty {
                    if !bookmarksCollapsed {
                        DragHandle(
                            axis: .vertical,
                            onDragChanged: { translation in
                                let containerHeight = geometry.size.height
                                let start = dragStartHeight ?? resolvedPaneHeight(containerHeight: containerHeight)
                                if dragStartHeight == nil { dragStartHeight = start }
                                // Dragging up (negative translation) grows the drawer.
                                onSetBookmarksPaneHeight(
                                    FilesBookmarksPaneMetrics.clamp(
                                        start - translation,
                                        containerHeight: containerHeight
                                    )
                                )
                            },
                            onDragEnded: {
                                dragStartHeight = nil
                                onCommitBookmarksPaneHeight()
                            }
                        )
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(theme.color("line").opacity(0.7))
                                .frame(height: 1)
                        }
                    }
                    FilesBookmarksPane(
                        bookmarks: bookmarks,
                        nodes: nodes,
                        context: treeContext,
                        openPaths: $bookmarkOpenPaths,
                        collapsed: bookmarksCollapsed,
                        onToggleCollapsed: onToggleBookmarksCollapsed
                    )
                    .frame(height: bookmarksCollapsed ? nil : resolvedPaneHeight(containerHeight: geometry.size.height))
                }
            }
        }
    }

    private var treePane: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                revealBar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        FileTreeListView(
                            nodes: nodes,
                            context: treeContext,
                            openPaths: $openPaths,
                            revealPath: revealPath
                        )
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu { rootContextMenu }
                .onChange(of: revealTick) { _, _ in
                    guard let path = revealPath else { return }
                    proxy.scrollTo("file:\(path)", anchor: .top)
                    proxy.scrollTo("dir:\(path)", anchor: .top)
                }
            }
        }
    }

    private var treeContext: FileTreeContext {
        FileTreeContext(
            worktreePath: worktreePath,
            worktreeRoot: worktreeRoot,
            fileTreeGeneration: fileTreeGeneration,
            showIgnored: showIgnored,
            bookmarks: bookmarks,
            onSelectFile: onSelectFile,
            onFileHistory: onFileHistory,
            onCreateFile: onCreateFile,
            onCreateFolder: onCreateFolder,
            shouldAutoLoadChildren: shouldAutoLoadChildren,
            onLoadChildren: onLoadChildren,
            onToggleBookmark: onToggleBookmark,
            onRemoveBookmark: onRemoveBookmark
        )
    }

    private func resolvedPaneHeight(containerHeight: CGFloat) -> CGFloat {
        guard let bookmarksPaneHeight else {
            return FilesBookmarksPaneMetrics.defaultHeight(containerHeight: containerHeight)
        }
        return FilesBookmarksPaneMetrics.clamp(
            CGFloat(bookmarksPaneHeight),
            containerHeight: containerHeight
        )
    }

    @ViewBuilder
    private var revealBar: some View {
        if let revealPath {
            HStack(spacing: 6) {
                Icon(name: "target", size: 12, color: theme.color("accent"))
                    .frame(width: 14, height: 14)
                Text(FileTreeListView.revealDisplayName(for: revealPath))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: onClearReveal) {
                    Icon(name: "x", size: 10, color: theme.color("fg-dim"))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Clear focused file highlight")
                .help("Clear focused file highlight")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(theme.color("bg-3").opacity(0.92))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.color("line").opacity(0.7))
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder private var rootContextMenu: some View {
        let target = FileContextMenuTarget.resolve(
            kind: .dir,
            worktreePath: worktreePath,
            relativePath: ""
        )
        // No `isBookmarked`: this menu targets the worktree root, which is not
        // a bookmarkable path.
        FileContextMenuActions(
            configuration: .filesTab(target: target),
            onNewFile: { onCreateFile("") },
            onNewFolder: { onCreateFolder("") },
            onCopyRelativePath: { Clipboard.copy(".") },
            onCopyFullPath: { Clipboard.copy(worktreePath.path) }
        )
    }
}
