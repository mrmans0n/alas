import Foundation
import Observation

/// Syntax highlighting for the 3-way merge editor. Parses the LOCAL,
/// REMOTE, and BASE versions of the file (each one coherent code) off the
/// main actor and exposes the result per row, so every pane — including
/// RESULT, whose stacked hunks are not valid code on their own — gets the
/// same colors for the same line.
///
/// While a fresh parse is pending, rows whose text was already highlighted
/// reuse those spans, so typing and accepting hunks don't flash plain text.
@MainActor
@Observable
final class MergeSyntaxHighlighter {
    /// A highlight span relative to the start of its line, in UTF-16 units.
    struct LineSpan: Equatable, Sendable {
        let location: Int
        let length: Int
        let capture: HighlightCapture
    }

    struct Input: Equatable, Sendable {
        let local: [String]
        let remote: [String]
        let base: [String]
        let fileExtension: String
    }

    private struct Snapshot {
        var rows: [MergeRegionVisualLayout.Pane?: [String]] = [:]
        var lines: [MergeRegionVisualLayout.Pane?: [[LineSpan]]] = [:]
    }

    /// Bumped whenever a parse lands. Views read it to re-render.
    private(set) var revision = 0

    @ObservationIgnored private var snapshot = Snapshot()
    @ObservationIgnored private var spansByContent: [String: [LineSpan]] = [:]
    @ObservationIgnored private var lastInput: Input?

    var hasResults: Bool { revision > 0 }

    /// Parses `input` unless it was already parsed. Runs the tree-sitter
    /// work on a background task; cancellation drops the result.
    func update(_ input: Input) async {
        guard input != lastInput else { return }
        let parsed = await Task.detached(priority: .userInitiated) {
            (
                local: Self.lineSpans(rows: input.local, fileExtension: input.fileExtension),
                remote: Self.lineSpans(rows: input.remote, fileExtension: input.fileExtension),
                base: input.base.isEmpty ? [] : Self.lineSpans(rows: input.base, fileExtension: input.fileExtension)
            )
        }.value
        guard !Task.isCancelled else { return }
        lastInput = input
        var next = Snapshot()
        next.rows[.local] = input.local
        next.rows[.remote] = input.remote
        next.rows[nil] = input.base
        next.lines[.local] = parsed.local
        next.lines[.remote] = parsed.remote
        next.lines[nil] = parsed.base
        snapshot = next
        var byContent: [String: [LineSpan]] = [:]
        for (rows, lines) in [(input.local, parsed.local), (input.remote, parsed.remote), (input.base, parsed.base)] {
            for (row, spans) in zip(rows, lines) where byContent[row] == nil {
                byContent[row] = spans
            }
        }
        spansByContent = byContent
        revision += 1
    }

    /// Line spans for a side pane (`.local` / `.remote`) or the BASE
    /// projection (`nil`). Exact when `rows` match the last parse;
    /// otherwise each row reuses the spans of an identical line.
    func lines(for rows: [String], pane: MergeRegionVisualLayout.Pane?) -> [[LineSpan]] {
        if let parsedRows = snapshot.rows[pane], parsedRows == rows, let lines = snapshot.lines[pane] {
            return lines
        }
        return rows.map { spansByContent[$0] ?? [] }
    }

    /// RESULT rows borrow the spans of the row they were copied from.
    static func resultLines(
        origins: [MergeRegionVisualLayout.RowOrigin],
        local: [[LineSpan]],
        remote: [[LineSpan]],
        base: [[LineSpan]]
    ) -> [[LineSpan]] {
        origins.map { origin in
            switch origin {
            case .local(let row): row < local.count ? local[row] : []
            case .remote(let row): row < remote.count ? remote[row] : []
            case .base(let row): row < base.count ? base[row] : []
            }
        }
    }

    nonisolated static func lineSpans(rows: [String], fileExtension: String) -> [[LineSpan]] {
        guard !rows.isEmpty else { return [] }
        let source = rows.joined(separator: "\n") + "\n"
        let spans = TreeSitterHighlighter.highlight(source: source, fileExtension: fileExtension)
        return split(spans, lineLengths: rows.map { ($0 as NSString).length })
    }

    /// Splits whole-document spans into per-line spans. Spans crossing a
    /// newline (block comments, multi-line strings) are clipped per line.
    nonisolated static func split(_ spans: [HighlightSpan], lineLengths: [Int]) -> [[LineSpan]] {
        var starts: [Int] = []
        starts.reserveCapacity(lineLengths.count)
        var location = 0
        for length in lineLengths {
            starts.append(location)
            location += length + 1
        }
        var lines = Array(repeating: [LineSpan](), count: lineLengths.count)
        for span in spans where span.capture != .plain && span.range.length > 0 {
            let spanEnd = NSMaxRange(span.range)
            var line = lineIndex(containing: span.range.location, starts: starts)
            while line < lineLengths.count, starts[line] < spanEnd {
                let lineStart = starts[line]
                let lower = max(span.range.location, lineStart)
                let upper = min(spanEnd, lineStart + lineLengths[line])
                if upper > lower {
                    lines[line].append(LineSpan(location: lower - lineStart, length: upper - lower, capture: span.capture))
                }
                line += 1
            }
        }
        return lines
    }

    private nonisolated static func lineIndex(containing location: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
