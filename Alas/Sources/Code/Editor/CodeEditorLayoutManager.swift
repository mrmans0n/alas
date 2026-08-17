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
            let composedRange = string.rangeOfComposedCharacterSequence(at: location)
            for (value, range) in Self.warningCharacterRanges(in: string, composedRange: composedRange, warningScalars: Set(scalars.keys)) {
                guard let warning = scalars[value], let scalar = Unicode.Scalar(value), decorationRect(forCharacterRange: range, scalar: scalar).contains(containerPoint) else { continue }
                return warning.note.isEmpty ? warning.code : "\(warning.code) — \(warning.note)"
            }
        }
        return nil
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let configuration, let text = textStorage?.string else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let warnings = Dictionary(uniqueKeysWithValues: configuration.warningCharacters.compactMap { warning in
            warning.scalar.map { ($0.value, warning) }
        })
        let start = String.Index(utf16Offset: characters.location, in: text)
        let end = String.Index(utf16Offset: NSMaxRange(characters), in: text)
        if configuration.showWarningCharacters {
            var index = start
            while index < end {
                let scalar = text.unicodeScalars[index]
                let next = text.unicodeScalars.index(after: index)
                let range = NSRange(index..<next, in: text)
                if NSIntersectionRange(range, characters).length > 0, warnings[scalar.value] != nil {
                    let rect = decorationRect(forCharacterRange: range, scalar: scalar).offsetBy(dx: origin.x, dy: origin.y)
                    NSColor.systemRed.withAlphaComponent(0.28).setFill()
                    rect.insetBy(dx: 1, dy: 1).fill()
                }
                index = next
            }
        }

        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)

        guard configuration.showInvisibleCharacters else { return }
        var index = start
        while index < end {
            let scalar = text.unicodeScalars[index]
            let next = text.unicodeScalars.index(after: index)
            let range = NSRange(index..<next, in: text)
            if NSIntersectionRange(range, characters).length > 0,
               !(configuration.showWarningCharacters && warnings[scalar.value] != nil)
            {
                let rect = decorationRect(forCharacterRange: range).offsetBy(dx: origin.x, dy: origin.y)
                    let marker: String?
                    switch scalar.value { case 0x20 where configuration.showSpaces: marker = "·"
                    case 0x09 where configuration.showTabs: marker = "→"
                    case 0x0A where configuration.showLineEndings: marker = "↵"
                    default: marker = nil }
                    if let marker { marker.draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: [.font: textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: markerColor]) }
            }
            index = next
        }
    }

    static func warningCharacterRanges(in text: NSString, composedRange: NSRange, warningScalars: Set<UInt32>) -> [(UInt32, NSRange)] {
        let substring = text.substring(with: composedRange)
        return substring.unicodeScalars.indices.compactMap { index in
            let scalar = substring.unicodeScalars[index]
            guard warningScalars.contains(scalar.value) else { return nil }
            let next = substring.unicodeScalars.index(after: index)
            let range = NSRange(index..<next, in: substring)
            return (scalar.value, NSRange(location: composedRange.location + range.location, length: range.length))
        }
    }

    static func usesInsertionMarker(for scalar: Unicode.Scalar) -> Bool {
        if [0x0009, 0x000A, 0x000D].contains(scalar.value) { return false }
        return switch scalar.properties.generalCategory {
        case .control, .enclosingMark, .format, .nonspacingMark: true
        default: false
        }
    }

    static func usesScalarMarker(for scalar: Unicode.Scalar?, range: NSRange, glyphCharacterRange: NSRange) -> Bool {
        scalar.map(Self.usesInsertionMarker) == true
            || glyphCharacterRange.location != range.location
            || glyphCharacterRange.length != range.length
    }

    private func decorationRect(forCharacterRange range: NSRange, scalar: Unicode.Scalar? = nil) -> NSRect {
        guard let container = textContainers.first else { return .zero }
        let glyph = glyphIndexForCharacter(at: range.location)
        var rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let glyphCharacters = characterRange(forGlyphRange: NSRange(location: glyph, length: 1), actualGlyphRange: nil)
        let usesScalarMarker = Self.usesScalarMarker(for: scalar, range: range, glyphCharacterRange: glyphCharacters)
        if usesScalarMarker || rect.width <= 1 {
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x: CGFloat
            if scalar.map(Self.usesInsertionMarker) == true {
                let nextGlyph = NSMaxRange(range) < (textStorage?.length ?? 0)
                    ? glyphIndexForCharacter(at: NSMaxRange(range))
                    : numberOfGlyphs
                x = nextGlyph < numberOfGlyphs ? location(forGlyphAt: nextGlyph).x : rect.maxX
            } else if usesScalarMarker {
                let offset = CGFloat(range.location - glyphCharacters.location)
                x = rect.minX + rect.width * offset / CGFloat(max(glyphCharacters.length, 1))
            } else {
                x = location(forGlyphAt: glyph).x
            }
            rect = NSRect(x: x, y: line.minY, width: 8, height: line.height)
        }
        return rect
    }
}
