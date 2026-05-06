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

        // Build an explicit TextKit 1 chain. On macOS 14+ NSTextView defaults
        // to TextKit 2 (NSTextLayoutManager + NSTextContentStorage) when it
        // creates its own container — and in that mode the legacy
        // `textView.textStorage` returns nil, so any code that mutates it
        // silently no-ops. We rely on `textStorage.setAttributedString(...)`
        // and `addAttributes(_:range:)` for highlights and diagnostics, so
        // we need TextKit 1. Wiring the chain manually (storage → layout
        // manager → container → text view) guarantees that.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        // Two-direction-scroll code editor: the textView grows to fit its
        // content (longest line = width, total lines = height); it does
        // NOT track the scroll view's size. Hence autoresizingMask = [].
        let initialFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let textView = CodeTextView(frame: initialFrame, textContainer: textContainer)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        textView.drawsBackground = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []

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
