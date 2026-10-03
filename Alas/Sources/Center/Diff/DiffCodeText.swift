import AppKit
import SwiftUI

enum DiffInlineTone {
    case add
    case del
    case accent
}

enum DiffCodeText {
    static func attributedString(
        text: String,
        fileExtension: String,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        showWhitespace: Bool,
        inlineSpans: [DiffInlineSpan],
        inlineTone: DiffInlineTone,
        theme: Theme,
        highlightSyntax: Bool = true
    ) -> NSAttributedString {
        let visibleText = visibleWhitespaceText(text, enabled: showWhitespace)
        let output = NSMutableAttributedString(
            string: visibleText,
            attributes: baseAttributes(codeFontFamily: codeFontFamily, codeFontSize: codeFontSize, theme: theme)
        )
        let visibleLength = (visibleText as NSString).length

        if highlightSyntax {
            applySyntaxSpans(
                to: output,
                spans: TreeSitterHighlighter.tokenize(line: text, fileExtension: fileExtension),
                offset: 0,
                inlineTone: inlineTone,
                theme: theme,
                visibleLength: visibleLength
            )
        }
        applyInlineSpans(
            to: output,
            inlineSpans: inlineSpans,
            inlineTone: inlineTone,
            theme: theme,
            visibleLength: visibleLength
        )

        return output
    }

    private static func baseAttributes(
        codeFontFamily: String,
        codeFontSize: CGFloat,
        theme: Theme
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            .foregroundColor: theme.nsColor("fg"),
            .paragraphStyle: CenterTypography.paragraphStyle(),
        ]
    }

    static func applySyntaxSpans(
        to output: NSMutableAttributedString,
        spans: [HighlightSpan],
        offset: Int,
        inlineTone: DiffInlineTone,
        theme: Theme,
        visibleLength: Int
    ) {
        let spans = spans
            .filter { isValid($0.range, in: visibleLength) }
            .sorted { $0.range.location < $1.range.location }

        let editorTheme = EditorTheme(theme: theme)
        let onChangedLine = inlineTone == .add || inlineTone == .del
        var cursor = 0
        for span in spans {
            guard span.range.location >= cursor else { continue }
            let outputRange = NSRange(location: offset + span.range.location, length: span.range.length)
            guard isValid(outputRange, in: output.length) else { continue }
            output.addAttribute(
                .foregroundColor,
                value: editorTheme.color(for: span.capture, onChangedLine: onChangedLine),
                range: outputRange
            )
            cursor = NSMaxRange(span.range)
        }
    }

    private static func applyInlineSpans(
        to output: NSMutableAttributedString,
        inlineSpans: [DiffInlineSpan],
        inlineTone: DiffInlineTone,
        theme: Theme,
        visibleLength: Int
    ) {
        for span in inlineSpans {
            let range = NSRange(location: span.start, length: span.length)
            guard isValid(range, in: visibleLength) else { continue }
            output.addAttribute(
                .backgroundColor,
                value: NSColor.drawingColor(inlineColor(for: inlineTone, theme: theme).opacity(0.24)),
                range: range
            )
        }
    }

    private static func isValid(_ range: NSRange, in length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length
    }

    private static func inlineColor(for tone: DiffInlineTone, theme: Theme) -> Color {
        switch tone {
        case .add:
            return theme.color("add")
        case .del:
            return theme.color("del")
        case .accent:
            return theme.color("accent")
        }
    }

    private static func visibleWhitespaceText(_ text: String, enabled: Bool) -> String {
        guard enabled else { return text }
        return text
            .replacingOccurrences(of: " ", with: "·")
            .replacingOccurrences(of: "\t", with: "→")
    }
}
