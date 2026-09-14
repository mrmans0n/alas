import AppKit

@MainActor
final class EditorSemanticLayer {
    private weak var layoutManager: NSLayoutManager?
    private var theme: EditorTheme
    private let isCurrent: (EditorRequestContext) -> Bool
    private var spans: [HighlightSpan] = []
    private var context: EditorRequestContext?

    init(layoutManager: NSLayoutManager, theme: EditorTheme, isCurrent: @escaping (EditorRequestContext) -> Bool) {
        self.layoutManager = layoutManager
        self.theme = theme
        self.isCurrent = isCurrent
    }

    func replace(_ spans: [HighlightSpan], context: EditorRequestContext) {
        guard isCurrent(context), let length = layoutManager?.textStorage?.length,
              spans.allSatisfy({ $0.range.location >= 0 && $0.range.location <= length && $0.range.length > 0 && $0.range.length <= length - $0.range.location }) else { return }
        clear()
        self.spans = spans
        self.context = context
        reapply(theme: theme)
    }

    /// Temporary foreground belongs exclusively to this layer. Clearing the
    /// whole current storage also removes ranges shifted by a character edit.
    func clear() {
        if let layoutManager, let storage = layoutManager.textStorage {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        spans = []
        context = nil
    }

    func reapply(theme: EditorTheme) {
        self.theme = theme
        guard let context, isCurrent(context), let layoutManager, let storage = layoutManager.textStorage else { clear()
        return }
        guard spans.allSatisfy({ $0.range.location <= storage.length && $0.range.length <= storage.length - $0.range.location }) else { clear()
        return }
        for span in spans {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: theme.attributes(for: span.capture)[.foregroundColor]!, forCharacterRange: span.range)
        }
    }
}
