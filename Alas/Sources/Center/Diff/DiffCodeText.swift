import AppKit
import SwiftUI

enum DiffInlineTone {
    case add
    case del
    case accent
}

struct DiffCodeText: View {
    let text: String
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let wrapLines: Bool
    let showWhitespace: Bool
    let inlineSpans: [DiffInlineSpan]
    let inlineTone: DiffInlineTone

    @Environment(\.theme) private var theme

    var body: some View {
        Text(attributedText)
            .lineSpacing(CenterTypography.textLineSpacing(forFontSize: codeFontSize))
            .lineLimit(wrapLines ? nil : 1)
            .fixedSize(horizontal: !wrapLines, vertical: true)
            .textSelection(.enabled)
    }

    private var attributedText: AttributedString {
        AttributedString(attributedString())
    }

    private func attributedString() -> NSAttributedString {
        let visibleText = Self.visibleWhitespaceText(text, enabled: showWhitespace)
        let output = NSMutableAttributedString(
            string: visibleText,
            attributes: baseAttributes
        )
        let visibleLength = (visibleText as NSString).length
        let originalLength = (text as NSString).length
        let canApplyOriginalOffsets = visibleLength == originalLength

        if canApplyOriginalOffsets {
            applySyntaxSpans(to: output, visibleLength: visibleLength)
            applyInlineSpans(to: output, visibleLength: visibleLength)
        }

        return output
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            .foregroundColor: NSColor(theme.color("fg")),
            .paragraphStyle: CenterTypography.paragraphStyle(),
        ]
    }

    private func applySyntaxSpans(to output: NSMutableAttributedString, visibleLength: Int) {
        let spans = TreeSitterHighlighter.tokenize(line: text, fileExtension: fileExtension)
            .filter { isValid($0.range, in: visibleLength) }
            .sorted { $0.range.location < $1.range.location }

        var cursor = 0
        for span in spans {
            guard span.range.location >= cursor else { continue }
            output.addAttribute(
                .foregroundColor,
                value: NSColor(syntaxColor(for: span.capture)),
                range: span.range
            )
            cursor = NSMaxRange(span.range)
        }
    }

    private func applyInlineSpans(to output: NSMutableAttributedString, visibleLength: Int) {
        for span in inlineSpans {
            let range = NSRange(location: span.start, length: span.length)
            guard isValid(range, in: visibleLength) else { continue }
            output.addAttribute(
                .backgroundColor,
                value: NSColor(inlineColor.opacity(0.24)),
                range: range
            )
        }
    }

    private func isValid(_ range: NSRange, in length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length
    }

    private var inlineColor: Color {
        switch inlineTone {
        case .add:
            return theme.color("add")
        case .del:
            return theme.color("del")
        case .accent:
            return theme.color("accent")
        }
    }

    private func syntaxColor(for capture: HighlightCapture) -> Color {
        switch capture {
        case .keyword:
            return theme.color("syntax-keyword")
        case .type:
            return theme.color("syntax-type")
        case .function:
            return theme.color("syntax-function")
        case .string:
            return theme.color("add")
        case .number:
            return theme.color("mod")
        case .comment:
            return theme.color("fg-faint")
        case .attribute, .constant:
            return theme.color("syntax-keyword")
        case .variable, .parameter, .property, .operator, .punctuation, .plain:
            return theme.color("fg")
        }
    }

    private static func visibleWhitespaceText(_ text: String, enabled: Bool) -> String {
        guard enabled else { return text }
        return text
            .replacingOccurrences(of: " ", with: "·")
            .replacingOccurrences(of: "\t", with: "→   ")
    }
}
