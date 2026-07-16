import Foundation

enum DiffReviewFileContextLines: Equatable, Sendable {
    case unavailable
    case available([String])
}

struct DiffReviewFileContextSnapshot: Equatable, Sendable {
    let old: DiffReviewFileContextLines
    let new: DiffReviewFileContextLines
}

enum DiffContextExpansionMode: Equatable {
    case chunk(size: Int)
    case all
}

struct DiffContextExpansionState: Equatable {
    private struct SharedExpansion: Equatable {
        var top: Int = 0
        var bottom: Int = 0
    }

    private var expandedLineCounts: [DiffContextExpansionKey: Int] = [:]
    private var sharedExpandedLineCounts: [DiffContextExpansionKey: SharedExpansion] = [:]

    func expandedLineCount(for key: DiffContextExpansionKey) -> Int {
        if key.isShared {
            return expandedLineCount(for: key, edge: .top)
        }
        return expandedLineCounts[key, default: 0]
    }

    func expandedLineCount(for key: DiffContextExpansionKey, edge: DiffContextExpansionEdge) -> Int {
        guard key.isShared else {
            return expandedLineCount(for: key)
        }

        let shared = sharedExpandedLineCounts[key, default: SharedExpansion()]
        switch edge {
        case .top:
            return shared.top
        case .bottom:
            return shared.bottom
        }
    }

    func remainingLineCount(for key: DiffContextExpansionKey, available: Int) -> Int {
        let available = max(0, available)
        guard key.isShared else {
            return max(0, available - expandedLineCount(for: key))
        }

        let shared = sharedExpandedLineCounts[key, default: SharedExpansion()]
        return max(0, available - shared.top - shared.bottom)
    }

    mutating func expand(_ key: DiffContextExpansionKey, available: Int, mode: DiffContextExpansionMode) {
        if key.isShared {
            expand(key, available: available, mode: mode, edge: .top)
            return
        }

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

    mutating func expand(
        _ key: DiffContextExpansionKey,
        available: Int,
        mode: DiffContextExpansionMode,
        edge: DiffContextExpansionEdge
    ) {
        guard key.isShared else {
            expand(key, available: available, mode: mode)
            return
        }

        let available = max(0, available)
        var shared = sharedExpandedLineCounts[key, default: SharedExpansion()]
        let current: Int
        let other: Int
        switch edge {
        case .top:
            current = shared.top
            other = shared.bottom
        case .bottom:
            current = shared.bottom
            other = shared.top
        }

        let requested: Int
        switch mode {
        case let .chunk(size):
            requested = current + max(0, size)
        case .all:
            requested = available - other
        }

        let clamped = min(max(0, requested), max(0, available - other))
        switch edge {
        case .top:
            shared.top = clamped
        case .bottom:
            shared.bottom = clamped
        }
        sharedExpandedLineCounts[key] = shared
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

    private struct HunkSideExtent {
        let start: Int
        let count: Int

        var lineBefore: Int {
            count > 0 ? start - 1 : start
        }

        var lineAfter: Int {
            start + max(count, 1)
        }
    }

    static func derive(
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        providerAvailable: Bool,
        expansion: DiffContextExpansionState,
        filePath: String,
        chunkSize: Int
    ) -> [DiffDisplayGroup] {
        groups.enumerated().map { index, group in
            var rows: [DiffDisplayRow] = []

            if providerAvailable, index == 0 {
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

            if providerAvailable, index > 0 {
                rows.append(contentsOf: sharedExpansionRows(
                    upperGroup: groups[index - 1],
                    lowerGroup: group,
                    upperGroupIndex: index - 1,
                    lowerGroupIndex: index,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    filePath: filePath,
                    edge: .bottom
                ))
            }

            rows.append(contentsOf: group.rows)

            if providerAvailable, index + 1 < groups.count {
                rows.append(contentsOf: sharedExpansionRows(
                    upperGroup: group,
                    lowerGroup: groups[index + 1],
                    upperGroupIndex: index,
                    lowerGroupIndex: index + 1,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    filePath: filePath,
                    edge: .top
                ))
            } else if providerAvailable {
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
                rows: rows,
                sharedContextBefore: sharedContextBefore(
                    forGroupAt: index,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    providerAvailable: providerAvailable
                ),
                sharedContextAfter: sharedContextAfter(
                    forGroupAt: index,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    providerAvailable: providerAvailable
                )
            )
        }
    }

    private static func sharedContextBefore(
        forGroupAt index: Int,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        expansion: DiffContextExpansionState,
        providerAvailable: Bool
    ) -> DiffContextExpansionKey? {
        guard providerAvailable, index > 0 else { return nil }
        return exhaustedSharedContextKey(
            upperGroupIndex: index - 1,
            groups: groups,
            snapshot: snapshot,
            expansion: expansion
        )
    }

    private static func sharedContextAfter(
        forGroupAt index: Int,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        expansion: DiffContextExpansionState,
        providerAvailable: Bool
    ) -> DiffContextExpansionKey? {
        guard providerAvailable, index + 1 < groups.count else { return nil }
        return exhaustedSharedContextKey(
            upperGroupIndex: index,
            groups: groups,
            snapshot: snapshot,
            expansion: expansion
        )
    }

    private static func exhaustedSharedContextKey(
        upperGroupIndex: Int,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        expansion: DiffContextExpansionState
    ) -> DiffContextExpansionKey? {
        guard upperGroupIndex + 1 < groups.count else { return nil }

        let upperGroup = groups[upperGroupIndex]
        let lowerGroup = groups[upperGroupIndex + 1]
        let key = DiffContextExpansionKey.shared(upperGroupID: upperGroup.id, lowerGroupID: lowerGroup.id)
        guard let snapshot else {
            return optimisticBoundaryAvailable(
                for: upperGroup,
                groupIndex: upperGroupIndex,
                boundary: .below,
                groups: groups
            ) ? nil : key
        }
        guard boundaryContextIsAvailable(for: upperGroup, boundary: .below, snapshot: snapshot) else {
            return nil
        }

        let available = boundaryRange(
            for: upperGroup,
            groupIndex: upperGroupIndex,
            boundary: .below,
            groups: groups,
            snapshot: snapshot
        ).lineCount
        return expansion.remainingLineCount(for: key, available: available) == 0 ? key : nil
    }

    static func availableLineCount(
        key: DiffContextExpansionKey,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?
    ) -> Int {
        guard let snapshot else {
            return 0
        }

        switch key.kind {
        case let .external(groupID, boundary):
            guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
                return 0
            }
            guard ownsBoundary(groupIndex: groupIndex, boundary: boundary) else {
                return 0
            }
            return boundaryRange(
                for: groups[groupIndex],
                groupIndex: groupIndex,
                boundary: boundary,
                groups: groups,
                snapshot: snapshot
            ).lineCount
        case let .shared(upperGroupID, lowerGroupID):
            guard
                let upperIndex = groups.firstIndex(where: { $0.id == upperGroupID }),
                upperIndex + 1 < groups.count,
                groups[upperIndex + 1].id == lowerGroupID
            else {
                return 0
            }
            return boundaryRange(
                for: groups[upperIndex],
                groupIndex: upperIndex,
                boundary: .below,
                groups: groups,
                snapshot: snapshot
            ).lineCount
        }
    }

    private static func sharedExpansionRows(
        upperGroup: DiffDisplayGroup,
        lowerGroup: DiffDisplayGroup,
        upperGroupIndex: Int,
        lowerGroupIndex: Int,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        expansion: DiffContextExpansionState,
        filePath: String,
        edge: DiffContextExpansionEdge
    ) -> [DiffDisplayRow] {
        let key = DiffContextExpansionKey.shared(upperGroupID: upperGroup.id, lowerGroupID: lowerGroup.id)
        let attachedGroup = edge == .top ? upperGroup : lowerGroup
        let attachedGroupIndex = edge == .top ? upperGroupIndex : lowerGroupIndex
        let attachedBoundary: DiffContextBoundary = edge == .top ? .below : .above

        guard let snapshot else {
            guard optimisticBoundaryAvailable(
                for: upperGroup,
                groupIndex: upperGroupIndex,
                boundary: .below,
                groups: groups
            ) else {
                return []
            }
            return [expandableRow(
                group: attachedGroup,
                boundary: attachedBoundary,
                remaining: 0,
                key: key,
                edge: edge
            )]
        }

        let range = boundaryRange(
            for: upperGroup,
            groupIndex: upperGroupIndex,
            boundary: .below,
            groups: groups,
            snapshot: snapshot
        )
        let available = range.lineCount
        guard available > 0 else {
            return []
        }

        let topExpanded = min(expansion.expandedLineCount(for: key, edge: .top), available)
        let bottomExpanded = min(
            expansion.expandedLineCount(for: key, edge: .bottom),
            max(0, available - topExpanded)
        )
        let expandedCount = edge == .top ? topExpanded : bottomExpanded
        let remaining = expansion.remainingLineCount(for: key, available: available)
        let offsets: Range<Int>
        switch edge {
        case .top:
            offsets = 0..<expandedCount
        case .bottom:
            offsets = (available - expandedCount)..<available
        }

        let excludedOldLineNumbers: Set<Int>
        let excludedNewLineNumbers: Set<Int>
        switch edge {
        case .top:
            excludedOldLineNumbers = []
            excludedNewLineNumbers = []
        case .bottom:
            let topOffsets = 0..<topExpanded
            excludedOldLineNumbers = lineNumbers(
                start: range.oldStart,
                count: range.oldCount,
                offsets: topOffsets,
                totalCount: available,
                boundary: .below
            )
            excludedNewLineNumbers = lineNumbers(
                start: range.newStart,
                count: range.newCount,
                offsets: topOffsets,
                totalCount: available,
                boundary: .below
            )
        }

        var rows = offsets.map {
            expandedContextRow(
                group: attachedGroup,
                groupIndex: attachedGroupIndex,
                boundary: attachedBoundary,
                range: range,
                offset: $0,
                totalCount: available,
                snapshot: snapshot,
                filePath: filePath,
                excludedOldLineNumbers: excludedOldLineNumbers,
                excludedNewLineNumbers: excludedNewLineNumbers
            )
        }

        guard remaining > 0 else {
            return rows
        }

        let expandable = expandableRow(
            group: attachedGroup,
            boundary: attachedBoundary,
            remaining: remaining,
            key: key,
            edge: edge
        )
        switch edge {
        case .top:
            rows.insert(expandable, at: rows.endIndex)
            rows.insert(
                expandableRow(
                    group: attachedGroup,
                    boundary: attachedBoundary,
                    remaining: remaining,
                    key: key,
                    edge: nil,
                    defaultsEdgeFromBoundary: false
                ),
                at: rows.endIndex
            )
        case .bottom:
            rows.insert(expandable, at: rows.startIndex)
        }
        return rows
    }

    private static func expansionRows(
        for group: DiffDisplayGroup,
        groupIndex: Int,
        boundary: DiffContextBoundary,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        expansion: DiffContextExpansionState,
        filePath: String,
        chunkSize: Int
    ) -> [DiffDisplayRow] {
        guard ownsBoundary(groupIndex: groupIndex, boundary: boundary) else {
            return []
        }
        guard let snapshot else {
            guard optimisticBoundaryAvailable(
                for: group,
                groupIndex: groupIndex,
                boundary: boundary,
                groups: groups
            ) else {
                return []
            }
            let key = DiffContextExpansionKey(groupID: group.id, boundary: boundary)
            return [expandableRow(group: group, boundary: boundary, remaining: 0, key: key)]
        }

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
            key: key
        )
        switch boundary {
        case .above:
            rows.insert(expandable, at: rows.startIndex)
        case .below:
            rows.insert(expandable, at: rows.endIndex)
        }
        return rows
    }

    private static func ownsBoundary(groupIndex: Int, boundary: DiffContextBoundary) -> Bool {
        switch boundary {
        case .above:
            groupIndex == 0
        case .below:
            true
        }
    }

    private static func optimisticBoundaryAvailable(
        for group: DiffDisplayGroup,
        groupIndex: Int,
        boundary: DiffContextBoundary,
        groups: [DiffDisplayGroup]
    ) -> Bool {
        let currentOld = hunkSideExtent(in: group, side: .old)
        let currentNew = hunkSideExtent(in: group, side: .new)

        switch boundary {
        case .above:
            let previous = groupIndex > 0 ? groups[groupIndex - 1] : nil
            guard let previous else {
                return currentOld.lineBefore > 0 || currentNew.lineBefore > 0
            }
            let previousOld = hunkSideExtent(in: previous, side: .old)
            let previousNew = hunkSideExtent(in: previous, side: .new)
            return optimisticLineCount(start: previousOld.lineAfter, end: currentOld.lineBefore) > 0
                || optimisticLineCount(start: previousNew.lineAfter, end: currentNew.lineBefore) > 0
        case .below:
            guard groupIndex + 1 < groups.count else {
                return true
            }
            let next = groups[groupIndex + 1]
            let nextOld = hunkSideExtent(in: next, side: .old)
            let nextNew = hunkSideExtent(in: next, side: .new)
            return optimisticLineCount(start: currentOld.lineAfter, end: nextOld.lineBefore) > 0
                || optimisticLineCount(start: currentNew.lineAfter, end: nextNew.lineBefore) > 0
        }
    }

    private static func optimisticLineCount(start: Int, end: Int) -> Int {
        guard start <= end else { return 0 }
        return end - start + 1
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
        let currentOld = hunkSideExtent(in: group, side: .old)
        let currentNew = hunkSideExtent(in: group, side: .new)
        let previousOld = previous.map { hunkSideExtent(in: $0, side: .old) }
        let previousNew = previous.map { hunkSideExtent(in: $0, side: .new) }
        let nextOld = next.map { hunkSideExtent(in: $0, side: .old) }
        let nextNew = next.map { hunkSideExtent(in: $0, side: .new) }

        switch boundary {
        case .above:
            let oldStart = previousOld?.lineAfter ?? 1
            let newStart = previousNew?.lineAfter ?? 1
            return BoundaryRange(
                oldStart: oldStart,
                oldCount: lineCount(
                    start: oldStart,
                    end: currentOld.lineBefore,
                    snapshotLines: snapshot.old.lineCount
                ),
                newStart: newStart,
                newCount: lineCount(
                    start: newStart,
                    end: currentNew.lineBefore,
                    snapshotLines: snapshot.new.lineCount
                )
            )
        case .below:
            let oldStart = currentOld.lineAfter
            let newStart = currentNew.lineAfter
            return BoundaryRange(
                oldStart: oldStart,
                oldCount: lineCount(
                    start: oldStart,
                    end: nextOld?.lineBefore ?? snapshot.old.lineCount,
                    snapshotLines: snapshot.old.lineCount
                ),
                newStart: newStart,
                newCount: lineCount(
                    start: newStart,
                    end: nextNew?.lineBefore ?? snapshot.new.lineCount,
                    snapshotLines: snapshot.new.lineCount
                )
            )
        }
    }

    private static func boundaryContextIsAvailable(
        for group: DiffDisplayGroup,
        boundary: DiffContextBoundary,
        snapshot: DiffReviewFileContextSnapshot
    ) -> Bool {
        let currentOld = hunkSideExtent(in: group, side: .old)
        let currentNew = hunkSideExtent(in: group, side: .new)

        switch boundary {
        case .above:
            return snapshot.old.hasLine(currentOld.lineBefore)
                || snapshot.new.hasLine(currentNew.lineBefore)
        case .below:
            return snapshot.old.hasLine(currentOld.lineAfter)
                || snapshot.new.hasLine(currentNew.lineAfter)
        }
    }

    private static func lineCount(start: Int, end: Int?, snapshotLines: Int?) -> Int {
        guard let snapshotLines, let end else { return 0 }
        let clampedStart = max(1, start)
        let clampedEnd = min(end, snapshotLines)
        guard clampedStart <= clampedEnd else { return 0 }
        return clampedEnd - clampedStart + 1
    }

    private static func lineNumbers(
        start: Int?,
        count: Int,
        offsets: Range<Int>,
        totalCount: Int,
        boundary: DiffContextBoundary
    ) -> Set<Int> {
        Set(offsets.compactMap {
            lineNumber(
                start: start,
                count: count,
                offset: $0,
                totalCount: totalCount,
                boundary: boundary
            )
        })
    }

    private static func hunkSideExtent(in group: DiffDisplayGroup, side: DiffLineSide) -> HunkSideExtent {
        let start = side == .old ? group.sourceHunk.oldStart : group.sourceHunk.newStart
        let count = group.sourceHunk.lines.reduce(0) { partial, line in
            partial + (lineConsumes(line, side: side) ? 1 : 0)
        }
        return HunkSideExtent(start: start, count: count)
    }

    private static func lineConsumes(_ line: ParsedDiff.Hunk.Line, side: DiffLineSide) -> Bool {
        switch (line.kind, side) {
        case (.context, .old), (.context, .new), (.delete, .old), (.add, .new):
            return true
        case (_, .paired), (.add, .old), (.delete, .new):
            return false
        }
    }

    private static func expandedContextRow(
        group: DiffDisplayGroup,
        groupIndex: Int,
        boundary: DiffContextBoundary,
        range: BoundaryRange,
        offset: Int,
        totalCount: Int,
        snapshot: DiffReviewFileContextSnapshot,
        filePath: String,
        excludedOldLineNumbers: Set<Int> = [],
        excludedNewLineNumbers: Set<Int> = []
    ) -> DiffDisplayRow {
        let candidateOldNumber = lineNumber(
            start: range.oldStart,
            count: range.oldCount,
            offset: offset,
            totalCount: totalCount,
            boundary: boundary
        )
        let candidateNewNumber = lineNumber(
            start: range.newStart,
            count: range.newCount,
            offset: offset,
            totalCount: totalCount,
            boundary: boundary
        )
        let oldNumber = candidateOldNumber.flatMap { excludedOldLineNumbers.contains($0) ? nil : $0 }
        let newNumber = candidateNewNumber.flatMap { excludedNewLineNumbers.contains($0) ? nil : $0 }
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
        edge: DiffContextExpansionEdge? = nil,
        defaultsEdgeFromBoundary: Bool = true
    ) -> DiffDisplayRow {
        let edgeID = edge.map { "-\($0.rawValue)" } ?? ""
        return DiffDisplayRow(
            id: "\(group.id)-expand-\(boundary.rawValue)\(edgeID)",
            kind: .expandableContext,
            old: nil,
            new: nil,
            collapsedLineCount: remaining,
            contextExpansion: DiffContextExpansionRow(
                key: key,
                boundary: boundary,
                remainingLineCount: remaining,
                edge: edge,
                defaultsEdgeFromBoundary: defaultsEdgeFromBoundary
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

    func hasLine(_ number: Int) -> Bool {
        guard let lineCount else { return false }
        return number >= 1 && number <= lineCount
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
