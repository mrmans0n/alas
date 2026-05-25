import AppKit
import SwiftUI

struct DiffSelectableTextBuilder {
    struct LineMetadata: Equatable {
        let kind: ParsedDiff.Hunk.Line.Kind
        let marker: String
        let range: NSRange
    }

    struct Result {
        let attributedString: NSAttributedString
        let lines: [LineMetadata]
    }

    static func plainString(for hunk: ParsedDiff.Hunk) -> String {
        hunk.lines.map(\.text).joined(separator: "\n")
    }

    static func build(
        hunk: ParsedDiff.Hunk,
        fileExtension: String,
        font: NSFont,
        theme: Theme
    ) -> Result {
        let output = NSMutableAttributedString()
        var metadata: [LineMetadata] = []
        var location = 0

        for (index, line) in hunk.lines.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: font, theme: theme)))
                location += 1
            }

            let lineStart = location
            let attributedLine = attributedLine(
                line.text,
                fileExtension: fileExtension,
                font: font,
                theme: theme
            )
            output.append(attributedLine)
            let lineLength = (line.text as NSString).length
            metadata.append(LineMetadata(
                kind: line.kind,
                marker: marker(for: line),
                range: NSRange(location: lineStart, length: lineLength)
            ))
            location += lineLength
        }

        return Result(attributedString: output, lines: metadata)
    }

    private static func attributedLine(
        _ line: String,
        fileExtension: String,
        font: NSFont,
        theme: Theme
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ns = line as NSString
        let total = ns.length
        guard total > 0 else {
            return NSAttributedString(string: "", attributes: baseAttributes(font: font, theme: theme))
        }

        let spans = TreeSitterHighlighter.tokenize(line: line, fileExtension: fileExtension)
            .filter { $0.range.location >= 0 && NSMaxRange($0.range) <= total }
            .sorted { $0.range.location < $1.range.location }

        var cursor = 0
        for span in spans {
            if span.range.location < cursor { continue }
            if span.range.location > cursor {
                let plainRange = NSRange(location: cursor, length: span.range.location - cursor)
                result.append(NSAttributedString(
                    string: ns.substring(with: plainRange),
                    attributes: baseAttributes(font: font, theme: theme)
                ))
            }
            result.append(NSAttributedString(
                string: ns.substring(with: span.range),
                attributes: attributes(for: span.capture, font: font, theme: theme)
            ))
            cursor = NSMaxRange(span.range)
        }

        if cursor < total {
            let tail = NSRange(location: cursor, length: total - cursor)
            result.append(NSAttributedString(
                string: ns.substring(with: tail),
                attributes: baseAttributes(font: font, theme: theme)
            ))
        }

        if result.length == 0 {
            result.append(NSAttributedString(string: line, attributes: baseAttributes(font: font, theme: theme)))
        }
        return result
    }

    private static func marker(for line: ParsedDiff.Hunk.Line) -> String {
        switch line.kind {
        case .add:
            return "+\(line.newNumber.map(String.init) ?? "")"
        case .delete:
            return "−\(line.oldNumber.map(String.init) ?? "")"
        case .context:
            return " \(line.oldNumber.map(String.init) ?? "")"
        }
    }

    private static func baseAttributes(font: NSFont, theme: Theme) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor(theme.color("fg")),
            .paragraphStyle: CenterTypography.paragraphStyle(),
        ]
    }

    private static func attributes(
        for capture: HighlightCapture,
        font: NSFont,
        theme: Theme
    ) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes(font: font, theme: theme)
        attributes[.foregroundColor] = NSColor(color(for: capture, theme: theme))
        return attributes
    }

    private static func color(for capture: HighlightCapture, theme: Theme) -> Color {
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
        default:
            return theme.color("fg")
        }
    }
}
