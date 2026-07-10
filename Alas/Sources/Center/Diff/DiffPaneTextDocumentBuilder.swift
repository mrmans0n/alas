import AppKit
import SwiftUI

struct DiffPaneTextDocumentBuilder {
    struct LineMetadata: Equatable {
        let kind: DiffDisplayRow.Kind
        let range: NSRange
        var tone: DiffPaneLineTone? = nil
        var sourceLine: DiffDisplayLine? = nil
        var sourceRange: NSRange? = nil
        var syntaxGroup: Int? = nil
        var expansionKey: DiffContextExpansionKey? = nil
        var expansionBoundary: DiffContextBoundary? = nil
    }

    struct CodeDocument {
        let attributedString: NSAttributedString
        let lines: [LineMetadata]
        let syntaxSource: String?

        init(attributedString: NSAttributedString, lines: [LineMetadata], syntaxSource: String? = nil) {
            self.attributedString = attributedString
            self.lines = lines
            self.syntaxSource = syntaxSource
        }
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
        buildSplit(
            rows: DiffPaneRowProjection.visibleRows(in: group, expandedCollapsedRowIDs: expandedCollapsedRowIDs),
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        )
    }

    static func buildSplit(
        rows: [DiffDisplayRow],
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> SplitResult {
        var oldColumn = ColumnAccumulator(font: font, theme: theme)
        var newColumn = ColumnAccumulator(font: font, theme: theme)
        var oldGutter = GutterAccumulator(font: font, theme: theme)
        var newGutter = GutterAccumulator(font: font, theme: theme)

        for row in rows {
            if row.kind == .expandableContext {
                oldGutter.append("+", side: .paired)
                newGutter.append("", side: .paired)
                oldColumn.append(
                    expandableContextText(row, font: font, theme: theme),
                    kind: row.kind,
                    tone: .collapsed,
                    sourceLine: nil,
                    expansion: row.contextExpansion
                )
                newColumn.append(
                    emptyLayoutGlyph(font: font, theme: theme),
                    kind: row.kind,
                    tone: .collapsed,
                    sourceLine: nil,
                    expansion: row.contextExpansion
                )
                continue
            }

            oldGutter.append(marker(for: row.old, emptyKind: row.kind, side: .old), side: .old)
            newGutter.append(marker(for: row.new, emptyKind: row.kind, side: .new), side: .new)

            if row.kind == .collapsed {
                oldColumn.append(
                    collapsedCodeText(row, font: font, theme: theme),
                    kind: row.kind,
                    tone: .collapsed,
                    sourceLine: nil,
                    expansion: row.contextExpansion
                )
                newColumn.append(
                    emptyLayoutGlyph(font: font, theme: theme),
                    kind: row.kind,
                    tone: .collapsed,
                    sourceLine: nil,
                    expansion: row.contextExpansion
                )
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
                kind: row.kind,
                tone: tone(for: row.old, rowKind: row.kind),
                sourceLine: reviewSourceLine(row.old, side: .old),
                expansion: row.contextExpansion
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
                kind: row.kind,
                tone: tone(for: row.new, rowKind: row.kind),
                sourceLine: reviewSourceLine(row.new, side: .new),
                expansion: row.contextExpansion
            )
        }

        return SplitResult(
            oldCode: highlightedCodeDocument(
                oldColumn.document,
                fileExtension: fileExtension,
                theme: theme
            ),
            oldGutter: oldGutter.attributedString,
            newCode: highlightedCodeDocument(
                newColumn.document,
                fileExtension: fileExtension,
                theme: theme
            ),
            newGutter: newGutter.attributedString
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
        buildStacked(
            rows: DiffPaneRowProjection.visibleRows(in: group, expandedCollapsedRowIDs: expandedCollapsedRowIDs),
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        )
    }

    static func buildStacked(
        rows: [DiffDisplayRow],
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> StackedResult {
        var codeColumn = ColumnAccumulator(font: font, theme: theme)
        var gutter = GutterAccumulator(font: font, theme: theme)

        var index = 0
        while index < rows.count {
            let row = rows[index]
            if row.kind == .expandableContext {
                gutter.append("+", side: .paired)
                codeColumn.append(
                    expandableContextText(row, font: font, theme: theme),
                    kind: row.kind,
                    tone: .collapsed,
                    sourceLine: nil,
                    expansion: row.contextExpansion
                )
                index += 1
                continue
            }

            if row.kind == .collapsed {
                gutter.append("", side: .paired)
                codeColumn.append(
                    collapsedCodeText(row, font: font, theme: theme),
                    kind: row.kind,
                    tone: .collapsed,
                    sourceLine: nil,
                    expansion: row.contextExpansion
                )
                index += 1
                continue
            }

            let rowStart = index
            while index < rows.count, rows[index].kind != .collapsed, rows[index].kind != .expandableContext {
                index += 1
            }
            let lines = DiffPaneRowProjection.stackedLines(for: Array(rows[rowStart..<index]))
            for (row, line) in lines {
                gutter.append(marker(for: line, emptyKind: row.kind, side: line.anchor.side), side: line.anchor.side)
                codeColumn.append(
                    code(
                        line.text,
                        line: line,
                        fileExtension: fileExtension,
                        font: font,
                        showWhitespace: showWhitespace,
                        theme: theme
                    ),
                    kind: row.kind,
                    tone: tone(for: line, rowKind: row.kind),
                    sourceLine: line,
                    expansion: row.contextExpansion
                )
            }
        }

        return StackedResult(
            code: highlightedCodeDocument(
                codeColumn.document,
                fileExtension: fileExtension,
                theme: theme
            ),
            gutter: gutter.attributedString
        )
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
        if layoutMode == .stacked {
            return buildStackedSingleDocument(
                rows: rows,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            )
        }

        for row in rows {
            if output.length > 0 {
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: font, theme: theme)))
            }

            let start = output.length
            switch row.kind {
            case .collapsed:
                output.append(collapsedLine(row, font: font, theme: theme))
            case .expandableContext:
                output.append(expandableContextLine(row, font: font, theme: theme))
            case .context, .expandedContext, .add, .delete, .replacement:
                output.append(splitLine(
                    row,
                    fileExtension: fileExtension,
                    font: font,
                    showWhitespace: showWhitespace,
                    theme: theme,
                    splitColumnCharacterWidth: splitColumnCharacterWidth
                ))
            }

            lines.append(LineMetadata(
                kind: row.kind,
                range: NSRange(location: start, length: output.length - start),
                expansionKey: row.contextExpansion?.key,
                expansionBoundary: row.contextExpansion?.boundary
            ))
        }

        return Result(attributedString: output, lines: lines)
    }

    private static func buildStackedSingleDocument(
        rows: [DiffDisplayRow],
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> Result {
        let output = NSMutableAttributedString()
        var lines: [LineMetadata] = []
        var index = 0

        while index < rows.count {
            let row = rows[index]
            if output.length > 0 {
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: font, theme: theme)))
            }

            if row.kind == .collapsed || row.kind == .expandableContext {
                let start = output.length
                if row.kind == .expandableContext {
                    output.append(expandableContextLine(row, font: font, theme: theme))
                } else {
                    output.append(collapsedLine(row, font: font, theme: theme))
                }
                lines.append(LineMetadata(
                    kind: row.kind,
                    range: NSRange(location: start, length: output.length - start),
                    expansionKey: row.contextExpansion?.key,
                    expansionBoundary: row.contextExpansion?.boundary
                ))
                index += 1
                continue
            }

            let rowStart = index
            while index < rows.count, rows[index].kind != .collapsed, rows[index].kind != .expandableContext {
                index += 1
            }
            appendStackedLines(
                DiffPaneRowProjection.stackedLines(for: Array(rows[rowStart..<index])),
                to: output,
                lines: &lines,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            )
        }

        return Result(attributedString: output, lines: lines)
    }

    private static func appendStackedLines(
        _ stackedLines: [(row: DiffDisplayRow, line: DiffDisplayLine)],
        to output: NSMutableAttributedString,
        lines: inout [LineMetadata],
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) {
        for (index, entry) in stackedLines.enumerated() {
            let row = entry.row
            let line = entry.line
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
            let prefixLength = (prefix(for: line, emptyKind: .context, side: line.anchor.side) as NSString).length
            lines.append(LineMetadata(
                kind: row.kind,
                range: NSRange(location: start, length: output.length - start),
                sourceLine: line,
                sourceRange: NSRange(location: start + prefixLength, length: (line.text as NSString).length),
                expansionKey: row.contextExpansion?.key,
                expansionBoundary: row.contextExpansion?.boundary
            ))
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

    private static func expandableContextLine(
        _ row: DiffDisplayRow,
        font: NSFont,
        theme: Theme
    ) -> NSAttributedString {
        NSAttributedString(
            string: "      \(expandableContextLabel(row))",
            attributes: collapsedTextAttributes(font: font, theme: theme)
        )
    }

    private static func collapsedCodeText(
        _ row: DiffDisplayRow,
        font: NSFont,
        theme: Theme
    ) -> NSAttributedString {
        NSAttributedString(
            string: "... \(row.collapsedLineCount) unchanged lines",
            attributes: collapsedTextAttributes(font: font, theme: theme)
        )
    }

    private static func expandableContextText(
        _ row: DiffDisplayRow,
        font: NSFont,
        theme: Theme
    ) -> NSAttributedString {
        NSAttributedString(
            string: expandableContextLabel(row),
            attributes: collapsedTextAttributes(font: font, theme: theme)
        )
    }

    private static func expandableContextLabel(_ row: DiffDisplayRow) -> String {
        let boundaryText = row.contextExpansion?.boundary == .below ? "below" : "above"
        guard row.collapsedLineCount > 0 else {
            return "Expand context \(boundaryText)"
        }
        return "Expand \(row.collapsedLineCount) unchanged lines \(boundaryText)"
    }

    private static func collapsedTextAttributes(font: NSFont, theme: Theme) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor(theme.color("fg-dim")),
            .paragraphStyle: CenterTypography.paragraphStyle(),
        ]
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
            if text.isEmpty {
                return emptyLayoutGlyph(font: font, theme: theme)
            }
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
            theme: theme,
            highlightSyntax: false
        )
    }

    private static func highlightedCodeDocument(
        _ document: CodeDocument,
        fileExtension: String,
        theme: Theme
    ) -> CodeDocument {
        guard let source = document.syntaxSource, !source.isEmpty else {
            return document
        }

        let output = NSMutableAttributedString(attributedString: document.attributedString)
        for segment in syntaxSegments(in: document.lines) {
            let segmentRange = NSRange(
                location: segment.start,
                length: segment.end - segment.start
            )
            let segmentSource = (source as NSString).substring(with: segmentRange)
            let spans = TreeSitterHighlighter.highlight(source: segmentSource, fileExtension: fileExtension)
                .map {
                    HighlightSpan(
                        range: NSRange(location: $0.range.location + segmentRange.location, length: $0.range.length),
                        capture: $0.capture
                    )
                }
                .sorted { $0.range.location < $1.range.location }
            applySyntaxSpans(
                spans,
                to: output,
                lines: document.lines,
                startIndex: segment.startIndex,
                endIndex: segment.endIndex,
                theme: theme
            )
        }

        return CodeDocument(
            attributedString: output,
            lines: document.lines,
            syntaxSource: source
        )
    }

    private static func syntaxSegments(in lines: [LineMetadata]) -> [SyntaxSegment] {
        var result: [SyntaxSegment] = []
        var index = 0
        while index < lines.count {
            guard let group = lines[index].syntaxGroup,
                  let range = lines[index].sourceRange else {
                index += 1
                continue
            }

            let startIndex = index
            var endIndex = index
            var end = NSMaxRange(range)
            index += 1
            while index < lines.count, lines[index].syntaxGroup == group {
                endIndex = index
                if let nextRange = lines[index].sourceRange {
                    end = NSMaxRange(nextRange)
                } else {
                    end = NSMaxRange(lines[index].range)
                }
                index += 1
            }

            result.append(SyntaxSegment(
                start: range.location,
                end: end,
                startIndex: startIndex,
                endIndex: endIndex
            ))
        }
        return result
    }

    private static func applySyntaxSpans(
        _ spans: [HighlightSpan],
        to output: NSMutableAttributedString,
        lines: [LineMetadata],
        startIndex: Int,
        endIndex: Int,
        theme: Theme
    ) {
        var spansByLine = Array(repeating: [HighlightSpan](), count: endIndex - startIndex + 1)
        var lineIndex = startIndex
        for span in spans {
            let spanEnd = NSMaxRange(span.range)
            while lineIndex <= endIndex {
                guard let sourceRange = lines[lineIndex].sourceRange else {
                    lineIndex += 1
                    continue
                }
                if NSMaxRange(sourceRange) > span.range.location {
                    break
                }
                lineIndex += 1
            }

            var index = lineIndex
            while index <= endIndex {
                guard let sourceRange = lines[index].sourceRange else {
                    index += 1
                    continue
                }
                if sourceRange.location >= spanEnd { break }

                let intersection = NSIntersectionRange(span.range, sourceRange)
                if intersection.length > 0 {
                    spansByLine[index - startIndex].append(HighlightSpan(
                        range: NSRange(
                            location: intersection.location - sourceRange.location,
                            length: intersection.length
                        ),
                        capture: span.capture
                    ))
                }
                index += 1
            }
        }

        for (offset, lineSpans) in spansByLine.enumerated() where !lineSpans.isEmpty {
            let line = lines[startIndex + offset]
            guard let sourceRange = line.sourceRange else { continue }
            DiffCodeText.applySyntaxSpans(
                to: output,
                spans: lineSpans,
                offset: sourceRange.location,
                inlineTone: inlineTone(for: line.tone ?? .context),
                theme: theme,
                visibleLength: sourceRange.length
            )
        }
    }

    fileprivate static func marker(
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
        return line.lineNumber.map(String.init) ?? ""
    }

    private static func reviewSourceLine(_ line: DiffDisplayLine?, side: DiffLineSide) -> DiffDisplayLine? {
        guard let line else { return nil }
        guard line.anchor.side != side else { return line }

        let anchor = DiffLineAnchor(
            filePath: line.anchor.filePath,
            hunkIndex: line.anchor.hunkIndex,
            rowIndex: line.anchor.rowIndex,
            side: side,
            oldLine: side == .old ? line.anchor.oldLine : nil,
            newLine: side == .new ? line.anchor.newLine : nil
        )
        return DiffDisplayLine(
            id: "\(anchor.filePath):\(anchor.side.rawValue):\(anchor.oldLine ?? 0):\(anchor.newLine ?? 0)",
            anchor: anchor,
            text: line.text,
            lineNumber: line.lineNumber,
            kind: line.kind,
            inlineSpans: line.inlineSpans,
            noTrailingNewline: line.noTrailingNewline
        )
    }

    private static func tone(for line: DiffDisplayLine?, rowKind: DiffDisplayRow.Kind) -> DiffPaneLineTone {
        guard let line else {
            return (rowKind == .collapsed || rowKind == .expandableContext) ? .collapsed : .placeholder
        }
        switch line.kind {
        case .add:
            return .add
        case .delete:
            return .delete
        case .context:
            return .context
        }
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

    private static func emptyLayoutGlyph(font: NSFont, theme: Theme) -> NSAttributedString {
        NSAttributedString(
            string: " ",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.clear,
                .paragraphStyle: CenterTypography.paragraphStyle(),
            ]
        )
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

    private static func inlineTone(for tone: DiffPaneLineTone) -> DiffInlineTone {
        switch tone {
        case .add:
            return .add
        case .delete:
            return .del
        case .context, .placeholder, .collapsed:
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
        case .context, .expandedContext:
            return theme.color("bg-1")
        case .collapsed, .expandableContext:
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
    private let syntaxSource = NSMutableString()
    private var metadata: [DiffPaneTextDocumentBuilder.LineMetadata] = []
    private let newlineAttributes: [NSAttributedString.Key: Any]
    private var syntaxGroup = 0
    private var activeSyntaxSide: DiffLineSide?

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
            lines: metadata,
            syntaxSource: syntaxSource as String
        )
    }

    mutating func append(
        _ line: NSAttributedString,
        kind: DiffDisplayRow.Kind,
        tone: DiffPaneLineTone? = nil,
        sourceLine: DiffDisplayLine? = nil,
        expansion: DiffContextExpansionRow? = nil
    ) {
        if output.length > 0 {
            output.append(NSAttributedString(string: "\n", attributes: newlineAttributes))
            syntaxSource.append("\n")
        }
        let start = output.length
        output.append(line)
        let lineSyntaxGroup: Int?
        if let sourceLine {
            syntaxSource.append(sourceLine.text)
            if shouldStartNewSyntaxGroup(for: sourceLine.anchor.side) {
                syntaxGroup += 1
            }
            lineSyntaxGroup = syntaxGroup
            updateActiveSyntaxSide(with: sourceLine.anchor.side)
        } else {
            syntaxSource.append(String(repeating: " ", count: line.length))
            if kind == .collapsed || kind == .expandableContext {
                lineSyntaxGroup = nil
                syntaxGroup += 1
                activeSyntaxSide = nil
            } else {
                lineSyntaxGroup = syntaxGroup
            }
        }
        metadata.append(DiffPaneTextDocumentBuilder.LineMetadata(
            kind: kind,
            range: NSRange(location: start, length: line.length),
            tone: tone,
            sourceLine: sourceLine,
            sourceRange: sourceLine.map { _ in NSRange(location: start, length: line.length) },
            syntaxGroup: lineSyntaxGroup,
            expansionKey: expansion?.key,
            expansionBoundary: expansion?.boundary
        ))
    }

    private func shouldStartNewSyntaxGroup(for side: DiffLineSide) -> Bool {
        guard let activeSyntaxSide, activeSyntaxSide != side else {
            return false
        }
        return true
    }

    private mutating func updateActiveSyntaxSide(with side: DiffLineSide) {
        activeSyntaxSide = side
    }
}

private struct SyntaxSegment {
    let start: Int
    let end: Int
    let startIndex: Int
    let endIndex: Int
}

private struct GutterAccumulator {
    private let output = NSMutableAttributedString()
    private let font: NSFont
    private let theme: Theme
    private let newlineAttributes: [NSAttributedString.Key: Any]
    private var lineCount = 0

    init(font: NSFont, theme: Theme) {
        self.font = font
        self.theme = theme
        newlineAttributes = [
            .font: font,
            .foregroundColor: NSColor(theme.color("fg")),
            .paragraphStyle: CenterTypography.paragraphStyle(),
        ]
    }

    var attributedString: NSAttributedString {
        output
    }

    mutating func append(_ text: String, side: DiffLineSide) {
        if lineCount > 0 {
            output.append(NSAttributedString(string: "\n", attributes: newlineAttributes))
        }
        output.append(DiffPaneTextDocumentBuilder.marker(text, font: font, theme: theme, side: side))
        lineCount += 1
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
