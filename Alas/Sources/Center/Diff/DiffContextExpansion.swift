import Foundation

enum DiffReviewFileContextLines: Equatable, Sendable {
    case unavailable
    case available([String])
}

struct DiffReviewFileContextSnapshot: Equatable, Sendable {
    let old: DiffReviewFileContextLines
    let new: DiffReviewFileContextLines
}

struct DiffContextExpansionState: Equatable {
    enum Mode: Equatable {
        case chunk(size: Int)
        case all
    }

    private var expandedLineCounts: [DiffContextExpansionKey: Int] = [:]

    func expandedLineCount(for key: DiffContextExpansionKey) -> Int {
        expandedLineCounts[key, default: 0]
    }

    mutating func expand(_ key: DiffContextExpansionKey, available: Int, mode: Mode) {
        let available = max(0, available)
        let current = expandedLineCounts[key, default: 0]
        let next: Int
        switch mode {
        case let .chunk(size):
            next = current + max(0, size)
        case .all:
            next = available
        }
        expandedLineCounts[key] = min(next, available)
    }
}

enum DiffContextExpandedDisplayBuilder {
    private struct BoundaryRange {
        let oldStart: Int?
        let oldCount: Int
        let newStart: Int?
        let newCount: Int

        var lineCount: Int {
            max(oldCount, newCount)
        }
    }

    static func derive(
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot,
        providerAvailable: Bool,
        expansion: DiffContextExpansionState,
        filePath: String,
        chunkSize: Int
    ) -> [DiffDisplayGroup] {
        groups.enumerated().map { index, group in
            var rows: [DiffDisplayRow] = []

            if providerAvailable {
                rows.append(contentsOf: expansionRows(
                    for: group,
                    groupIndex: index,
                    boundary: .above,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    filePath: filePath,
                    chunkSize: chunkSize
                ))
            }

            rows.append(contentsOf: group.rows)

            if providerAvailable {
                rows.append(contentsOf: expansionRows(
                    for: group,
                    groupIndex: index,
                    boundary: .below,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    filePath: filePath,
                    chunkSize: chunkSize
                ))
            }

            return DiffDisplayGroup(
                id: group.id,
                header: group.header,
                sourceHunk: group.sourceHunk,
                rows: rows
            )
        }
    }

    private static func expansionRows(
        for group: DiffDisplayGroup,
        groupIndex: Int,
        boundary: DiffContextBoundary,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot,
        expansion: DiffContextExpansionState,
        filePath: String,
        chunkSize: Int
    ) -> [DiffDisplayRow] {
        let range = boundaryRange(
            for: group,
            groupIndex: groupIndex,
            boundary: boundary,
            groups: groups,
            snapshot: snapshot
        )
        let available = range.lineCount
        guard available > 0 else { return [] }

        let key = DiffContextExpansionKey(groupID: group.id, boundary: boundary)
        let expandedCount = min(expansion.expandedLineCount(for: key), available)
        let remaining = available - expandedCount
        let offsets: Range<Int>
        switch boundary {
        case .above:
            offsets = (available - expandedCount)..<available
        case .below:
            offsets = 0..<expandedCount
        }

        var rows = offsets.map {
            expandedContextRow(
                group: group,
                groupIndex: groupIndex,
                boundary: boundary,
                range: range,
                offset: $0,
                totalCount: available,
                snapshot: snapshot,
                filePath: filePath
            )
        }

        guard remaining > 0 else { return rows }

        let expandable = expandableRow(
            group: group,
            boundary: boundary,
            remaining: remaining,
            key: key,
            chunkSize: chunkSize
        )
        switch boundary {
        case .above:
            rows.append(expandable)
        case .below:
            rows.insert(expandable, at: rows.endIndex)
        }
        return rows
    }

    private static func boundaryRange(
        for group: DiffDisplayGroup,
        groupIndex: Int,
        boundary: DiffContextBoundary,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot
    ) -> BoundaryRange {
        let previous = groupIndex > 0 ? groups[groupIndex - 1] : nil
        let next = groupIndex + 1 < groups.count ? groups[groupIndex + 1] : nil

        switch boundary {
        case .above:
            return BoundaryRange(
                oldStart: startAfterLastLine(in: previous, side: .old),
                oldCount: aboveCount(
                    start: startAfterLastLine(in: previous, side: .old),
                    end: lineBeforeFirstLine(in: group, side: .old),
                    snapshotLines: snapshot.old.lineCount
                ),
                newStart: startAfterLastLine(in: previous, side: .new),
                newCount: aboveCount(
                    start: startAfterLastLine(in: previous, side: .new),
                    end: lineBeforeFirstLine(in: group, side: .new),
                    snapshotLines: snapshot.new.lineCount
                )
            )
        case .below:
            return BoundaryRange(
                oldStart: lineAfterLastLine(in: group, side: .old),
                oldCount: belowCount(
                    start: lineAfterLastLine(in: group, side: .old),
                    end: lineBeforeFirstLine(in: next, side: .old) ?? snapshot.old.lineCount,
                    snapshotLines: snapshot.old.lineCount
                ),
                newStart: lineAfterLastLine(in: group, side: .new),
                newCount: belowCount(
                    start: lineAfterLastLine(in: group, side: .new),
                    end: lineBeforeFirstLine(in: next, side: .new) ?? snapshot.new.lineCount,
                    snapshotLines: snapshot.new.lineCount
                )
            )
        }
    }

    private static func aboveCount(start: Int?, end: Int?, snapshotLines: Int?) -> Int {
        guard let snapshotLines, let start, let end else { return 0 }
        let clampedStart = max(1, start)
        let clampedEnd = min(end, snapshotLines)
        guard clampedStart <= clampedEnd else { return 0 }
        return clampedEnd - clampedStart + 1
    }

    private static func belowCount(start: Int?, end: Int?, snapshotLines: Int?) -> Int {
        guard let snapshotLines, let start, let end else { return 0 }
        let clampedStart = max(1, start)
        let clampedEnd = min(end, snapshotLines)
        guard clampedStart <= clampedEnd else { return 0 }
        return clampedEnd - clampedStart + 1
    }

    private static func startAfterLastLine(in group: DiffDisplayGroup?, side: DiffLineSide) -> Int? {
        guard let group else { return 1 }
        return lastLineNumber(in: group, side: side).map { $0 + 1 }
    }

    private static func lineBeforeFirstLine(in group: DiffDisplayGroup?, side: DiffLineSide) -> Int? {
        guard let group else { return nil }
        return firstLineNumber(in: group, side: side).map { $0 - 1 }
    }

    private static func lineAfterLastLine(in group: DiffDisplayGroup, side: DiffLineSide) -> Int? {
        lastLineNumber(in: group, side: side).map { $0 + 1 }
    }

    private static func firstLineNumber(in group: DiffDisplayGroup, side: DiffLineSide) -> Int? {
        for row in group.rows {
            let line = side == .old ? row.old : row.new
            if let number = line?.lineNumber {
                return number
            }
        }
        return nil
    }

    private static func lastLineNumber(in group: DiffDisplayGroup, side: DiffLineSide) -> Int? {
        for row in group.rows.reversed() {
            let line = side == .old ? row.old : row.new
            if let number = line?.lineNumber {
                return number
            }
        }
        return nil
    }

    private static func expandedContextRow(
        group: DiffDisplayGroup,
        groupIndex: Int,
        boundary: DiffContextBoundary,
        range: BoundaryRange,
        offset: Int,
        totalCount: Int,
        snapshot: DiffReviewFileContextSnapshot,
        filePath: String
    ) -> DiffDisplayRow {
        let oldNumber = lineNumber(
            start: range.oldStart,
            count: range.oldCount,
            offset: offset,
            totalCount: totalCount,
            boundary: boundary
        )
        let newNumber = lineNumber(
            start: range.newStart,
            count: range.newCount,
            offset: offset,
            totalCount: totalCount,
            boundary: boundary
        )
        let rowIndex = syntheticRowIndex(boundary: boundary, offset: offset)
        let anchorSide = anchorSide(oldNumber: oldNumber, newNumber: newNumber)
        let anchor = DiffLineAnchor(
            filePath: filePath,
            hunkIndex: groupIndex,
            rowIndex: rowIndex,
            side: anchorSide,
            oldLine: anchorSide == .new ? nil : oldNumber,
            newLine: anchorSide == .old ? nil : newNumber
        )

        return DiffDisplayRow(
            id: "\(group.id)-expanded-\(boundary.rawValue)-\(offset)-\(oldNumber ?? 0)-\(newNumber ?? 0)",
            kind: .expandedContext,
            old: displayLine(
                anchor: anchor,
                number: oldNumber,
                text: oldNumber.flatMap { snapshot.old.line(at: $0) }
            ),
            new: displayLine(
                anchor: anchor,
                number: newNumber,
                text: newNumber.flatMap { snapshot.new.line(at: $0) }
            ),
            collapsedLineCount: 0
        )
    }

    private static func expandableRow(
        group: DiffDisplayGroup,
        boundary: DiffContextBoundary,
        remaining: Int,
        key: DiffContextExpansionKey,
        chunkSize: Int
    ) -> DiffDisplayRow {
        DiffDisplayRow(
            id: "\(group.id)-expand-\(boundary.rawValue)-\(remaining)-\(chunkSize)",
            kind: .expandableContext,
            old: nil,
            new: nil,
            collapsedLineCount: remaining,
            contextExpansion: DiffContextExpansionRow(
                key: key,
                boundary: boundary,
                remainingLineCount: remaining
            )
        )
    }

    private static func displayLine(anchor: DiffLineAnchor, number: Int?, text: String?) -> DiffDisplayLine? {
        guard let number, let text else { return nil }
        return DiffDisplayLine(
            id: "\(anchor.filePath):\(anchor.side.rawValue):\(anchor.oldLine ?? 0):\(anchor.newLine ?? 0):\(number)",
            anchor: anchor,
            text: text,
            lineNumber: number,
            kind: .context,
            inlineSpans: [],
            noTrailingNewline: false
        )
    }

    private static func lineNumber(
        start: Int?,
        count: Int,
        offset: Int,
        totalCount: Int,
        boundary: DiffContextBoundary
    ) -> Int? {
        guard let start, count > 0 else { return nil }
        switch boundary {
        case .above:
            let alignedOffset = offset - (totalCount - count)
            guard alignedOffset >= 0, alignedOffset < count else { return nil }
            return start + alignedOffset
        case .below:
            guard offset < count else { return nil }
            return start + offset
        }
    }

    private static func syntheticRowIndex(boundary: DiffContextBoundary, offset: Int) -> Int {
        switch boundary {
        case .above:
            return -100_000 + offset
        case .below:
            return 100_000 + offset
        }
    }

    private static func anchorSide(oldNumber: Int?, newNumber: Int?) -> DiffLineSide {
        if oldNumber != nil, newNumber != nil {
            return .paired
        }
        return oldNumber == nil ? .new : .old
    }
}

private extension DiffReviewFileContextLines {
    var lineCount: Int? {
        switch self {
        case .unavailable:
            return nil
        case let .available(lines):
            return lines.count
        }
    }

    func line(at number: Int) -> String? {
        switch self {
        case .unavailable:
            return nil
        case let .available(lines):
            let index = number - 1
            guard lines.indices.contains(index) else { return nil }
            return lines[index]
        }
    }
}
