import AppKit

@MainActor
final class EditorFindHighlightRenderer {
    private weak var textView: CodeTextView?
    private var projectionObserver: NSObjectProtocol?
    private var projectionWillChangeObserver: NSObjectProtocol?
    private var paintedRanges: [NSRange] = []
    private var rendered: (matches: [NSRange], active: Int?, inactiveColor: NSColor, activeColor: NSColor, revision: Int?)?

    isolated deinit {
        if let projectionObserver { NotificationCenter.default.removeObserver(projectionObserver) }
        if let projectionWillChangeObserver { NotificationCenter.default.removeObserver(projectionWillChangeObserver) }
    }

    func attach(textView: CodeTextView) {
        if self.textView !== textView {
            clear()
            if let projectionObserver { NotificationCenter.default.removeObserver(projectionObserver) }
            if let projectionWillChangeObserver { NotificationCenter.default.removeObserver(projectionWillChangeObserver) }
            self.textView = textView
            projectionWillChangeObserver = NotificationCenter.default.addObserver(forName: .editorDisplayProjectionWillChange, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearPaint() }
            }
            projectionObserver = NotificationCenter.default.addObserver(forName: .editorDisplayProjectionDidChange, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let rendered = self.rendered else { return }
                    guard rendered.revision == self.textView?.displayAdapter?.buffer.editGeneration else { self.clear()
                    return }
                    self.render(matches: rendered.matches, activeIndex: rendered.active, inactiveColor: rendered.inactiveColor, activeColor: rendered.activeColor)
                }
            }
        }
    }

    func clear() {
        rendered = nil
        clearPaint()
    }

    private func clearPaint() {
        defer { paintedRanges = [] }
        guard let textView,
              let layoutManager = textView.layoutManager else {
            return
        }

        let textLength = (textView.string as NSString).length
        let ranges = textView.displayAdapter == nil ? markedRanges(layoutManager: layoutManager, textLength: textLength) : paintedRanges
        // Merge overlaps so restoring a saved background never clears it again.
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            guard let clipped = range.intersection(NSRange(location: 0, length: textLength)), clipped.length > 0 else { continue }
            if let last = merged.last, NSMaxRange(last) >= clipped.location {
                merged[merged.count - 1] = last.union(clipped)
            } else { merged.append(clipped) }
        }
        for range in merged.reversed() {
            clearMarkedRange(range, layoutManager: layoutManager)
        }
    }

    func render(matches: [NSRange], activeIndex: Int?, inactiveColor: NSColor, activeColor: NSColor) {
        clear()

        rendered = (matches, activeIndex, inactiveColor, activeColor, textView?.displayAdapter?.buffer.editGeneration)

        guard let textView,
              let layoutManager = textView.layoutManager,
              !matches.isEmpty else { return }

        let textLength = textView.sourceAttributedText.length
        for (index, range) in matches.enumerated() {
            guard isRenderable(range: range, textLength: textLength) else { continue }

            let color = index == activeIndex ? activeColor : inactiveColor
            for segment in textView.displaySegments(forSource: range) {
                addFindBackground(color, for: segment, layoutManager: layoutManager)
                paintedRanges.append(segment)
            }
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
