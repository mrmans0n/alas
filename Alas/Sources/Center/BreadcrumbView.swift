import AppKit
import SwiftUI

/// Per-segment context-menu payload for a file segment (the last breadcrumb).
struct BreadcrumbFileMenu {
    var onViewAtHEAD: (() -> Void)? = nil
    var onCompareWithHEAD: (() -> Void)? = nil
    var onFileHistory: (() -> Void)? = nil
    var onCopyRelativePath: (() -> Void)? = nil
    var onCopyFullPath: (() -> Void)? = nil
    var onRevealInFinder: (() -> Void)? = nil
    var onOpenWithSystem: (() -> Void)? = nil
}

/// Per-segment context-menu payload for an intermediate folder segment.
struct BreadcrumbFolderMenu {
    var onRevealInFinder: (() -> Void)? = nil
    var onFocusInFiles: (() -> Void)? = nil
    var onCopyFullPath: (() -> Void)? = nil
}

enum BreadcrumbMenuItems {
    case file(BreadcrumbFileMenu)
    case folder(BreadcrumbFolderMenu)
}

/// Shared breadcrumb bar used by EditorTabView, ImagePreviewTabView, and
/// BinaryPreviewTabView. Renders `relativePath` split on "/"; intermediate
/// segments tap-to-reveal in the Files tab; the last segment is the file.
/// Right-click on any segment shows a context menu supplied by `menuItems`.
struct BreadcrumbView: View {
    let relativePath: String
    let onRevealInFiles: (String) -> Void
    /// Receives (segmentIndex, pathPrefix). Returns the menu items for that
    /// segment. The last segment is the file; intermediate segments are
    /// folders. Callers branch on the index to decide.
    let menuItems: (Int, String) -> BreadcrumbMenuItems
    /// Optional trailing view (e.g. the editor's LSP status badge).
    var trailing: AnyView? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        let components = relativePath.split(separator: "/")
        let lastIndex = components.count - 1
        return HStack(spacing: 6) {
            if components.isEmpty {
                Text("").font(.system(size: 11, design: .monospaced))
            } else {
                ForEach(Array(components.enumerated()), id: \.offset) { (i, comp) in
                    let pathPrefix = components[0...i].joined(separator: "/")
                    Text(String(comp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(i == lastIndex ? theme.color("fg") : theme.color("fg-muted"))
                        .onTapGesture { onRevealInFiles(String(pathPrefix)) }
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() }
                            else { NSCursor.pointingHand.pop() }
                        }
                        .contextMenu { menu(for: i, pathPrefix: String(pathPrefix)) }
                    if i < lastIndex {
                        Text("/").foregroundColor(theme.color("fg-faint"))
                    }
                }
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func menu(for index: Int, pathPrefix: String) -> some View {
        switch menuItems(index, pathPrefix) {
        case .file(let m):
            if let m = m.onViewAtHEAD { Button("View at HEAD") { m() } }
            if let m = m.onCompareWithHEAD { Button("Compare with HEAD") { m() } }
            if let m = m.onFileHistory { Button("File History") { m() } }
            if let m = m.onCopyRelativePath { Button("Copy Relative Path") { m() } }
            if let m = m.onCopyFullPath { Button("Copy Full Path") { m() } }
            if let m = m.onRevealInFinder { Button("Reveal in Finder") { m() } }
            if let m = m.onOpenWithSystem { Button("Open with System") { m() } }
        case .folder(let m):
            if let m = m.onRevealInFinder { Button("Reveal in Finder") { m() } }
            if let m = m.onFocusInFiles { Button("Focus on Files tab") { m() } }
            if let m = m.onCopyFullPath { Button("Copy Full Path") { m() } }
        }
    }
}