import SwiftUI
import AppKit

/// `NSViewRepresentable` that wraps an `NSScrollView` containing a
/// `CodeTextView`. Read-only, monospaced, no soft-wrap. The coordinator
/// (`CodeEditorCoordinator`) owns load/highlight/LSP wiring — the view
/// itself just builds the AppKit hierarchy and forwards lifecycle calls.
struct CodeEditorView: NSViewRepresentable {
    typealias Coordinator = CodeEditorCoordinator

    let worktreeId: String
    let worktreeRoot: URL
    let relativePath: String
    let appState: AppState
    @Environment(\.theme) var theme

    func makeCoordinator() -> CodeEditorCoordinator {
        CodeEditorCoordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(theme.color("bg-1"))

        // Code editor pattern: textView grows in BOTH directions to fit its
        // content, independent of the scroll view's content size. Pass a
        // non-zero initial frame and a `nil` text container so NSTextView
        // creates a properly-configured one for us; we then override the
        // container's tracking + size below. `autoresizingMask = []` is
        // intentional — if the textView tracked the scrollView's width it
        // would soft-wrap instead of scrolling horizontally.
        let initialFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let textView = CodeTextView(frame: initialFrame, textContainer: nil)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        textView.drawsBackground = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []

        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false

        scroll.documentView = textView

        context.coordinator.attach(
            textView: textView,
            worktreeId: worktreeId,
            worktreeRoot: worktreeRoot,
            relativePath: relativePath,
            theme: theme
        )
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.updateIfNeeded(
            worktreeId: worktreeId,
            worktreeRoot: worktreeRoot,
            relativePath: relativePath,
            theme: theme
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: CodeEditorCoordinator) {
        coordinator.detach()
    }
}
