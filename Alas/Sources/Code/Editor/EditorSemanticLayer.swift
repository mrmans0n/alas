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
    private var projectionWillChangeObserver: NSObjectProtocol?
    private var paintedRanges: [NSRange] = []
    private var isProvisional = false

    isolated deinit {
        if let projectionObserver { NotificationCenter.default.removeObserver(projectionObserver) }
        if let projectionWillChangeObserver { NotificationCenter.default.removeObserver(projectionWillChangeObserver) }
    }

    init(layoutManager: NSLayoutManager, theme: EditorTheme, textView: CodeTextView? = nil, isCurrent: @escaping (EditorRequestContext) -> Bool) {
        self.layoutManager = layoutManager
        self.theme = theme
        self.isCurrent = isCurrent
        self.textView = textView
        if let textView {
            projectionWillChangeObserver = NotificationCenter.default.addObserver(forName: .editorDisplayProjectionWillChange, object: textView, queue: .main) { [weak self] notification in
                let edit = notification.userInfo?[EditorDisplayProjectionUserInfo.sourceEdit] as? EditorTextEdit
                let revision = notification.userInfo?[EditorDisplayProjectionUserInfo.revision] as? Int
                MainActor.assumeIsolated { self?.projectionWillChange(edit: edit, revision: revision) }
            }
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
        isProvisional = false
        reapply(theme: theme)
    }

    func clear() {
        clearPaint()
        spans = []
        context = nil
        sourceRevision = nil
        isProvisional = false
    }

    private func clearPaint() {
        defer { paintedRanges = [] }
        guard let layoutManager, let storage = layoutManager.textStorage else { return }
        // Legacy, unprojected storage can move before we receive an edit. The
        // projected path clears before mutation and can use exact owned ranges.
        let ranges = textView?.displayAdapter == nil ? [NSRange(location: 0, length: storage.length)] : paintedRanges
        for range in ranges {
            guard let clipped = range.intersection(NSRange(location: 0, length: storage.length)), clipped.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clipped)
        }
    }

    func reapply(theme: EditorTheme) {
        self.theme = theme
        guard sourceRevision == textView?.displayAdapter?.buffer.editGeneration,
              isProvisional || context.map(isCurrent) == true,
              let layoutManager, let storage = layoutManager.textStorage else { clear()
        return }
        let length = textView?.sourceAttributedText.length ?? storage.length
        guard spans.allSatisfy({ $0.range.location <= length && $0.range.length <= length - $0.range.location }) else { clear()
        return }
        clearPaint()
        for span in spans {
            for range in textView?.displaySegments(forSource: span.range) ?? [span.range] {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: theme.attributes(for: span.capture)[.foregroundColor]!, forCharacterRange: range)
                paintedRanges.append(range)
            }
        }
    }

    private func projectionWillChange(edit: EditorTextEdit?, revision: Int?) {
        clearPaint()
        guard let revision else {
            clearState()
            return
        }
        guard let edit else {
            if sourceRevision != revision { clearState() }
            return
        }
        guard sourceRevision.map({ $0 &+ 1 }) == revision else {
            clearState()
            return
        }
        spans = spans.compactMap { span in
            let start = span.range.location
            let end = NSMaxRange(span.range)
            let oldEnd = NSMaxRange(edit.oldRange)
            let delta = edit.newLength - edit.oldLength
            if edit.oldLength == 0 {
                if end < edit.location { return span }
                if start > edit.location {
                    return HighlightSpan(range: NSRange(location: start + delta, length: span.range.length), capture: span.capture)
                }
                guard !edit.replacementText.contains("\n"), !edit.replacementText.contains("\r") else { return nil }
                return HighlightSpan(range: NSRange(location: start, length: span.range.length + delta), capture: span.capture)
            }
            if end <= edit.location { return span }
            if start >= oldEnd {
                return HighlightSpan(range: NSRange(location: start + delta, length: span.range.length), capture: span.capture)
            }
            return nil
        }
        sourceRevision = revision
        isProvisional = true
    }

    private func clearState() {
        spans = []
        context = nil
        sourceRevision = nil
        isProvisional = false
    }
}
