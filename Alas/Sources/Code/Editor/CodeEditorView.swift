import SwiftUI
import AppKit

/// `NSClipView` subclass that prevents AppKit from placing the document before
/// the leading edge during initial layout, while preserving normal horizontal
/// scrolling for long lines.
final class CodeEditorLeadingClipView: NSClipView {
    private var preservesNextExplicitZeroOrigin = false

    override func scroll(to newOrigin: NSPoint) {
        defer { preservesNextExplicitZeroOrigin = false }
        super.scroll(to: pinnedOrigin(for: newOrigin))
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        defer { preservesNextExplicitZeroOrigin = false }
        super.setBoundsOrigin(pinnedOrigin(for: newOrigin))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        let leadingX = leadingBoundsOriginX
        guard enclosingScrollView?.hasHorizontalScroller == true,
              let documentView else {
            bounds.origin.x = leadingX
            return bounds
        }

        let maxX = max(documentView.frame.width - bounds.width, leadingX)
        bounds.origin.x = resolvedOriginX(
            proposed: proposedBounds.origin.x,
            clamped: bounds.origin.x,
            leadingX: leadingX,
            maxX: maxX
        )
        return bounds
    }

    private func pinnedOrigin(for origin: NSPoint) -> NSPoint {
        guard enclosingScrollView?.hasHorizontalScroller == true else { return origin }
        let leadingX = leadingBoundsOriginX
        if leadingX < 0, origin.x == 0 {
            preservesNextExplicitZeroOrigin = true
            return origin
        }
        // Only enforce the leading edge here; `constrainBoundsRect` (which
        // `super.scroll`/`setBoundsOrigin` funnel through) applies the upper
        // bound and the gutter-reset handling.
        let resolved = resolvedOriginX(
            proposed: origin.x,
            clamped: max(origin.x, leadingX),
            leadingX: leadingX,
            maxX: .greatestFiniteMagnitude
        )
        return resolved == origin.x ? origin : NSPoint(x: resolved, y: origin.y)
    }

    /// Resolves a proposed horizontal origin against the gutter-adjusted leading
    /// edge (`leadingX`, e.g. `-rulerThickness`).
    ///
    /// AppKit's layout and frame-change passes repeatedly propose `x == 0` — they
    /// treat `0` as the leading edge, unaware the line-number gutter shifts the
    /// true leading to `leadingX`. Whichever pass runs last would otherwise win,
    /// so the first characters of a line intermittently end up hidden under the
    /// gutter. Snapping layout-only `0` resets to `leadingX` fixes the race while
    /// still preserving an explicit scroll/scrollbar move that lands exactly on
    /// zero.
    private func resolvedOriginX(proposed: CGFloat, clamped: CGFloat, leadingX: CGFloat, maxX: CGFloat) -> CGFloat {
        guard leadingX < 0 else { return min(max(clamped, leadingX), maxX) }

        if proposed == 0 {
            if preservesNextExplicitZeroOrigin {
                preservesNextExplicitZeroOrigin = false
                return min(max(clamped, leadingX), maxX)
            }
            return leadingX
        }

        preservesNextExplicitZeroOrigin = false
        return min(max(clamped, leadingX), maxX)
    }

    /// The leading-most horizontal bounds origin. A left-side vertical ruler
    /// (the line-number gutter) makes AppKit shift the clip's bounds origin
    /// negative by the ruler's reserved thickness so the document content
    /// clears the gutter. The true leading edge is therefore `-rulerThickness`,
    /// not `0` — clamping to `0` hides the first characters of every line under
    /// the gutter with no way to scroll them back into view.
    private var leadingBoundsOriginX: CGFloat {
        guard let scrollView = enclosingScrollView,
              scrollView.rulersVisible,
              let ruler = scrollView.verticalRulerView,
              ruler.orientation == .verticalRuler else { return 0 }
        return -ruler.requiredThickness
    }
}

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
    var revealEndLine: Int? = nil
    let revealCharacter: Int?
    let revealRevision: Int?
    let appState: AppState
    let externalAbsolutePath: String?
    /// Whether an external tab is editable (opt-in for run-script edits).
    /// `false` for the default read-only external navigation tabs.
    var externalEditable: Bool = false
    /// The worktree-relative path of the in-worktree file from which the
    /// user navigated to this external tab. Used to route LSP traffic for
    /// the external file to the correct holder in nested-package layouts.
    let originatingRelativePath: String?
    /// Pulled from `appState.config.code.fontFamily` by the parent view's
    /// body so SwiftUI registers the dependency. NSViewRepresentable hooks
    /// (makeNSView/updateNSView) are not part of body evaluation, so reads
    /// inside them are not tracked — passing the values as inputs is what
    /// causes `updateNSView` to fire when the user changes the font.
    let fontFamily: String
    let fontSize: Int
    let showLineNumbers: Bool
    var onTextViewAttached: (CodeTextView) -> Void = { _ in }
    var onTextViewDetached: (CodeTextView?) -> Void = { _ in }
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
        // Since the macOS 14 SDK `clipsToBounds` defaults to `false`, so the
        // scroll view no longer clips its subviews. Without this, the vertical
        // ruler's responsive-scrolling overdraw paints line numbers above the
        // scroll view's top edge, bleeding over the breadcrumb header that sits
        // directly above the editor in the enclosing SwiftUI VStack.
        scroll.clipsToBounds = true
        scroll.contentView = CodeEditorLeadingClipView(frame: .zero)

        let buffer: EditorBuffer
        if let abs = externalAbsolutePath {
            let absoluteURL = URL(fileURLWithPath: abs)
            let ext = (abs as NSString).pathExtension
            let language = appState.lsp.language(forFileExtension: ext)
            let originatingFileURL: URL? = originatingRelativePath.map { worktreeRoot.appendingPathComponent($0) }
            buffer = appState.tabs.externalBuffer(
                worktreeId: worktreeId,
                tabId: tabId,
                absoluteURL: absoluteURL,
                worktreeRoot: worktreeRoot,
                originatingFileURL: originatingFileURL,
                language: language,
                editable: externalEditable
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
        configureLineNumberRuler(for: scroll, textView: textView)

        configureLifecycleCallbacks(on: context.coordinator)
        context.coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: worktreeId,
            worktreeRoot: worktreeRoot,
            tabId: tabId,
            revealLine: revealLine,
            revealEndLine: revealEndLine,
            revealCharacter: revealCharacter,
            revealRevision: revealRevision,
            theme: theme,
            externalAbsolutePath: externalAbsolutePath,
            originatingRelativePath: originatingRelativePath,
            externalEditable: externalEditable
        )
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        configureLifecycleCallbacks(on: context.coordinator)
        context.coordinator.updateIfNeeded(
            worktreeId: worktreeId,
            worktreeRoot: worktreeRoot,
            relativePath: relativePath,
            tabId: tabId,
            revealLine: revealLine,
            revealEndLine: revealEndLine,
            revealCharacter: revealCharacter,
            revealRevision: revealRevision,
            theme: theme,
            externalAbsolutePath: externalAbsolutePath,
            originatingRelativePath: originatingRelativePath,
            externalEditable: externalEditable
        )

        if let textView = nsView.documentView as? CodeTextView {
            configureLineNumberRuler(for: nsView, textView: textView)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: CodeEditorCoordinator) {
        // Detach the coordinator from the text view, but DO NOT close the
        // buffer's LSP document or watcher — the buffer outlives this view.
        coordinator.detach()
    }

    private func configureLifecycleCallbacks(on coordinator: CodeEditorCoordinator) {
        let expectedTabId = tabId
        coordinator.onTextViewAttached = { textView, attachedTabId in
            guard attachedTabId == expectedTabId else { return }
            DispatchQueue.main.async {
                onTextViewAttached(textView)
            }
        }
        coordinator.onTextViewDetached = { textView, detachedTabId in
            guard detachedTabId == nil || detachedTabId == expectedTabId else { return }
            DispatchQueue.main.async {
                onTextViewDetached(textView)
            }
        }
    }

    private func configureLineNumberRuler(for scrollView: NSScrollView, textView: CodeTextView) {
        guard showLineNumbers else {
            scrollView.verticalRulerView = nil
            scrollView.hasVerticalRuler = false
            scrollView.rulersVisible = false
            return
        }

        let ruler: CodeEditorLineNumberRulerView
        if let existingRuler = scrollView.verticalRulerView as? CodeEditorLineNumberRulerView {
            existingRuler.update(textView: textView, theme: theme)
            ruler = existingRuler
        } else {
            ruler = CodeEditorLineNumberRulerView(
                scrollView: scrollView,
                textView: textView,
                theme: theme
            )
            scrollView.verticalRulerView = ruler
        }

        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        ruler.needsDisplay = true
    }
}
