import AppKit

/// Thin wrapper around `NSWorkspace` for system-open and reveal-in-Finder
/// affordances exposed in the editor/image/binary panes and tab-bar menus.
enum FileSystemOpen {
    /// Open `url` with the system's default handler (same as `open <url>` on the CLI).
    @MainActor
    static func open(url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Reveal `url` in a Finder window with the item selected.
    @MainActor
    static func reveal(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}