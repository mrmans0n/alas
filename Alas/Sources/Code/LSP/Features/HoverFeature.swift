import AppKit
import Markdown
import SwiftUI

@MainActor
final class HoverFeature {
    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private let getTheme: () -> Theme
    private let getMonoFontFamily: () -> String
    private let getMonoFontSize: () -> Int
    private var debounce: Task<Void, Never>?
    private var popover: NSPopover?
    private var lastPosition: NSPoint?
    private var requestID: UInt64 = 0

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        getTheme: @escaping () -> Theme,
        getMonoFontFamily: @escaping () -> String,
        getMonoFontSize: @escaping () -> Int
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.getTheme = getTheme
        self.getMonoFontFamily = getMonoFontFamily
        self.getMonoFontSize = getMonoFontSize
        textView.hoverHandler = { [weak self] p in self?.onMove(at: p) }
    }

    private func onMove(at point: NSPoint) {
        // If the mouse moved by more than ~3px, restart the debounce window.
        if let last = lastPosition, hypot(last.x - point.x, last.y - point.y) < 3 { return }
        lastPosition = point
        debounce?.cancel()
        requestID += 1
        let currentRequestID = requestID
        let captured = point
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.show(at: captured, requestID: currentRequestID)
        }
    }

    private func show(at point: NSPoint, requestID currentRequestID: UInt64) async {
        guard let textView, let client = getClient(), let uri = getURI() else {
            closePopover()
            return
        }
        guard let position = textView.lspPosition(at: point) else {
            closePopover()
            return
        }
        let result: LSPHoverResult?
        do {
            result = try await client.hover(uri: uri, position: position)
        } catch {
            guard isCurrentRequest(currentRequestID, uri: uri, position: position, point: point) else { return }
            closePopover()
            return
        }
        guard isCurrentRequest(currentRequestID, uri: uri, position: position, point: point) else { return }
        guard let result else {
            closePopover()
            return
        }
        let body: String
        let isPlain: Bool
        switch result.contents {
        case .markupContent(_, let value):
            body = value
            isPlain = false
        case .plain(let s):
            body = s
            isPlain = true
        }
        guard !body.isEmpty else {
            closePopover()
            return
        }
        let markdown = isPlain && !body.contains("`") ? "`\(body)`" : body
        let textRect = textView.firstRect(for: position) ?? CGRect(origin: point, size: .zero)
        await MainActor.run {
            guard self.isCurrentRequest(currentRequestID, uri: uri, position: position, point: point) else { return }
            self.presentPopover(text: markdown, anchor: textRect, in: textView)
        }
    }

    private func isCurrentRequest(_ currentRequestID: UInt64, uri: String, position: LSPPosition, point: NSPoint) -> Bool {
        guard !Task.isCancelled,
              requestID == currentRequestID,
              getURI() == uri,
              textView?.lspPosition(at: point) == position
        else { return false }
        return true
    }

    private func presentPopover(text: String, anchor: NSRect, in view: NSView) {
        let theme = getTheme()
        let family = getMonoFontFamily()
        let size = getMonoFontSize()

        let document = Document(parsing: text)
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: family,
            monospacedFontSize: size,
            baseDirectory: URL(fileURLWithPath: "/")
        )

        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(
            rootView: HoverContentView(result: result, theme: theme)
        )
        popover.contentViewController = host
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        self.popover = popover

        applyPopoverSize(for: result)
    }

    private func applyPopoverSize(for result: MarkdownRenderResult) {
        guard let popover else { return }
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage(attributedString: result.attributedString)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.glyphRange(for: textContainer)

        var usedRect = layoutManager.usedRect(for: textContainer)
        usedRect.size.width += 16 + 20
        usedRect.size.height += 16 + 20

        let minSize = NSSize(width: 360, height: 220)
        let maxSize = NSSize(width: 500, height: 400)
        let clamped = NSSize(
            width: max(minSize.width, min(usedRect.size.width, maxSize.width)),
            height: max(minSize.height, min(usedRect.size.height, maxSize.height))
        )
        popover.contentSize = clamped
    }

    private func closePopover() {
        popover?.close()
        popover = nil
    }
}

private struct HoverContentView: NSViewRepresentable {
    let result: MarkdownRenderResult
    let theme: Theme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        context.coordinator.textView = textView
        textView.textStorage?.setAttributedString(result.attributedString)
        scrollView.backgroundColor = NSColor(theme.color("bg-1"))
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.textStorage?.setAttributedString(result.attributedString)
        nsView.backgroundColor = NSColor(theme.color("bg-1"))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView? {
            didSet { textView?.delegate = self }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            true
        }
    }
}

enum HoverFeatureTesting {
    @MainActor
    static func makeHoverContainer(result: MarkdownRenderResult, theme: Theme) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        textView.textStorage?.setAttributedString(result.attributedString)
        scrollView.backgroundColor = NSColor(theme.color("bg-1"))
        return scrollView
    }

    static func computePreferredSize(for result: MarkdownRenderResult) -> NSSize {
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage(attributedString: result.attributedString)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.glyphRange(for: textContainer)

        var usedRect = layoutManager.usedRect(for: textContainer)
        usedRect.size.width += 16 + 20
        usedRect.size.height += 16 + 20

        let minSize = NSSize(width: 360, height: 220)
        let maxSize = NSSize(width: 500, height: 400)
        return NSSize(
            width: max(minSize.width, min(usedRect.size.width, maxSize.width)),
            height: max(minSize.height, min(usedRect.size.height, maxSize.height))
        )
    }
}

extension CodeTextView {
    /// Resolves an `LSPPosition` (line, UTF-16 character) for a point in the
    /// view's coordinate space. Returns nil if outside the text area.
    func lspPosition(at point: NSPoint) -> LSPPosition? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        // Mouse points arrive in text-view coordinates, but
        // `glyphIndex(for:in:)` expects text-container coordinates. With a
        // non-zero `textContainerInset` (we use 12, 8) the two differ — not
        // converting shifts hover/Cmd-click onto a different column or line.
        let containerPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let nsString = storage.string as NSString
        guard charIndex < nsString.length else { return nil }
        // Walk to find line + UTF-16 column
        var line = 0
        var lineStart = 0
        var i = 0
        while i < charIndex {
            if nsString.character(at: i) == 10 {  // \n
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        return LSPPosition(line: line, character: charIndex - lineStart)
    }

    /// Returns the rect (in view coords) of the character at `position`,
    /// or nil if the position is invalid.
    func firstRect(for position: LSPPosition) -> NSRect? {
        guard let storage = textStorage, let layoutManager else { return nil }
        let nsString = storage.string as NSString
        // Find UTF-16 index for (line, character).
        var charIndex = 0
        var line = 0
        while line < position.line {
            let r = nsString.range(of: "\n", options: [], range: NSRange(location: charIndex, length: nsString.length - charIndex))
            if r.location == NSNotFound { return nil }
            charIndex = r.location + 1
            line += 1
        }
        charIndex += position.character
        guard charIndex < nsString.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer!)
        // boundingRect is in container coords; the popover anchors against
        // the view's bounds, so add the inset back.
        return rect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
    }
}
