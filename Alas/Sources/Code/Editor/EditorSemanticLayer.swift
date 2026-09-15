import AppKit

@MainActor
final class EditorSemanticLayer {
    private weak var layoutManager: NSLayoutManager?
    private var theme: EditorTheme
    private let isCurrent: (EditorRequestContext) -> Bool
    private var spans: [HighlightSpan] = []
    private var context: EditorRequestContext?
    private var sourceRevision: Int?
    private weak var textView: CodeTextView?
    private var projectionObserver: NSObjectProtocol?

    deinit { if let projectionObserver { NotificationCenter.default.removeObserver(projectionObserver) } }

    init(layoutManager: NSLayoutManager, theme: EditorTheme, textView: CodeTextView? = nil, isCurrent: @escaping (EditorRequestContext) -> Bool) {
        self.layoutManager = layoutManager
        self.theme = theme
        self.isCurrent = isCurrent
        self.textView = textView
        if let textView {
            projectionObserver = NotificationCenter.default.addObserver(forName: .editorDisplayProjectionDidChange, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }
                self.reapply(theme: self.theme) }
            }
        }
    }

    func replace(_ spans: [HighlightSpan], context: EditorRequestContext) {
        guard isCurrent(context), let length = textView?.sourceAttributedText.length ?? layoutManager?.textStorage?.length,
              spans.allSatisfy({ $0.range.location >= 0 && $0.range.location <= length && $0.range.length > 0 && $0.range.length <= length - $0.range.location }) else { return }
        if let textView, !spans.allSatisfy({ textView.nativeRange(forSource: $0.range) != nil }) { return }
        clear()
        self.spans = spans
        self.context = context
        sourceRevision = textView?.displayAdapter?.buffer.editGeneration
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
        sourceRevision = nil
    }

    func reapply(theme: EditorTheme) {
        self.theme = theme
        guard let context, isCurrent(context), sourceRevision == textView?.displayAdapter?.buffer.editGeneration,
              let layoutManager, let storage = layoutManager.textStorage else { clear()
        return }
        let length = textView?.sourceAttributedText.length ?? storage.length
        guard spans.allSatisfy({ $0.range.location <= length && $0.range.length <= length - $0.range.location }) else { clear()
        return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        for span in spans {
            for range in textView?.displaySegments(forSource: span.range) ?? [span.range] {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: theme.attributes(for: span.capture)[.foregroundColor]!, forCharacterRange: range)
            }
        }
    }
}
