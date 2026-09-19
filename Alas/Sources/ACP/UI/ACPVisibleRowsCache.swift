import Foundation

/// Non-observed memo for the window-sliced row list + id lookup. Keyed on
/// (messages generation, window bounds, tool-call grouping options);
/// geometry callbacks hit this once per layout pass instead of rebuilding an
/// O(rows) dictionary per row.
/// See docs/plans/2026-07-17-acp-transcript-livelock-fix.md (Task 2).
@MainActor
final class ACPVisibleRowsCache {
    private struct Key: Equatable {
        let generation: UInt64
        let head: Int
        let tail: Int
        let grouping: ACPToolCallGrouping.Options
    }
    private var key: Key?
    private var rows: [ACPTranscriptRenderRow] = []
    private var lookup: ACPTranscriptVisibleRowLookup?

    func rows(
        generation: UInt64, head: Int, tail: Int,
        grouping: ACPToolCallGrouping.Options = .disabled,
        build: () -> [ACPTranscriptRenderRow]
    ) -> [ACPTranscriptRenderRow] {
        let k = Key(generation: generation, head: head, tail: tail, grouping: grouping)
        if key != k {
            rows = build()
            lookup = nil
            key = k
        }
        return rows
    }

    func lookup(
        generation: UInt64, head: Int, tail: Int,
        grouping: ACPToolCallGrouping.Options = .disabled,
        build: () -> [ACPTranscriptRenderRow]
    ) -> ACPTranscriptVisibleRowLookup {
        let r = rows(generation: generation, head: head, tail: tail, grouping: grouping, build: build)
        if let lookup { return lookup }
        let l = ACPTranscriptVisibleRowLookup(rows: r)
        lookup = l
        return l
    }
}
