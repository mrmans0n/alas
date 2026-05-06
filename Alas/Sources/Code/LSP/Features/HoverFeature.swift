import AppKit
import SwiftUI

@MainActor
final class HoverFeature {
    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private var debounce: Task<Void, Never>?
    private var popover: NSPopover?
    private var lastPosition: NSPoint?

    init(textView: CodeTextView, getClient: @escaping () -> LSPClient?, getURI: @escaping () -> String?) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        textView.hoverHandler = { [weak self] p in self?.onMove(at: p) }
    }

    private func onMove(at point: NSPoint) {
        // If the mouse moved by more than ~3px, restart the debounce window.
        if let last = lastPosition, hypot(last.x - point.x, last.y - point.y) < 3 { return }
        lastPosition = point
        debounce?.cancel()
        let captured = point
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.show(at: captured)
        }
    }

    private func show(at point: NSPoint) async {
        guard let textView, let client = getClient(), let uri = getURI() else { return }
        guard let position = textView.lspPosition(at: point) else { return }
        let result: LSPHoverResult?
        do {
            result = try await client.hover(uri: uri, position: position)
        } catch {
            return
        }
        guard let result else { return }
        let body: String
        switch result.contents {
        case .markupContent(_, let value): body = value
        case .plain(let s):                body = s
        }
        guard !body.isEmpty else { return }
        let textRect = textView.firstRect(for: position) ?? CGRect(origin: point, size: .zero)
        await MainActor.run {
            self.presentPopover(text: body, anchor: textRect, in: textView)
        }
    }

    private func presentPopover(text: String, anchor: NSRect, in view: NSView) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 220)
        let host = NSHostingController(
            rootView: HoverContentView(markdown: text)
        )
        popover.contentViewController = host
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        self.popover = popover
    }
}

private struct HoverContentView: View {
    let markdown: String
    var body: some View {
        ScrollView {
            Text(attributed)
                .font(.system(size: 12, design: .default))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var attributed: AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
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
