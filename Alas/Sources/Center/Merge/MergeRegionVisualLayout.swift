import Foundation

/// Pure precomputation of per-pane visual rows for the 3-way merge
/// editor. Given the parsed `regions` from `MergeConflictTabModel`,
/// produces three same-length arrays (one per pane) where each row is
/// either a real source line or a blank padding row used to keep
/// corresponding conflict hunks vertically aligned across the panes.
///
/// Also emits per-conflict `VisualConflictRange` entries that the two
/// action gutters use to position their accept/reject glyphs + diagonal
/// SVG paths.
enum MergeRegionVisualLayout {
    struct VisualRow: Equatable {
        let content: String
        let sourceLineNumber: Int?

        var isPadding: Bool { sourceLineNumber == nil }
    }

    struct VisualConflictRange: Equatable {
        let conflictOrdinal: Int
        let localRows: Range<Int>
        let baseRows: Range<Int>
        let resultRows: Range<Int>
        let resultLocalRows: Range<Int>
        let resultRemoteRows: Range<Int>
        let remoteRows: Range<Int>
    }

    struct Layout: Equatable {
        let local: [VisualRow]
        let result: [VisualRow]
        let remote: [VisualRow]
        let conflictRanges: [VisualConflictRange]
    }

    static func compute(regions: [ConflictRegion], showBase: Bool = false) -> Layout {
        var local: [VisualRow] = []
        var result: [VisualRow] = []
        var remote: [VisualRow] = []
        var conflictRanges: [VisualConflictRange] = []
        var localLine = 1
        var resultLine = 1
        var remoteLine = 1
        var ordinal = 0
        for region in regions {
            switch region {
            case .text(let text):
                for line in splitPreservingTrailingEmpty(text) {
                    local.append(.init(content: line, sourceLineNumber: localLine))
                    result.append(.init(content: line, sourceLineNumber: resultLine))
                    remote.append(.init(content: line, sourceLineNumber: remoteLine))
                    localLine += 1
                    resultLine += 1
                    remoteLine += 1
                }
            case .conflict(let block):
                let localLines = splitPreservingTrailingEmpty(block.local)
                let baseLines = (showBase && block.base != nil)
                    ? splitPreservingTrailingEmpty(block.base!) : []
                let remoteLines = splitPreservingTrailingEmpty(block.remote)
                let localStart = local.count
                let remoteStart = remote.count
                let resultStart = result.count

                // LOCAL pane: real local rows, then padding for BASE + REMOTE rows
                for line in localLines {
                    local.append(.init(content: line, sourceLineNumber: localLine))
                    localLine += 1
                }
                for _ in 0 ..< (baseLines.count + remoteLines.count) {
                    local.append(.init(content: "", sourceLineNumber: nil))
                }
                // REMOTE pane: padding for LOCAL + BASE rows, then real remote rows
                for _ in 0 ..< (localLines.count + baseLines.count) {
                    remote.append(.init(content: "", sourceLineNumber: nil))
                }
                for line in remoteLines {
                    remote.append(.init(content: line, sourceLineNumber: remoteLine))
                    remoteLine += 1
                }
                // RESULT pane: LOCAL hunk + BASE hunk (if showBase) + REMOTE hunk
                for line in localLines {
                    result.append(.init(content: line, sourceLineNumber: nil))
                }
                for line in baseLines {
                    result.append(.init(content: line, sourceLineNumber: nil))
                }
                for line in remoteLines {
                    result.append(.init(content: line, sourceLineNumber: nil))
                }
                let localCount = localLines.count
                let baseCount = baseLines.count
                let remoteCount = remoteLines.count
                conflictRanges.append(.init(
                    conflictOrdinal: ordinal,
                    localRows: localStart ..< (localStart + localCount),
                    baseRows: (resultStart + localCount) ..< (resultStart + localCount + baseCount),
                    resultRows: resultStart ..< (resultStart + localCount + baseCount + remoteCount),
                    resultLocalRows: resultStart ..< (resultStart + localCount),
                    resultRemoteRows: (resultStart + localCount + baseCount) ..< (resultStart + localCount + baseCount + remoteCount),
                    remoteRows: (remoteStart + localCount + baseCount) ..< (remoteStart + localCount + baseCount + remoteCount)
                ))
                ordinal += 1
            }
        }
        return Layout(
            local: local,
            result: result,
            remote: remote,
            conflictRanges: conflictRanges
        )
    }

    private static func splitPreservingTrailingEmpty(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var parts = s.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
