import Foundation

/// Pure precomputation of per-pane visual rows for the 3-way merge
/// editor. Given the parsed `regions` from `MergeConflictTabModel`,
/// produces one row array per pane. Side panes show their version of the
/// file contiguously (no padding rows); RESULT stacks LOCAL, optional
/// BASE, and REMOTE inside each conflict.
///
/// Panes have different lengths, so alignment is expressed through
/// `chunks`: corresponding row ranges in every pane. Scroll sync maps a
/// row across panes chunk by chunk, and the action gutters draw ribbons
/// between corresponding hunks using `conflictRanges`.
enum MergeRegionVisualLayout {
    struct VisualRow: Equatable {
        let content: String
        let sourceLineNumber: Int?

        var isPadding: Bool { sourceLineNumber == nil }
    }

    enum Pane: Hashable, CaseIterable {
        case local, result, remote
    }

    /// Where a RESULT row's text comes from. Lets RESULT reuse syntax
    /// highlighting computed on the coherent LOCAL / REMOTE / BASE versions
    /// instead of parsing the stacked buffer, which is not valid code.
    enum RowOrigin: Equatable {
        case local(Int)
        case base(Int)
        case remote(Int)
    }

    /// Corresponding rows in every pane. Shared text is one chunk with
    /// equal counts; a conflict is one chunk whose RESULT span covers the
    /// stacked LOCAL + BASE + REMOTE rows.
    struct Chunk: Equatable {
        let local: Range<Int>
        let result: Range<Int>
        let remote: Range<Int>

        func rows(in pane: Pane) -> Range<Int> {
            switch pane {
            case .local: local
            case .result: result
            case .remote: remote
            }
        }
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
        /// Shared text plus every conflict's BASE hunk, in file order. Only
        /// used for syntax highlighting BASE rows shown in RESULT.
        let base: [VisualRow]
        let resultOrigins: [RowOrigin]
        let chunks: [Chunk]
        let conflictRanges: [VisualConflictRange]

        func rows(in pane: Pane) -> [VisualRow] {
            switch pane {
            case .local: local
            case .result: result
            case .remote: remote
            }
        }

        /// Maps a fractional row position in `source` to the corresponding
        /// position in `target`. Inside a chunk the position is interpolated
        /// linearly, so panes stay aligned at chunk boundaries and scroll
        /// continuously through hunks of different heights.
        func mapRow(_ row: Double, from source: Pane, to target: Pane) -> Double {
            guard source != target, !chunks.isEmpty else { return row }
            for chunk in chunks {
                let from = chunk.rows(in: source)
                guard !from.isEmpty, row < Double(from.upperBound) else { continue }
                let to = chunk.rows(in: target)
                guard row >= Double(from.lowerBound) else {
                    // Before the first non-empty chunk in `source`.
                    return Double(to.lowerBound) - (Double(from.lowerBound) - row)
                }
                let fraction = (row - Double(from.lowerBound)) / Double(from.count)
                return Double(to.lowerBound) + fraction * Double(to.count)
            }
            let last = chunks[chunks.count - 1]
            return Double(last.rows(in: target).upperBound) + (row - Double(last.rows(in: source).upperBound))
        }
    }

    static func compute(regions: [ConflictRegion], showBase: Bool = false) -> Layout {
        var local: [VisualRow] = []
        var result: [VisualRow] = []
        var remote: [VisualRow] = []
        var base: [VisualRow] = []
        var resultOrigins: [RowOrigin] = []
        var chunks: [Chunk] = []
        var conflictRanges: [VisualConflictRange] = []
        var ordinal = 0
        for region in regions {
            let localStart = local.count
            let resultStart = result.count
            let remoteStart = remote.count
            switch region {
            case .text(let text):
                let lines = splitPreservingTrailingEmpty(text)
                guard !lines.isEmpty else { continue }
                for line in lines {
                    resultOrigins.append(.local(local.count))
                    local.append(.init(content: line, sourceLineNumber: local.count + 1))
                    result.append(.init(content: line, sourceLineNumber: result.count + 1))
                    remote.append(.init(content: line, sourceLineNumber: remote.count + 1))
                    base.append(.init(content: line, sourceLineNumber: base.count + 1))
                }
            case .conflict(let block):
                let localLines = splitPreservingTrailingEmpty(block.local)
                let allBaseLines = block.base.map(splitPreservingTrailingEmpty) ?? []
                let shownBaseLines = showBase ? allBaseLines : []
                let remoteLines = splitPreservingTrailingEmpty(block.remote)
                for line in localLines {
                    resultOrigins.append(.local(local.count))
                    local.append(.init(content: line, sourceLineNumber: local.count + 1))
                    result.append(.init(content: line, sourceLineNumber: nil))
                }
                let baseStart = base.count
                for line in allBaseLines {
                    base.append(.init(content: line, sourceLineNumber: base.count + 1))
                }
                for (index, line) in shownBaseLines.enumerated() {
                    resultOrigins.append(.base(baseStart + index))
                    result.append(.init(content: line, sourceLineNumber: nil))
                }
                for line in remoteLines {
                    resultOrigins.append(.remote(remote.count))
                    remote.append(.init(content: line, sourceLineNumber: remote.count + 1))
                    result.append(.init(content: line, sourceLineNumber: nil))
                }
                let localCount = localLines.count
                let baseCount = shownBaseLines.count
                conflictRanges.append(.init(
                    conflictOrdinal: ordinal,
                    localRows: localStart ..< local.count,
                    baseRows: (resultStart + localCount) ..< (resultStart + localCount + baseCount),
                    resultRows: resultStart ..< result.count,
                    resultLocalRows: resultStart ..< (resultStart + localCount),
                    resultRemoteRows: (resultStart + localCount + baseCount) ..< result.count,
                    remoteRows: remoteStart ..< remote.count
                ))
                ordinal += 1
            }
            chunks.append(Chunk(
                local: localStart ..< local.count,
                result: resultStart ..< result.count,
                remote: remoteStart ..< remote.count
            ))
        }
        return Layout(
            local: local,
            result: result,
            remote: remote,
            base: base,
            resultOrigins: resultOrigins,
            chunks: chunks,
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
