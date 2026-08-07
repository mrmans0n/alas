import Foundation

/// Non-observed memo for the window-sliced row list + id lookup. Keyed on
/// (messages generation, window bounds); geometry callbacks hit this once
/// per layout pass instead of rebuilding an O(rows) dictionary per row.
/// See docs/plans/2026-07-17-acp-transcript-livelock-fix.md (Task 2).
@MainActor
final class ACPVisibleRowsCache {
    private struct Key: Equatable {
        let generation: UInt64
        let head: Int
        let tail: Int
    }
    private var key: Key?
    private var rows: [ACPTranscriptVisibleRow] = []
    private var lookup: ACPMessageList.VisibleMessageLookup?

    func rows(
        generation: UInt64, head: Int, tail: Int,
        build: () -> [ACPTranscriptVisibleRow]
    ) -> [ACPTranscriptVisibleRow] {
        let k = Key(generation: generation, head: head, tail: tail)
        if key != k {
            rows = build()
            lookup = nil
            key = k
        }
        return rows
    }

    func lookup(
        generation: UInt64, head: Int, tail: Int,
        build: () -> [ACPTranscriptVisibleRow]
    ) -> ACPMessageList.VisibleMessageLookup {
        let r = rows(generation: generation, head: head, tail: tail, build: build)
        if let lookup { return lookup }
        let l = ACPMessageList.visibleMessageLookup(rows: r.map { ($0.index, $0.stableId) })
        lookup = l
        return l
    }
}
