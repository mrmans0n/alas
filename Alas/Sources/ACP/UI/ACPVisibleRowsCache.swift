import Foundation

/// Non-observed memo for the window-sliced row list + id lookup. Keyed on
/// (messages generation, window bounds, tool-call grouping options,
/// tool-call expansion generation); geometry callbacks hit this once per
/// layout pass instead of rebuilding an O(rows) dictionary per row.
/// See docs/plans/2026-07-17-acp-transcript-livelock-fix.md (Task 2).
@MainActor
final class ACPVisibleRowsCache {
    private struct Key: Equatable {
        let generation: UInt64
        let head: Int
        let tail: Int
        let grouping: ACPToolCallGrouping.Options
        /// Expanding a bundle replaces its single row with a header plus
        /// one row per member, so the folded list itself changes — see
        /// `ACPToolCallGroupExpansionSeeds.generation`.
        let expansion: UInt64
    }
    private var key: Key?
    private var rows: [ACPTranscriptRenderRow] = []
    private var lookup: ACPTranscriptVisibleRowLookup?

    func rows(
        generation: UInt64, head: Int, tail: Int,
        grouping: ACPToolCallGrouping.Options = .disabled,
        expansion: UInt64 = 0,
        build: () -> [ACPTranscriptRenderRow]
    ) -> [ACPTranscriptRenderRow] {
        let k = Key(generation: generation, head: head, tail: tail, grouping: grouping, expansion: expansion)
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
        expansion: UInt64 = 0,
        build: () -> [ACPTranscriptRenderRow]
    ) -> ACPTranscriptVisibleRowLookup {
        let r = rows(
            generation: generation, head: head, tail: tail,
            grouping: grouping, expansion: expansion, build: build
        )
        if let lookup { return lookup }
        let l = ACPTranscriptVisibleRowLookup(rows: r)
        lookup = l
        return l
    }
}
