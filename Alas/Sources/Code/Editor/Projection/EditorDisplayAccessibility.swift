import AppKit

/// Accessibility has a source contract independent of NSTextInputClient's
/// native display coordinates. Hint descriptions are separate read-only children.
extension CodeTextView {
    // NSTextView implements the legacy entry points directly. Forwarding only
    // the modern methods leaves external AX parameterized queries native.
    // Implements deprecated AppKit AX entry points; the attribute keeps the
    // deprecation so calls to `super` inside do not warn.
    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        // `Any?` is not Sendable, so it cannot be returned out of the main-actor
        // closure; assign through a local instead. The body stays in this
        // override so it keeps the deprecation context of the entry point.
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated {
            result = switch attribute {
            case .value: accessibilityValue()
            case .numberOfCharacters: accessibilityNumberOfCharacters()
            case .selectedText: accessibilitySelectedText()
            case .selectedTextRange: NSValue(range: accessibilitySelectedTextRange())
            case .selectedTextRanges: accessibilitySelectedTextRanges()
            case .visibleCharacterRange: NSValue(range: accessibilityVisibleCharacterRange())
            case .insertionPointLineNumber: accessibilityInsertionPointLineNumber()
            case .sharedCharacterRange: NSValue(range: NSRange(location: 0, length: sourceAttributedText.length))
            case .children:
                // NSTextView's modern fallback calls this legacy entry point.
                // Forward an unbound view directly to the native implementation.
                displayAdapter == nil ? super.accessibilityAttributeValue(attribute) : accessibilityChildren()
            default: super.accessibilityAttributeValue(attribute)
            }
        }
        return result
    }

    // Implements deprecated AppKit AX entry points; the attribute keeps the
    // deprecation so calls to `super` inside do not warn.
    @available(macOS, deprecated: 10.10)
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        nonisolated(unsafe) let value = value
        MainActor.assumeIsolated {
            switch attribute {
            case .value: setAccessibilityValue(value)
            case .selectedText: setAccessibilitySelectedText(value as? String)
            case .selectedTextRange:
                if let range = value as? NSValue { setAccessibilitySelectedTextRange(range.rangeValue) }
            case .selectedTextRanges: setAccessibilitySelectedTextRanges(value as? [NSValue])
            default: super.accessibilitySetValue(value, forAttribute: attribute)
            }
        }
    }

    // Implements deprecated AppKit AX entry points; the attribute keeps the
    // deprecation so calls to `super` inside do not warn.
    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.ParameterizedAttribute, forParameter parameter: Any?) -> Any? {
        nonisolated(unsafe) var result: Any?
        nonisolated(unsafe) let parameter = parameter
        MainActor.assumeIsolated {
            result = { () -> Any? in
            switch attribute {
            case .stringForRange, .attributedStringForRange, .rtfForRange, .boundsForRange:
                guard let range = (parameter as? NSValue)?.rangeValue, nativeRange(forSource: range) != nil else { return nil }
                switch attribute {
                case .stringForRange: return accessibilityString(for: range)
                case .attributedStringForRange: return accessibilityAttributedString(for: range)
                case .rtfForRange: return accessibilityRTF(for: range)
                default: return NSValue(rect: accessibilityFrame(for: range))
                }
            case .rangeForLine:
                guard let line = parameter as? Int else { return nil }
                return NSValue(range: accessibilityRange(forLine: line))
            case .lineForIndex:
                guard let index = parameter as? Int else { return nil }
                return accessibilityLine(for: index)
            case .rangeForIndex:
                guard let index = parameter as? Int else { return nil }
                return NSValue(range: accessibilityRange(for: index))
            case .styleRangeForIndex:
                guard let index = parameter as? Int else { return nil }
                return NSValue(range: accessibilityStyleRange(for: index))
            case .rangeForPosition:
                guard let point = (parameter as? NSValue)?.pointValue else { return nil }
                return NSValue(range: accessibilityRange(for: point))
            default: return super.accessibilityAttributeValue(attribute, forParameter: parameter)
            }
            }()
        }
        return result
    }

    override func accessibilityValue() -> String? { sourceString }
    override func setAccessibilityValue(_ value: Any?) {
        guard let value = value as? String else { return }
        _ = replaceSource(range: NSRange(location: 0, length: sourceAttributedText.length), with: value)
    }

    override func accessibilityNumberOfCharacters() -> Int { sourceAttributedText.length }
    override func accessibilitySelectedTextRange() -> NSRange { sourceSelectedRange }
    override func accessibilitySelectedTextRanges() -> [NSValue]? { sourceSelectedRanges }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard nativeRange(forSource: range) != nil else { return }
        setSourceSelectedRange(range)
    }
    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        guard let ranges, !ranges.isEmpty, ranges.allSatisfy({ nativeRange(forSource: $0.rangeValue) != nil }) else { return }
        setSourceSelectedRanges(ranges)
    }
    override func accessibilitySelectedText() -> String? { accessibilityString(for: sourceSelectedRange) }
    override func setAccessibilitySelectedText(_ text: String?) {
        guard let text else { return }
        _ = replaceSource(range: sourceSelectedRange, with: text)
    }
    override func accessibilityString(for range: NSRange) -> String? {
        guard nativeRange(forSource: range) != nil else { return nil }
        return (sourceString as NSString).substring(with: range)
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard nativeRange(forSource: range) != nil else { return nil }
        return sourceAttributedText.attributedSubstring(from: range)
    }
    override func accessibilityRTF(for range: NSRange) -> Data? {
        guard let text = accessibilityAttributedString(for: range) else { return nil }
        return try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    override func accessibilityStyleRange(for index: Int) -> NSRange {
        guard index >= 0, index < sourceAttributedText.length else { return NSRange(location: NSNotFound, length: 0) }
        var range = NSRange()
        _ = sourceAttributedText.attributes(at: index, effectiveRange: &range)
        return range
    }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        visibleSourceRange ?? NSRange(location: NSNotFound, length: 0)
    }
    override func accessibilityInsertionPointLineNumber() -> Int { accessibilityLine(for: sourceSelectedRange.location) }
    override func accessibilityLine(for index: Int) -> Int {
        TextEditCoordinates.lspPosition(utf16Offset: index, in: sourceString)?.line ?? NSNotFound
    }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard let offset = try? LSPPositionCodec.offset(.init(line: line, character: 0), in: sourceString) else { return NSRange(location: NSNotFound, length: 0) }
        return (sourceString as NSString).lineRange(for: NSRange(location: offset, length: 0))
    }
    override func accessibilityRange(for index: Int) -> NSRange {
        guard nativeRange(forSource: NSRange(location: index, length: 0)) != nil else { return NSRange(location: NSNotFound, length: 0) }
        if index == sourceAttributedText.length { return NSRange(location: index, length: 0) }
        return (sourceString as NSString).rangeOfComposedCharacterSequence(at: index)
    }
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard let offset = utf16Offset(at: local) else { return NSRange(location: NSNotFound, length: 0) }
        return accessibilityRange(for: offset)
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window else { return .zero }
        let rects = sourceRects(inViewFor: range)
        guard let first = rects.first else { return .zero }
        return window.convertToScreen(convert(rects.dropFirst().reduce(first) { $0.union($1) }, to: nil))
    }
    override func accessibilityChildren() -> [Any]? {
        guard let adapter = displayAdapter else { return super.accessibilityChildren() }
        let revision = adapter.document.map.revision
        return adapter.document.map.hintRuns.map { run in
            let child = NSAccessibilityElement()
            child.setAccessibilityRole(.staticText)
            child.setAccessibilityLabel(run.hint.label)
            child.setAccessibilityParent(self)
            child.setAccessibilityCustomActions((inlayAccessibilityActions?(run.hint.id) ?? []) + [NSAccessibilityCustomAction(name: "Move to source position") { [weak self, weak adapter] in
                guard let self, let adapter, let current = self.displayAdapter, current === adapter,
                      current.document.map.revision == revision,
                      current.document.map.hintRuns.contains(where: { $0.hint.id == run.hint.id && $0.hint.sourceOffset == run.hint.sourceOffset }) else { return false }
                self.setSourceSelectedRange(NSRange(location: run.hint.sourceOffset, length: 0))
                self.scrollSourceRangeToVisible(NSRange(location: run.hint.sourceOffset, length: 0))
                return true
            }])
            if let window, let layoutManager, let textContainer {
                let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: run.displayOffset, length: 1), actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                child.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            }
            return child
        }
    }
}
