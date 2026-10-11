import Foundation

enum ReviewDraftCommentPlacement {
    struct RowKey: Hashable, Equatable {
        let side: DiffReviewInlineFeedbackSide
        let line: Int
    }

    struct Result: Equatable {
        let fileLevel: [ReviewDraftComment]
        let image: [ReviewDraftComment]
        let byRowAnchor: [RowKey: [ReviewDraftComment]]
        let groupIDByCommentID: [String: String]
    }

    static func position(
        _ comments: [ReviewDraftComment],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        let visibleKeys = Set(groups.flatMap(allRowKeys))
        let groupIDByKey = firstGroupIDByRowKey(in: groups)
        var fileLevel: [ReviewDraftComment] = []
        var image: [ReviewDraftComment] = []
        var byRowAnchor: [RowKey: [ReviewDraftComment]] = [:]
        var groupIDByCommentID: [String: String] = [:]

        for comment in comments where comment.state != .dismissed {
            if case .image = comment.anchor {
                image.append(comment)
                continue
            }
            guard let lineRange = comment.normalizedLineRange else {
                fileLevel.append(comment)
                continue
            }
            let key = RowKey(side: comment.side, line: lineRange.upperBound)
            if visibleKeys.contains(key) {
                byRowAnchor[key, default: []].append(comment)
                if let groupID = groupIDByKey[key] {
                    groupIDByCommentID[comment.id] = groupID
                }
            } else {
                fileLevel.append(comment)
            }
        }

        return Result(
            fileLevel: sorted(fileLevel),
            image: sorted(image),
            byRowAnchor: byRowAnchor.mapValues(sorted),
            groupIDByCommentID: groupIDByCommentID
        )
    }

    private static func firstGroupIDByRowKey(in groups: [DiffDisplayGroup]) -> [RowKey: String] {
        var output: [RowKey: String] = [:]
        for group in groups {
            for key in allRowKeys(in: group) where output[key] == nil {
                output[key] = group.id
            }
        }
        return output
    }

    static func visibleRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap { row -> [RowKey] in
            visibleRowKeys(in: row)
        }
    }

    static func allRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap(allRowKeys)
    }

    static func visibleRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        var keys: [RowKey] = []
        if let oldLine = row.old?.lineNumber {
            keys.append(RowKey(side: .old, line: oldLine))
        }
        if let newLine = row.new?.lineNumber {
            keys.append(RowKey(side: .new, line: newLine))
        }
        for line in Set([row.old?.lineNumber, row.new?.lineNumber].compactMap(\.self)).sorted() {
            keys.append(RowKey(side: .unknown, line: line))
        }
        return keys
    }

    static func allRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        visibleRowKeys(in: row) + row.collapsedRows.flatMap(allRowKeys)
    }

    static func sorted(_ comments: [ReviewDraftComment]) -> [ReviewDraftComment] {
        comments.sorted { lhs, rhs in
            if lhs.path != rhs.path {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            if let lhsRange = lhs.normalizedLineRange, let rhsRange = rhs.normalizedLineRange {
                if lhsRange.lowerBound != rhsRange.lowerBound {
                    return lhsRange.lowerBound < rhsRange.lowerBound
                }
                if lhsRange.upperBound != rhsRange.upperBound {
                    return lhsRange.upperBound < rhsRange.upperBound
                }
            } else if lhs.normalizedLineRange != nil {
                return false
            } else if rhs.normalizedLineRange != nil {
                return true
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    static func comments(
        matching keys: [RowKey],
        in placement: Result,
        groupID: String? = nil,
        excludingIDs excludedIDs: Set<String> = []
    ) -> [ReviewDraftComment] {
        var seenIDs = excludedIDs
        var comments: [ReviewDraftComment] = []
        for key in keys {
            for comment in placement.byRowAnchor[key] ?? [] {
                if let groupID, placement.groupIDByCommentID[comment.id] != groupID {
                    continue
                }
                guard seenIDs.insert(comment.id).inserted else { continue }
                comments.append(comment)
            }
        }
        return sorted(comments)
    }
}

enum ReviewDraftCommentRowSegmentation {
    struct Segment: Equatable, Identifiable {
        let id: String
        let rows: [DiffDisplayRow]
        let rowsSignature: DiffDisplayRowsSignature
        let draftComments: [ReviewDraftComment]
        let showsComposer: Bool

        init(
            id: String,
            rows: [DiffDisplayRow],
            rowsSignature: DiffDisplayRowsSignature? = nil,
            draftComments: [ReviewDraftComment],
            showsComposer: Bool
        ) {
            self.id = id
            self.rows = rows
            self.rowsSignature = rowsSignature ?? DiffDisplayRowsSignature(rows)
            self.draftComments = draftComments
            self.showsComposer = showsComposer
        }

        static func == (lhs: Segment, rhs: Segment) -> Bool {
            lhs.id == rhs.id
                && lhs.rowsSignature == rhs.rowsSignature
                && lhs.draftComments == rhs.draftComments
                && lhs.showsComposer == rhs.showsComposer
        }
    }

    struct Result: Equatable {
        let items: [Segment]

        var containsLocalAccessories: Bool {
            items.contains { !$0.draftComments.isEmpty || $0.showsComposer }
        }
    }

    static func segments(
        for group: DiffDisplayGroup,
        placement: ReviewDraftCommentPlacement.Result,
        pendingAnchor: DiffReviewLineAnchor?,
        canCreateDraftComment: Bool = true
    ) -> Result {
        let pendingKey = pendingAnchor.flatMap { pendingRowKey(for: $0, in: group) }
        let duplicatePendingKey = pendingKey.map { key in
            group.rows.filter { ReviewDraftCommentPlacement.allRowKeys(in: $0).contains(key) }.count > 1
        } ?? false
        var segments: [Segment] = []
        var bufferedRows: [DiffDisplayRow] = []
        var emittedCommentIDs: Set<String> = []

        for row in group.rows {
            bufferedRows.append(row)
            let keys = ReviewDraftCommentPlacement.allRowKeys(in: row)
            let comments = ReviewDraftCommentPlacement.comments(
                matching: keys,
                in: placement,
                groupID: group.id,
                excludingIDs: emittedCommentIDs
            )
            emittedCommentIDs.formUnion(comments.map(\.id))
            let showsComposer = canCreateDraftComment && (pendingKey.map { key in
                guard keys.contains(key) else { return false }
                guard duplicatePendingKey, let pendingAnchor else { return true }
                return rowContainsDisplayRowIndex(pendingAnchor.endRowIndex, row: row)
            } ?? false)
            guard !comments.isEmpty || showsComposer else { continue }

            segments.append(Segment(
                id: "\(group.id)-segment-\(segments.count)",
                rows: bufferedRows,
                draftComments: comments,
                showsComposer: showsComposer
            ))
            bufferedRows = []
        }

        if !bufferedRows.isEmpty {
            segments.append(Segment(
                id: "\(group.id)-segment-\(segments.count)",
                rows: bufferedRows,
                draftComments: [],
                showsComposer: false
            ))
        }

        return Result(items: segments)
    }

    static func canonicalPendingAnchor(
        _ anchor: DiffReviewLineAnchor,
        in groups: [DiffDisplayGroup]
    ) -> DiffReviewLineAnchor {
        guard anchor.side == .unknown else { return anchor }
        guard groups.contains(where: { canPlaceUnknownAnchor(anchor, in: $0) }) else { return anchor }

        if let range = selectedLineRange(anchor.selectedLines, side: .new, requiresChange: true) {
            return DiffReviewLineAnchor(
                path: anchor.path,
                side: .new,
                line: range.lowerBound,
                endLine: range.lowerBound == range.upperBound ? nil : range.upperBound,
                rowIndex: anchor.rowIndex,
                endRowIndex: anchor.endRowIndex,
                selectedLines: anchor.selectedLines,
                selectedText: anchor.selectedText
            )
        }

        if let range = selectedLineRange(anchor.selectedLines, side: .old, requiresChange: true) {
            return DiffReviewLineAnchor(
                path: anchor.path,
                side: .old,
                line: range.lowerBound,
                endLine: range.lowerBound == range.upperBound ? nil : range.upperBound,
                rowIndex: anchor.rowIndex,
                endRowIndex: anchor.endRowIndex,
                selectedLines: anchor.selectedLines,
                selectedText: anchor.selectedText
            )
        }

        return anchor
    }

    static func sourceIndexedAnchor(
        _ anchor: DiffReviewLineAnchor,
        in rows: [DiffDisplayRow]
    ) -> DiffReviewLineAnchor {
        let rowIndex = sourceRowIndex(for: anchor.rowIndex, side: anchor.side, in: rows) ?? anchor.rowIndex
        let endRowIndex = sourceRowIndex(for: anchor.endRowIndex, side: anchor.side, in: rows) ?? anchor.endRowIndex
        guard rowIndex != anchor.rowIndex || endRowIndex != anchor.endRowIndex else { return anchor }

        return DiffReviewLineAnchor(
            path: anchor.path,
            side: anchor.side,
            line: anchor.line,
            endLine: anchor.endLine,
            rowIndex: rowIndex,
            endRowIndex: endRowIndex,
            selectedLines: anchor.selectedLines,
            selectedText: anchor.selectedText
        )
    }

    private static func pendingRowKey(
        for anchor: DiffReviewLineAnchor,
        in group: DiffDisplayGroup
    ) -> ReviewDraftCommentPlacement.RowKey? {
        guard anchor.side == .unknown else {
            return ReviewDraftCommentPlacement.RowKey(side: anchor.side, line: anchor.draftPlacementLine)
        }

        guard canPlaceUnknownAnchor(anchor, in: group) else { return nil }
        let canonicalAnchor = canonicalPendingAnchor(anchor, in: [group])
        return ReviewDraftCommentPlacement.RowKey(
            side: canonicalAnchor.side,
            line: canonicalAnchor.draftPlacementLine
        )
    }

    private static func canPlaceUnknownAnchor(
        _ anchor: DiffReviewLineAnchor,
        in group: DiffDisplayGroup
    ) -> Bool {
        let keys = Set(ReviewDraftCommentPlacement.allRowKeys(in: group))
        return keys.contains(ReviewDraftCommentPlacement.RowKey(side: .unknown, line: anchor.draftPlacementLine))
            || keys.contains(ReviewDraftCommentPlacement.RowKey(side: .unknown, line: anchor.line))
    }

    private static func rowContainsDisplayRowIndex(_ rowIndex: Int, row: DiffDisplayRow) -> Bool {
        row.old?.anchor.rowIndex == rowIndex
            || row.new?.anchor.rowIndex == rowIndex
            || row.collapsedRows.contains { rowContainsDisplayRowIndex(rowIndex, row: $0) }
    }

    private static func sourceRowIndex(
        for localRowIndex: Int,
        side: DiffReviewInlineFeedbackSide,
        in rows: [DiffDisplayRow]
    ) -> Int? {
        guard rows.indices.contains(localRowIndex) else { return nil }
        let row = rows[localRowIndex]
        switch side {
        case .old:
            return row.old?.anchor.rowIndex ?? row.new?.anchor.rowIndex
        case .new:
            return row.new?.anchor.rowIndex ?? row.old?.anchor.rowIndex
        case .unknown:
            return row.old?.anchor.rowIndex ?? row.new?.anchor.rowIndex
        }
    }

    private static func selectedLineRange(
        _ selectedLines: [DiffReviewLineAnchor.SelectedLine],
        side: DiffReviewInlineFeedbackSide,
        requiresChange: Bool
    ) -> ClosedRange<Int>? {
        let lines = selectedLines.compactMap { line -> Int? in
            guard line.side == side else { return nil }
            guard !requiresChange || line.isChange else { return nil }
            return line.line
        }
        guard let lower = lines.min(), let upper = lines.max() else { return nil }
        return lower...upper
    }
}

enum DiffReviewInlineFeedbackPlacement {
    struct Result: Equatable {
        let fileLevel: [DiffReviewInlineFeedback]
        let byGroupID: [String: [DiffReviewInlineFeedback]]
    }

    static func position(
        _ items: [DiffReviewInlineFeedback],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        var fileLevel: [DiffReviewInlineFeedback] = []
        var byGroupID: [String: [DiffReviewInlineFeedback]] = [:]

        for item in items {
            guard let line = item.anchor.line,
                  let group = groups.first(where: { contains(line: line, side: item.anchor.side, in: $0) })
            else {
                fileLevel.append(item)
                continue
            }
            byGroupID[group.id, default: []].append(item)
        }

        return Result(fileLevel: fileLevel, byGroupID: byGroupID)
    }

    private static func contains(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        in group: DiffDisplayGroup
    ) -> Bool {
        group.rows.contains { row in
            contains(line: line, side: side, in: row)
        }
    }

    private static func contains(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        in row: DiffDisplayRow
    ) -> Bool {
        if rowMatches(line: line, side: side, row: row) {
            return true
        }
        return row.collapsedRows.contains { collapsedRow in
            contains(line: line, side: side, in: collapsedRow)
        }
    }

    private static func rowMatches(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        row: DiffDisplayRow
    ) -> Bool {
        switch side {
        case .new:
            return row.new?.lineNumber == line
        case .old:
            return row.old?.lineNumber == line
        case .unknown:
            return row.new?.lineNumber == line || row.old?.lineNumber == line
        }
    }
}
