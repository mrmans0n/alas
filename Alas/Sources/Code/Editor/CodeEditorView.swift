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
    let tabId: TabID
    let revealLine: Int?
    let revealCharacter: Int?
    let appState: AppState
    let externalAbsolutePath: String?
    /// Pulled from `appState.config.code.fontFamily` by the parent view's
    /// body so SwiftUI registers the dependency. NSViewRepresentable hooks
    /// (makeNSView/updateNSView) are not part of body evaluation, so reads
    /// inside them are not tracked — passing the values as inputs is what
    /// causes `updateNSView` to fire when the user changes the font.
    let fontFamily: String
    let fontSize: Int
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

        let buffer: EditorBuffer
        if let abs = externalAbsolutePath {
            buffer = appState.tabs.externalBuffer(
                worktreeId: worktreeId,
                tabId: tabId,
                absoluteURL: URL(fileURLWithPath: abs)
            )
        } else {
            buffer = appState.tabs.buffer(
                worktreeId: worktreeId,
                tabId: tabId,
                worktreeRoot: worktreeRoot,
                relativePath: relativePath
            )
        }

        // Build the TextKit 1 chain. The coordinator owns the
        // storage<->layoutManager binding (see `bindBuffer`) so that swapping
        // buffers across tab switches can rebind onto the new storage; we
        // pass an unattached layout manager here.
        let layoutManager = NSLayoutManager()
        let containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let initialFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let textView = CodeTextView(frame: initialFrame, textContainer: textContainer)
        textView.font = CodeEditorCoordinator.resolveFont(
            family: fontFamily,
            size: CGFloat(fontSize)
        )
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
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: worktreeId,
            worktreeRoot: worktreeRoot,
            tabId: tabId,
            revealLine: revealLine,
            revealCharacter: revealCharacter,
            theme: theme,
            externalAbsolutePath: externalAbsolutePath
        )
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.updateIfNeeded(
            worktreeId: worktreeId,
            worktreeRoot: worktreeRoot,
            relativePath: relativePath,
            tabId: tabId,
            revealLine: revealLine,
            revealCharacter: revealCharacter,
            theme: theme,
            externalAbsolutePath: externalAbsolutePath
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: CodeEditorCoordinator) {
        // Detach the coordinator from the text view, but DO NOT close the
        // buffer's LSP document or watcher — the buffer outlives this view.
        coordinator.detach()
    }
}
