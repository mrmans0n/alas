import AppKit

@MainActor
final class EditorFindHighlightRenderer {
    private weak var textView: CodeTextView?
    private var highlightedRanges: [NSRange] = []

    func attach(textView: CodeTextView) {
        if self.textView !== textView {
            clear()
            self.textView = textView
        }
    }

    func clear() {
        guard let layoutManager = textView?.layoutManager else {
            highlightedRanges.removeAll()
            return
        }

        for range in highlightedRanges {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        highlightedRanges.removeAll()
    }

    func render(matches: [NSRange], activeIndex: Int?, color: NSColor) {
        clear()

        guard let textView,
              let layoutManager = textView.layoutManager,
              !matches.isEmpty else { return }

        let textLength = (textView.string as NSString).length
        for (index, range) in matches.enumerated() {
            guard index != activeIndex,
                  range.location != NSNotFound,
                  range.location >= 0,
                  range.length > 0,
                  NSMaxRange(range) <= textLength else { continue }

            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            highlightedRanges.append(range)
        }
    }
}
