import AppKit

extension Notification.Name {
    static let editorDisplayProjectionDidChange = Notification.Name("alas.editorDisplayProjectionDidChange")
    static let editorSourceDidChange = Notification.Name("alas.editorSourceDidChange")
}

extension CodeTextView {
    func displayHint(atViewPoint point: NSPoint) -> EditorDisplayHint? {
        guard let adapter = displayAdapter, adapter.document.map.revision == adapter.buffer.editGeneration,
              let layoutManager, let textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return adapter.document.map.hintRuns.first(where: { $0.displayOffset == index })?.hint
    }

    var sourceAttributedText: NSAttributedString { displayAdapter?.buffer.storage ?? textStorage ?? NSAttributedString() }
    var sourceLineStarts: [Int] { displayAdapter?.sourceLineStarts ?? EditorDisplayAdapter.lineStarts(in: sourceString) }

    func sourceLineIndex(containing offset: Int) -> Int {
        let starts = sourceLineStarts
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    /// The first display fragment owns a source line, including leading hints.
    func sourceLineY(_ line: Int) -> CGFloat? {
        let starts = sourceLineStarts
        guard starts.indices.contains(line), let layoutManager, let textContainer else { return nil }
        let offset: Int
        if let adapter = displayAdapter {
            guard let mapped = try? adapter.document.map.displayOffset(forSource: starts[line], affinity: .beforeHints) else { return nil }
            offset = mapped
        } else { offset = starts[line] }
        if offset == (textStorage?.length ?? 0) { return localInsertionRect(at: offset)?.minY }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: offset, length: 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        _ = textContainer
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
    }

    func sourceLinePosition(atViewY y: CGFloat) -> Double {
        guard let layoutManager, let textContainer, (textStorage?.length ?? 0) > 0 else { return 0 }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(0, y - textContainerOrigin.y)), in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              let offset = sourceRange(forNative: NSRange(location: layoutManager.characterIndexForGlyph(at: glyph), length: 0))?.location else { return 0 }
        let line = sourceLineIndex(containing: offset)
        let top = sourceLineY(line) ?? 0
        let bottom = sourceLineY(line + 1) ?? max(top + 1, frame.height)
        return Double(line) + Double(min(1, max(0, (y - top) / max(1, bottom - top))))
    }

    func setSourceSelectedRange(_ range: NSRange) {
        setSourceSelectedRanges([NSValue(range: range)])
    }

    func displaySegments(forSource range: NSRange) -> [NSRange] {
        if let adapter = displayAdapter {
            guard adapter.document.map.revision == adapter.buffer.editGeneration else { return [] }
            return (try? adapter.document.map.displaySegments(forSource: range)) ?? []
        }
        let length = sourceAttributedText.length
        guard range.location >= 0, range.location <= length, range.length >= 0,
              range.length <= length - range.location else { return [] }
        return range.length == 0 ? [] : [range]
    }

    func nativeRange(forSource range: NSRange) -> NSRange? {
        if let adapter = displayAdapter { return adapter.displayRange(forSource: range) }
        guard range.location >= 0, range.location <= sourceAttributedText.length, range.length >= 0,
              range.length <= sourceAttributedText.length - range.location else { return nil }
        return range
    }

    func sourceRange(forNative range: NSRange) -> NSRange? {
        if let adapter = displayAdapter { return adapter.sourceRange(forDisplay: range) }
        return nativeRange(forSource: range)
    }

    func scrollSourceRangeToVisible(_ range: NSRange) {
        guard let native = nativeRange(forSource: range) else { return }
        scrollRangeToVisible(native)
    }

    var visibleSourceRange: NSRange? {
        guard let layoutManager, let textContainer else { return nil }
        let rect = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return sourceRange(forNative: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
    }

    /// Source rectangles in view coordinates. Attachments are excluded by run
    /// identity, including when the source itself contains U+FFFC.
    func sourceRects(inViewFor range: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        if range.length == 0 { return sourceInsertionRect(inViewAt: range.location).map { [$0] } ?? [] }
        var result: [NSRect] = []
        for segment in displaySegments(forSource: range) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: segment, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                result.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
            }
        }
        return result
    }

    func sourceInsertionRect(inViewAt offset: Int) -> NSRect? {
        guard let range = nativeRange(forSource: NSRange(location: offset, length: 0)) else { return nil }
        // AppKit's candidate rectangle keeps native display coordinates and
        // supplies the bidi-aware insertion edge, including EOF attachments.
        if let window {
            let screen = firstRect(forCharacterRange: range, actualRange: nil)
            if !screen.isEmpty { return convert(window.convertFromScreen(screen), from: nil) }
        }
        return localInsertionRect(at: range.location)
    }

    func addSourceTemporaryAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        for segment in displaySegments(forSource: range) {
            layoutManager?.addTemporaryAttributes(attributes, forCharacterRange: segment)
        }
    }

    func removeSourceTemporaryAttribute(_ key: NSAttributedString.Key, range: NSRange) {
        for segment in displaySegments(forSource: range) {
            layoutManager?.removeTemporaryAttribute(key, forCharacterRange: segment)
        }
    }
}
