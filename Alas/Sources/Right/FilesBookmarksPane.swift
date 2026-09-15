import SwiftUI

/// Height bounds for the Files-tab bookmarks drawer, as a fraction of the tab.
enum FilesBookmarksPaneMetrics {
    static let minFraction: CGFloat = 0.25
    static let maxFraction: CGFloat = 0.5
    /// Stand-in until the tab reports a height, so the drawer never collapses
    /// to nothing on first layout.
    static let fallbackContainerHeight: CGFloat = 520

    static func bounds(containerHeight: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let height = containerHeight > 0 ? containerHeight : fallbackContainerHeight
        return (height * minFraction, height * maxFraction)
    }

    static func clamp(_ height: CGFloat, containerHeight: CGFloat) -> CGFloat {
        let bounds = bounds(containerHeight: containerHeight)
        return Swift.min(Swift.max(height, bounds.min), bounds.max)
    }

    static func defaultHeight(containerHeight: CGFloat) -> CGFloat {
        let bounds = bounds(containerHeight: containerHeight)
        return (bounds.min + bounds.max) / 2
    }
}

/// The bookmarks drawer under the Files tab's tree. Bookmarks are repo-level,
/// so a path stored here may be absent from the worktree on screen — those rows
/// stay visible and dimmed rather than silently disappearing.
struct FilesBookmarksPane: View {
    let bookmarks: [String]
    let nodes: [FileTreeNode]
    let context: FileTreeContext
    @Binding var openPaths: Set<String>

    @Environment(\.theme) private var theme

    private var rootPaths: Set<String> { Set(bookmarks) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(bookmarks, id: \.self) { path in
                        row(for: path)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(theme.color("bg-2"))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Icon(name: "star.fill", size: 9, color: theme.color("fg-faint"))
                .frame(width: 12, height: 12)
            Text("BOOKMARKS")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
            Text("\(bookmarks.count)")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(theme.color("seg-pill-bg"))
                .clipShape(Capsule())
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 8)
        }
        .paneBand(fill: theme.color("section-head-bg"))
    }

    @ViewBuilder private func row(for path: String) -> some View {
        switch FileBookmarks.resolve(path: path, in: nodes) {
        case .resolved(let node):
            FileTreeListView(
                nodes: [node],
                context: context,
                openPaths: $openPaths,
                idPrefix: "bm:",
                bookmarkRootPaths: rootPaths,
                filtersRootNodes: false
            )
        case .loading:
            placeholderRow(for: path) {
                Spinner(lineWidth: 1.5, duration: 0.7)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Loading \(FilesBookmarksPane.leafName(of: path))")
            }
        case .missing:
            placeholderRow(for: path) {
                Icon(name: "folder", size: 12, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
            }
            .help("Not present in this worktree")
        }
    }

    /// A bookmark that has no node to render yet (or at all). Matches the tree
    /// row's metrics so the drawer doesn't jump when the real row arrives.
    private func placeholderRow<Leading: View>(
        for path: String,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 6) {
            leading()
            Text(FilesBookmarksPane.leafName(of: path))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
            if let parent = FilesBookmarksPane.parentPath(of: path) {
                Text(parent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                context.onToggleBookmark(path)
            } label: {
                Icon(name: "x", size: 9, color: theme.color("fg-faint"))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Remove \(FilesBookmarksPane.leafName(of: path)) from bookmarks")
            .help("Remove from Bookmarks")
        }
        .padding(.leading, FileTreeListView.rowLeadingPadding(depth: 0))
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(0.72)
    }

    nonisolated static func leafName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    nonisolated static func parentPath(of path: String) -> String? {
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        return parent.isEmpty ? nil : parent
    }
}
