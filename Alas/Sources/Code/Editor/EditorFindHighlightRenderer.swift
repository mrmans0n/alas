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
        for range in markedRanges(layoutManager: layoutManager, textLength: textLength).reversed() {
            clearMarkedRange(range, layoutManager: layoutManager)
        }
    }

    func render(matches: [NSRange], activeIndex: Int?, inactiveColor: NSColor, activeColor: NSColor) {
        clear()

        guard let textView,
              let layoutManager = textView.layoutManager,
              !matches.isEmpty else { return }

        let textLength = (textView.string as NSString).length
        for (index, range) in matches.enumerated() {
            guard isRenderable(range: range, textLength: textLength) else { continue }

            let color = index == activeIndex ? activeColor : inactiveColor
            addFindBackground(color, for: range, layoutManager: layoutManager)
        }
    }

    private func isRenderable(range: NSRange, textLength: Int) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              textLength > 0 else { return false }

        return NSMaxRange(range) <= textLength
    }

    private func addFindBackground(_ color: NSColor, for range: NSRange, layoutManager: NSLayoutManager) {
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            var effectiveRange = NSRange(location: location, length: end - location)
            let previousBackground = layoutManager.temporaryAttribute(
                .backgroundColor,
                atCharacterIndex: location,
                effectiveRange: &effectiveRange
            )
            let segment = effectiveRange.intersection(range) ?? NSRange(location: location, length: end - location)
            guard segment.length > 0 else { break }

            layoutManager.addTemporaryAttribute(
                .editorFindPreviousBackgroundColor,
                value: previousBackground ?? NSNull(),
                forCharacterRange: segment
            )
            layoutManager.addTemporaryAttribute(.editorFindHighlightMarker, value: true, forCharacterRange: segment)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: segment)
            location = NSMaxRange(segment)
        }
    }

    private func markedRanges(layoutManager: NSLayoutManager, textLength: Int) -> [NSRange] {
        guard textLength > 0 else { return [] }

        var ranges: [NSRange] = []
        var location = 0
        while location < textLength {
            var effectiveRange = NSRange(location: location, length: textLength - location)
            let marker = layoutManager.temporaryAttribute(
                .editorFindHighlightMarker,
                atCharacterIndex: location,
                effectiveRange: &effectiveRange
            )
            guard effectiveRange.length > 0 else { break }

            if marker != nil {
                ranges.append(effectiveRange)
            }
            location = NSMaxRange(effectiveRange)
        }
        return ranges
    }

    private func clearMarkedRange(_ range: NSRange, layoutManager: NSLayoutManager) {
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            var effectiveRange = NSRange(location: location, length: end - location)
            let previousBackground = layoutManager.temporaryAttribute(
                .editorFindPreviousBackgroundColor,
                atCharacterIndex: location,
                effectiveRange: &effectiveRange
            )
            let segment = effectiveRange.intersection(range) ?? NSRange(location: location, length: end - location)
            guard segment.length > 0 else { break }

            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: segment)
            if let color = previousBackground as? NSColor {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: segment)
            }

            layoutManager.removeTemporaryAttribute(.editorFindPreviousBackgroundColor, forCharacterRange: segment)
            layoutManager.removeTemporaryAttribute(.editorFindHighlightMarker, forCharacterRange: segment)
            location = NSMaxRange(segment)
        }
    }
}

private extension NSAttributedString.Key {
    static let editorFindHighlightMarker = NSAttributedString.Key("alas.editorFindHighlightMarker")
    static let editorFindPreviousBackgroundColor = NSAttributedString.Key("alas.editorFindPreviousBackgroundColor")
}
