import AppKit

struct CodeEditorTextRenderingConfiguration: Equatable {
    var showInvisibleCharacters: Bool
    var showSpaces: Bool
    var showTabs: Bool
    var showLineEndings: Bool
    var showWarningCharacters: Bool
    var warningCharacters: [WarningCharacter]

    init(code: AppConfig.Code) {
        showInvisibleCharacters = code.showInvisibleCharacters
        showSpaces = code.showSpaces
        showTabs = code.showTabs
        showLineEndings = code.showLineEndings
        showWarningCharacters = code.showWarningCharacters
        warningCharacters = code.warningCharacters
    }
}

final class CodeEditorLayoutManager: NSLayoutManager {
    private var configuration: CodeEditorTextRenderingConfiguration?
    private var markerColor = NSColor.secondaryLabelColor.withAlphaComponent(0.42)

    func update(configuration: CodeEditorTextRenderingConfiguration, theme: Theme) {
        let color = NSColor(theme.color("fg-1")).withAlphaComponent(0.42)
        guard self.configuration != configuration || !markerColor.isEqual(color) else { return }
        self.configuration = configuration
        markerColor = color
        invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    @MainActor func warningToolTip(at point: NSPoint, in textView: NSTextView) -> String? {
        guard let configuration, configuration.showWarningCharacters,
              let container = textView.textContainer else { return nil }
        var fraction: CGFloat = 0
        let index = characterIndex(for: NSPoint(x: point.x - textView.textContainerInset.width, y: point.y - textView.textContainerInset.height), in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let scalars = Dictionary(uniqueKeysWithValues: configuration.warningCharacters.compactMap { warning in
            warning.scalar.map { ($0.value, warning) }
        })
        let string = textView.string as NSString
        let containerPoint = NSPoint(x: point.x - textView.textContainerInset.width, y: point.y - textView.textContainerInset.height)
        for location in [index, index - 1] where location >= 0 && location < string.length {
            let range = string.rangeOfComposedCharacterSequence(at: location)
            let value = string.substring(with: range).unicodeScalars.first?.value
            guard let value, let warning = scalars[value], decorationRect(forCharacterRange: range).contains(containerPoint) else { continue }
            return warning.note.isEmpty ? warning.code : "\(warning.code) — \(warning.note)"
        }
        return nil
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let configuration, let text = textStorage?.string else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let warnings = Dictionary(uniqueKeysWithValues: configuration.warningCharacters.compactMap { warning in
            warning.scalar.map { ($0.value, warning) }
        })
        let start = String.Index(utf16Offset: characters.location, in: text)
        let end = String.Index(utf16Offset: NSMaxRange(characters), in: text)
        for index in text.unicodeScalars.indices where index >= start && index < end {
            let scalar = text.unicodeScalars[index]
            let range = NSRange(index..<text.unicodeScalars.index(after: index), in: text)
            guard NSIntersectionRange(range, characters).length > 0 else { continue }
            let rect = decorationRect(forCharacterRange: range).offsetBy(dx: origin.x, dy: origin.y)
            if configuration.showWarningCharacters, let warning = warnings[scalar.value] {
                NSColor.systemRed.withAlphaComponent(0.28).setFill()
                rect.insetBy(dx: 1, dy: 1).fill()
                _ = warning
            } else if configuration.showInvisibleCharacters {
                let marker: String?
                switch scalar.value { case 0x20 where configuration.showSpaces: marker = "·"
                case 0x09 where configuration.showTabs: marker = "→"
                case 0x0A where configuration.showLineEndings: marker = "↵"
                default: marker = nil }
                if let marker { marker.draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: [.font: textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: markerColor]) }
            }
        }
    }

    private func decorationRect(forCharacterRange range: NSRange) -> NSRect {
        guard let container = textContainers.first else { return .zero }
        let glyph = glyphIndexForCharacter(at: range.location)
        var rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        if rect.width <= 1 {
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect = NSRect(x: location(forGlyphAt: glyph).x, y: line.minY, width: 8, height: line.height)
        }
        return rect
    }
}
