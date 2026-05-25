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
        let resultRows: Range<Int>
        let remoteRows: Range<Int>
    }

    struct Layout: Equatable {
        let local: [VisualRow]
        let result: [VisualRow]
        let remote: [VisualRow]
        let conflictRanges: [VisualConflictRange]
    }

    static func compute(regions: [ConflictRegion]) -> Layout {
        var local: [VisualRow] = []
        var result: [VisualRow] = []
        var remote: [VisualRow] = []
        var conflictRanges: [VisualConflictRange] = []
        var localLine = 1
        var remoteLine = 1
        var resultLine = 1
        var ordinal = 0
        for region in regions {
            switch region {
            case .text(let text):
                for line in splitPreservingTrailingEmpty(text) {
                    local.append(.init(content: line, sourceLineNumber: localLine))
                    result.append(.init(content: line, sourceLineNumber: resultLine))
                    remote.append(.init(content: line, sourceLineNumber: remoteLine))
                    localLine += 1
                    remoteLine += 1
                    resultLine += 1
                }
            case .conflict(let block):
                let localLines = splitPreservingTrailingEmpty(block.local)
                let remoteLines = splitPreservingTrailingEmpty(block.remote)
                let localStart = local.count
                let remoteStart = remote.count
                let resultStart = result.count
                for line in localLines {
                    local.append(.init(content: line, sourceLineNumber: localLine))
                    localLine += 1
                }
                for _ in 0 ..< remoteLines.count {
                    local.append(.init(content: "", sourceLineNumber: nil))
                }
                for _ in 0 ..< localLines.count {
                    remote.append(.init(content: "", sourceLineNumber: nil))
                }
                for line in remoteLines {
                    remote.append(.init(content: line, sourceLineNumber: remoteLine))
                    remoteLine += 1
                }
                for line in localLines {
                    result.append(.init(content: line, sourceLineNumber: nil))
                }
                for line in remoteLines {
                    result.append(.init(content: line, sourceLineNumber: nil))
                }
                let localCount = localLines.count
                let remoteCount = remoteLines.count
                conflictRanges.append(.init(
                    conflictOrdinal: ordinal,
                    localRows: localStart ..< (localStart + localCount),
                    resultRows: resultStart ..< (resultStart + localCount + remoteCount),
                    remoteRows: (remoteStart + localCount) ..< (remoteStart + localCount + remoteCount)
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
