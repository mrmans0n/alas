import Foundation

enum DiffDisplayModelBuilder {
    private struct IndexedLine {
        let index: Int
        let line: ParsedDiff.Hunk.Line
    }

    static func build(
        diff: ParsedDiff,
        filePath: String,
        collapseContextThreshold: Int = 12,
        contextEdgeCount: Int = 3
    ) -> DiffDisplayModel {
        let groups = diff.hunks.enumerated().map { hunkIndex, hunk in
            DiffDisplayGroup(
                id: "hunk-\(hunkIndex)-\(hunk.header)",
                header: hunk.header,
                sourceHunk: hunk,
                rows: buildRows(
                    hunk: hunk,
                    filePath: filePath,
                    hunkIndex: hunkIndex,
                    collapseContextThreshold: collapseContextThreshold,
                    contextEdgeCount: contextEdgeCount
                )
            )
        }

        return DiffDisplayModel(filePath: filePath, groups: groups)
    }

    private static func buildRows(
        hunk: ParsedDiff.Hunk,
        filePath: String,
        hunkIndex: Int,
        collapseContextThreshold: Int,
        contextEdgeCount: Int
    ) -> [DiffDisplayRow] {
        var rows: [DiffDisplayRow] = []
        var index = 0

        while index < hunk.lines.count {
            let line = IndexedLine(index: index, line: hunk.lines[index])
            switch line.line.kind {
            case .context:
                let start = index
                while index < hunk.lines.count, hunk.lines[index].kind == .context {
                    index += 1
                }
                appendContextRows(
                    (start..<index).map { IndexedLine(index: $0, line: hunk.lines[$0]) },
                    to: &rows,
                    filePath: filePath,
                    hunkIndex: hunkIndex,
                    collapseContextThreshold: collapseContextThreshold,
                    contextEdgeCount: contextEdgeCount
                )
            case .delete:
                let deleteStart = index
                while index < hunk.lines.count, hunk.lines[index].kind == .delete {
                    index += 1
                }
                let deletes = (deleteStart..<index).map { IndexedLine(index: $0, line: hunk.lines[$0]) }

                let addStart = index
                while index < hunk.lines.count, hunk.lines[index].kind == .add {
                    index += 1
                }
                let adds = (addStart..<index).map { IndexedLine(index: $0, line: hunk.lines[$0]) }

                appendChangedRows(
                    deletes: deletes,
                    adds: adds,
                    to: &rows,
                    filePath: filePath,
                    hunkIndex: hunkIndex
                )
            case .add:
                let addStart = index
                while index < hunk.lines.count, hunk.lines[index].kind == .add {
                    index += 1
                }
                let adds = (addStart..<index).map { IndexedLine(index: $0, line: hunk.lines[$0]) }
                appendChangedRows(
                    deletes: [],
                    adds: adds,
                    to: &rows,
                    filePath: filePath,
                    hunkIndex: hunkIndex
                )
            }
        }

        return rows
    }

    private static func appendContextRows(
        _ lines: [IndexedLine],
        to rows: inout [DiffDisplayRow],
        filePath: String,
        hunkIndex: Int,
        collapseContextThreshold: Int,
        contextEdgeCount: Int
    ) {
        guard shouldCollapse(lines, threshold: collapseContextThreshold, edgeCount: contextEdgeCount) else {
            lines.forEach {
                appendContextRow($0, to: &rows, filePath: filePath, hunkIndex: hunkIndex)
            }
            return
        }

        lines.prefix(contextEdgeCount).forEach {
            appendContextRow($0, to: &rows, filePath: filePath, hunkIndex: hunkIndex)
        }

        rows.append(
            DiffDisplayRow(
                id: "hunk-\(hunkIndex)-row-\(rows.count)-collapsed",
                kind: .collapsed,
                old: nil,
                new: nil,
                collapsedLineCount: lines.count - (contextEdgeCount * 2)
            )
        )

        lines.suffix(contextEdgeCount).forEach {
            appendContextRow($0, to: &rows, filePath: filePath, hunkIndex: hunkIndex)
        }
    }

    private static func shouldCollapse(
        _ lines: [IndexedLine],
        threshold: Int,
        edgeCount: Int
    ) -> Bool {
        lines.count > threshold && edgeCount > 0 && lines.count > edgeCount * 2
    }

    private static func appendContextRow(
        _ source: IndexedLine,
        to rows: inout [DiffDisplayRow],
        filePath: String,
        hunkIndex: Int
    ) {
        let line = source.line
        let rowIndex = source.index
        rows.append(
            DiffDisplayRow(
                id: "hunk-\(hunkIndex)-row-\(rowIndex)-context-\(line.oldNumber ?? 0)-\(line.newNumber ?? 0)",
                kind: .context,
                old: displayLine(
                    line,
                    filePath: filePath,
                    hunkIndex: hunkIndex,
                    rowIndex: rowIndex,
                    side: .old,
                    inlineSpans: []
                ),
                new: displayLine(
                    line,
                    filePath: filePath,
                    hunkIndex: hunkIndex,
                    rowIndex: rowIndex,
                    side: .new,
                    inlineSpans: []
                ),
                collapsedLineCount: 0
            )
        )
    }

    private static func appendChangedRows(
        deletes: [IndexedLine],
        adds: [IndexedLine],
        to rows: inout [DiffDisplayRow],
        filePath: String,
        hunkIndex: Int
    ) {
        let replacementCount = min(deletes.count, adds.count)
        for offset in 0..<replacementCount {
            let deleteLine = deletes[offset]
            let addLine = adds[offset]
            let highlight = DiffInlineHighlighter.highlightDeleteAdd(old: deleteLine.line.text, new: addLine.line.text)
            let rowIndex = deleteLine.index
            rows.append(
                DiffDisplayRow(
                    id: "hunk-\(hunkIndex)-row-\(rowIndex)-replacement-\(deleteLine.line.oldNumber ?? 0)-\(addLine.line.newNumber ?? 0)",
                    kind: .replacement,
                    old: displayLine(
                        deleteLine.line,
                        filePath: filePath,
                        hunkIndex: hunkIndex,
                        rowIndex: rowIndex,
                        side: .old,
                        inlineSpans: highlight.oldSpans
                    ),
                    new: displayLine(
                        addLine.line,
                        filePath: filePath,
                        hunkIndex: hunkIndex,
                        rowIndex: rowIndex,
                        side: .new,
                        inlineSpans: highlight.newSpans
                    ),
                    collapsedLineCount: 0
                )
            )
        }

        deletes.dropFirst(replacementCount).forEach { source in
            let line = source.line
            let rowIndex = source.index
            rows.append(
                DiffDisplayRow(
                    id: "hunk-\(hunkIndex)-row-\(rowIndex)-delete-\(line.oldNumber ?? 0)",
                    kind: .delete,
                    old: displayLine(
                        line,
                        filePath: filePath,
                        hunkIndex: hunkIndex,
                        rowIndex: rowIndex,
                        side: .old,
                        inlineSpans: []
                    ),
                    new: nil,
                    collapsedLineCount: 0
                )
            )
        }

        adds.dropFirst(replacementCount).forEach { source in
            let line = source.line
            let rowIndex = source.index
            rows.append(
                DiffDisplayRow(
                    id: "hunk-\(hunkIndex)-row-\(rowIndex)-add-\(line.newNumber ?? 0)",
                    kind: .add,
                    old: nil,
                    new: displayLine(
                        line,
                        filePath: filePath,
                        hunkIndex: hunkIndex,
                        rowIndex: rowIndex,
                        side: .new,
                        inlineSpans: []
                    ),
                    collapsedLineCount: 0
                )
            )
        }
    }

    private static func displayLine(
        _ line: ParsedDiff.Hunk.Line,
        filePath: String,
        hunkIndex: Int,
        rowIndex: Int,
        side: DiffLineSide,
        inlineSpans: [DiffInlineSpan]
    ) -> DiffDisplayLine {
        let lineNumber: Int?
        switch side {
        case .old:
            lineNumber = line.oldNumber
        case .new:
            lineNumber = line.newNumber
        case .paired:
            lineNumber = line.newNumber ?? line.oldNumber
        }

        let anchor = DiffLineAnchor(
            filePath: filePath,
            hunkIndex: hunkIndex,
            rowIndex: rowIndex,
            side: side,
            oldLine: side == .new ? nil : line.oldNumber,
            newLine: side == .old ? nil : line.newNumber
        )

        return DiffDisplayLine(
            id: "\(anchor.filePath):\(anchor.side.rawValue):\(anchor.oldLine ?? 0):\(anchor.newLine ?? 0)",
            anchor: anchor,
            text: line.text,
            lineNumber: lineNumber,
            kind: line.kind,
            inlineSpans: inlineSpans,
            noTrailingNewline: line.noTrailingNewline
        )
    }
}
