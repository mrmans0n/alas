import AppKit

@MainActor
final class EditorFindHighlightRenderer {
    private weak var textView: CodeTextView?

    func attach(textView: CodeTextView) {
        if self.textView !== textView {
            clear()
            self.textView = textView
        }
    }

    func clear() {
        guard let textView,
              let layoutManager = textView.layoutManager else {
            return
        }

        let textLength = (textView.string as NSString).length
        guard textLength > 0 else { return }
        layoutManager.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: NSRange(location: 0, length: textLength)
        )
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
        }
    }
}
