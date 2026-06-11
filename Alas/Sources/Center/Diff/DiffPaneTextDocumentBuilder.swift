import AppKit
import SwiftUI

struct DiffPaneTextDocumentBuilder {
    struct LineMetadata: Equatable {
        let kind: DiffDisplayRow.Kind
        let range: NSRange
    }

    struct CodeDocument {
        let attributedString: NSAttributedString
        let lines: [LineMetadata]
    }

    struct SplitResult {
        let oldCode: CodeDocument
        let oldGutter: NSAttributedString
        let newCode: CodeDocument
        let newGutter: NSAttributedString
    }

    struct StackedResult {
        let code: CodeDocument
        let gutter: NSAttributedString
    }

    struct Result {
        let attributedString: NSAttributedString
        let lines: [LineMetadata]
    }

    static func buildSplit(
        group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> SplitResult {
        var oldColumn = ColumnAccumulator(font: font, theme: theme)
        var newColumn = ColumnAccumulator(font: font, theme: theme)
        let oldGutter = NSMutableAttributedString()
        let newGutter = NSMutableAttributedString()
        let rows = DiffPaneRowProjection.visibleRows(
            in: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs
        )

        for row in rows {
            appendGutterLine(marker(for: row.old, emptyKind: row.kind, side: .old), to: oldGutter, font: font, theme: theme, side: .old)
            appendGutterLine(marker(for: row.new, emptyKind: row.kind, side: .new), to: newGutter, font: font, theme: theme, side: .new)

            if row.kind == .collapsed {
                oldColumn.append(
                    collapsedCodeText(row, font: font, theme: theme),
                    kind: row.kind
                )
                newColumn.append(NSAttributedString(string: "", attributes: baseAttributes(font: font, theme: theme)), kind: row.kind)
                continue
            }

            oldColumn.append(
                code(
                    row.old?.text ?? "",
                    line: row.old,
                    fileExtension: fileExtension,
                    font: font,
                    showWhitespace: showWhitespace,
                    theme: theme
                ),
                kind: row.kind
            )
            newColumn.append(
                code(
                    row.new?.text ?? "",
                    line: row.new,
                    fileExtension: fileExtension,
                    font: font,
                    showWhitespace: showWhitespace,
                    theme: theme
                ),
                kind: row.kind
            )
        }

        return SplitResult(
            oldCode: oldColumn.document,
            oldGutter: oldGutter,
            newCode: newColumn.document,
            newGutter: newGutter
        )
    }

    static func buildStacked(
        group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> StackedResult {
        var codeColumn = ColumnAccumulator(font: font, theme: theme)
        let gutter = NSMutableAttributedString()
        let rows = DiffPaneRowProjection.visibleRows(
            in: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs
        )

        for row in rows {
            if row.kind == .collapsed {
                appendGutterLine("", to: gutter, font: font, theme: theme, side: .paired)
                codeColumn.append(collapsedCodeText(row, font: font, theme: theme), kind: row.kind)
                continue
            }

            for line in DiffPaneRowProjection.stackedLines(for: row) {
                appendGutterLine(marker(for: line, emptyKind: row.kind, side: line.anchor.side), to: gutter, font: font, theme: theme, side: line.anchor.side)
                codeColumn.append(
                    code(
                        line.text,
                        line: line,
                        fileExtension: fileExtension,
                        font: font,
                        showWhitespace: showWhitespace,
                        theme: theme
                    ),
                    kind: row.kind
                )
            }
        }

        return StackedResult(code: codeColumn.document, gutter: gutter)
    }

    static func build(
        group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>,
        layoutMode: DiffLayoutMode,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme,
        splitColumnCharacterWidth: Int = 48
    ) -> Result {
        let output = NSMutableAttributedString()
        var lines: [LineMetadata] = []
        let rows = DiffPaneRowProjection.visibleRows(
            in: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs
        )

        for row in rows {
            if output.length > 0 {
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: font, theme: theme)))
            }

            let start = output.length
            switch row.kind {
            case .collapsed:
                output.append(collapsedLine(row, font: font, theme: theme))
            case .context, .add, .delete, .replacement:
                switch layoutMode {
                case .split:
                    output.append(splitLine(
                        row,
                        fileExtension: fileExtension,
                        font: font,
                        showWhitespace: showWhitespace,
                        theme: theme,
                        splitColumnCharacterWidth: splitColumnCharacterWidth
                    ))
                case .stacked:
                    appendStackedLines(
                        row,
                        to: output,
                        lines: &lines,
                        fileExtension: fileExtension,
                        font: font,
                        showWhitespace: showWhitespace,
                        theme: theme
                    )
                    continue
                }
            }

            lines.append(LineMetadata(kind: row.kind, range: NSRange(location: start, length: output.length - start)))
        }

        return Result(attributedString: output, lines: lines)
    }

    private static func appendStackedLines(
        _ row: DiffDisplayRow,
        to output: NSMutableAttributedString,
        lines: inout [LineMetadata],
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) {
        for (index, line) in DiffPaneRowProjection.stackedLines(for: row).enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: font, theme: theme)))
            }
            let start = output.length
            output.append(stackedLine(
                line,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            ))
            lines.append(LineMetadata(kind: row.kind, range: NSRange(location: start, length: output.length - start)))
        }
    }

    private static func splitLine(
        _ row: DiffDisplayRow,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme,
        splitColumnCharacterWidth: Int
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let oldCode = truncatedCode(row.old?.text ?? "", width: splitColumnCharacterWidth)
        let oldPrefix = prefix(for: row.old, emptyKind: row.kind, side: .old)
        output.append(marker(oldPrefix, font: font, theme: theme, side: .old))
        output.append(code(
            oldCode,
            line: row.old,
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        ))
        output.append(NSAttributedString(string: "\t", attributes: baseAttributes(font: font, theme: theme)))

        let newCode = row.new?.text ?? ""
        let newPrefix = prefix(for: row.new, emptyKind: row.kind, side: .new)
        output.append(marker(newPrefix, font: font, theme: theme, side: .new))
        output.append(code(
            newCode,
            line: row.new,
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        ))
        output.addAttribute(.backgroundColor, value: NSColor(rowBackground(for: row.kind, theme: theme)), range: NSRange(location: 0, length: output.length))
        return output
    }

    private static func stackedLine(
        _ line: DiffDisplayLine,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        output.append(marker(prefix(for: line, emptyKind: .context, side: line.anchor.side), font: font, theme: theme, side: line.anchor.side))
        output.append(code(
            line.text,
            line: line,
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        ))
        output.addAttribute(.backgroundColor, value: NSColor(lineBackground(for: line.kind, theme: theme)), range: NSRange(location: 0, length: output.length))
        return output
    }

    private static func collapsedLine(
        _ row: DiffDisplayRow,
        font: NSFont,
        theme: Theme
    ) -> NSAttributedString {
        NSAttributedString(
            string: "      ... \(row.collapsedLineCount) unchanged lines",
            attributes: [
                .font: font,
                .foregroundColor: NSColor(theme.color("fg-dim")),
                .backgroundColor: NSColor(theme.color("bg-2")),
                .paragraphStyle: CenterTypography.paragraphStyle(),
            ]
        )
    }

    private static func collapsedCodeText(
        _ row: DiffDisplayRow,
        font: NSFont,
        theme: Theme
    ) -> NSAttributedString {
        NSAttributedString(
            string: "... \(row.collapsedLineCount) unchanged lines",
            attributes: [
                .font: font,
                .foregroundColor: NSColor(theme.color("fg-dim")),
                .backgroundColor: NSColor(theme.color("bg-2")),
                .paragraphStyle: CenterTypography.paragraphStyle(),
            ]
        )
    }

    private static func code(
        _ text: String,
        line: DiffDisplayLine?,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> NSAttributedString {
        guard let line else {
            return NSAttributedString(string: text, attributes: baseAttributes(font: font, theme: theme))
        }
        return DiffCodeText.attributedString(
            text: text,
            fileExtension: fileExtension,
            codeFontFamily: font.familyName ?? "",
            codeFontSize: font.pointSize,
            showWhitespace: showWhitespace,
            inlineSpans: line.inlineSpans,
            inlineTone: inlineTone(for: line.kind),
            theme: theme
        )
    }

    private static func appendGutterLine(
        _ text: String,
        to output: NSMutableAttributedString,
        font: NSFont,
        theme: Theme,
        side: DiffLineSide
    ) {
        if output.length > 0 {
            output.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: font, theme: theme)))
        }
        output.append(marker(text, font: font, theme: theme, side: side))
    }

    private static func marker(
        _ text: String,
        font: NSFont,
        theme: Theme,
        side: DiffLineSide
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(markerColor(for: side, theme: theme)),
                .paragraphStyle: CenterTypography.paragraphStyle(),
            ]
        )
    }

    private static func marker(
        for line: DiffDisplayLine?,
        emptyKind: DiffDisplayRow.Kind,
        side: DiffLineSide
    ) -> String {
        guard let line else {
            return ""
        }
        let number = line.lineNumber.map(String.init) ?? ""
        let sign: String
        switch line.kind {
        case .add:
            sign = "+"
        case .delete:
            sign = "-"
        case .context:
            sign = " "
        }
        return "\(sign)\(number)"
    }

    private static func prefix(
        for line: DiffDisplayLine?,
        emptyKind: DiffDisplayRow.Kind,
        side: DiffLineSide
    ) -> String {
        guard let line else {
            return "      | "
        }
        let number = line.lineNumber.map(String.init) ?? ""
        let marker: String
        switch line.kind {
        case .add:
            marker = "+"
        case .delete:
            marker = "-"
        case .context:
            marker = " "
        }
        return "\(marker)\(number.leftPadded(to: 5)) | "
    }

    private static func truncatedCode(_ text: String, width: Int) -> String {
        guard width > 3 else { return text }
        let ns = text as NSString
        guard ns.length > width else {
            return text.rightPadded(to: width)
        }
        return ns.substring(to: width - 3) + "..."
    }

    private static func baseAttributes(font: NSFont, theme: Theme) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor(theme.color("fg")),
            .paragraphStyle: CenterTypography.paragraphStyle(),
        ]
    }

    private static func inlineTone(for kind: ParsedDiff.Hunk.Line.Kind) -> DiffInlineTone {
        switch kind {
        case .add:
            return .add
        case .delete:
            return .del
        case .context:
            return .accent
        }
    }

    private static func markerColor(for side: DiffLineSide, theme: Theme) -> Color {
        switch side {
        case .old:
            return theme.color("del")
        case .new:
            return theme.color("add")
        case .paired:
            return theme.color("fg-faint")
        }
    }

    private static func rowBackground(for kind: DiffDisplayRow.Kind, theme: Theme) -> Color {
        switch kind {
        case .add:
            return theme.color("add").opacity(0.12)
        case .delete:
            return theme.color("del").opacity(0.12)
        case .replacement:
            return theme.color("mod").opacity(0.10)
        case .context:
            return theme.color("bg-1")
        case .collapsed:
            return theme.color("bg-2")
        }
    }

    private static func lineBackground(for kind: ParsedDiff.Hunk.Line.Kind, theme: Theme) -> Color {
        switch kind {
        case .add:
            return theme.color("add").opacity(0.12)
        case .delete:
            return theme.color("del").opacity(0.12)
        case .context:
            return theme.color("bg-1")
        }
    }
}

private struct ColumnAccumulator {
    private let output = NSMutableAttributedString()
    private var metadata: [DiffPaneTextDocumentBuilder.LineMetadata] = []
    private let newlineAttributes: [NSAttributedString.Key: Any]

    init(font: NSFont, theme: Theme) {
        newlineAttributes = [
            .font: font,
            .foregroundColor: NSColor(theme.color("fg")),
            .paragraphStyle: CenterTypography.paragraphStyle(),
        ]
    }

    var document: DiffPaneTextDocumentBuilder.CodeDocument {
        DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: output,
            lines: metadata
        )
    }

    mutating func append(_ line: NSAttributedString, kind: DiffDisplayRow.Kind) {
        if output.length > 0 {
            output.append(NSAttributedString(string: "\n", attributes: newlineAttributes))
        }
        let start = output.length
        output.append(line)
        metadata.append(DiffPaneTextDocumentBuilder.LineMetadata(
            kind: kind,
            range: NSRange(location: start, length: line.length)
        ))
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        let length = (self as NSString).length
        guard length < width else { return self }
        return String(repeating: " ", count: width - length) + self
    }

    func rightPadded(to width: Int) -> String {
        let length = (self as NSString).length
        guard length < width else { return self }
        return self + String(repeating: " ", count: width - length)
    }
}
