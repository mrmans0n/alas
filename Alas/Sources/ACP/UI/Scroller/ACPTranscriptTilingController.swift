import CoreGraphics

/// Single authority on transcript row placement for the AppKit scroller:
/// ordered rows, measured heights, cumulative y-offsets (flipped/top-down
/// coordinates), and total document height. Pure layout math — no AppKit —
/// so every behavior is unit-testable.
@MainActor
final class ACPTranscriptTilingController {
    struct Metrics: Equatable {
        var rowSpacing: CGFloat = 18
        var topPadding: CGFloat = 24
    }

    struct RowLayout: Equatable {
        let id: String
        var height: CGFloat
        var minY: CGFloat
        var maxY: CGFloat { minY + height }
    }

    private let metrics: Metrics
    private var rows: [RowLayout] = []
    private var indexById: [String: Int] = [:]
    private(set) var documentHeight: CGFloat = 0

    init(metrics: Metrics = Metrics()) {
        self.metrics = metrics
    }

    var rowCount: Int { rows.count }

    func row(withId id: String) -> RowLayout? {
        indexById[id].map { rows[$0] }
    }

    func rowLayout(at index: Int) -> RowLayout { rows[index] }
    func rowId(at index: Int) -> String { rows[index].id }
    func index(ofId id: String) -> Int? { indexById[id] }

    func replaceAll(rows newRows: [(id: String, height: CGFloat)]) {
        rows = newRows.map { RowLayout(id: $0.id, height: $0.height, minY: 0) }
        retile(from: 0)
        rebuildIndex()
    }

    /// Core insertion primitive shared by `prepend`, `append`, and the
    /// general `insert(rows:at:viewportMinY:)`. Returns three things a
    /// caller needs to decide compensation:
    ///   - `insertionY`: the pre-mutation `minY` of the row that will end up
    ///     right after the inserted block, using the same half-open
    ///     convention as `updateHeight` (or the pre-mutation `documentHeight`
    ///     when inserting at the end — `index == rows.count`).
    ///   - `hadExistingRows`: whether the controller held any rows before
    ///     this call. A first-ever populate (empty → N) has nothing to keep
    ///     visually still, so compensation must never apply to it even
    ///     though `insertionY` trivially equals `viewportMinY == 0` in that
    ///     case.
    ///   - `delta`: total height inserted (row heights + one spacing per row).
    private func insertCore(
        rows newRows: [(id: String, height: CGFloat)], at index: Int
    ) -> (insertionY: CGFloat, hadExistingRows: Bool, delta: CGFloat) {
        let hadExistingRows = !rows.isEmpty
        let insertionY = index < rows.count ? rows[index].minY : documentHeight
        guard !newRows.isEmpty else { return (insertionY, hadExistingRows, 0) }
        let delta = newRows.reduce(CGFloat(0)) { $0 + $1.height + metrics.rowSpacing }
        rows.insert(
            contentsOf: newRows.map { RowLayout(id: $0.id, height: $0.height, minY: 0) },
            at: index
        )
        retile(from: index)
        rebuildIndex()
        return (insertionY, hadExistingRows, delta)
    }

    /// Insert rows before the current first row. Returns the y-delta every
    /// pre-existing row moved down by — the exact amount the scroll offset
    /// must grow to keep the viewport visually still.
    func prepend(rows newRows: [(id: String, height: CGFloat)]) -> CGFloat {
        insertCore(rows: newRows, at: 0).delta
    }

    func append(rows newRows: [(id: String, height: CGFloat)]) {
        _ = insertCore(rows: newRows, at: rows.count)
    }

    /// Insert rows at an arbitrary index. Returns the scroll-offset
    /// compensation the caller must add to keep the viewport visually
    /// still: the inserted height iff there was existing content AND the
    /// insertion point lies at or above the current viewport top
    /// (`insertionY <= viewportMinY`), zero otherwise. Same half-open
    /// convention as `updateHeight`.
    func insert(
        rows newRows: [(id: String, height: CGFloat)], at index: Int, viewportMinY: CGFloat
    ) -> CGFloat {
        let clampedIndex = max(0, min(index, rows.count))
        let (insertionY, hadExistingRows, delta) = insertCore(rows: newRows, at: clampedIndex)
        return hadExistingRows && insertionY <= viewportMinY ? delta : 0
    }

    /// Remove `count` rows starting at `index`. Returns the scroll-offset
    /// compensation the caller must add to keep the viewport visually
    /// still: the negative removed height iff the removal point lies at or
    /// above the current viewport top (`removalY <= viewportMinY`), zero
    /// otherwise. Same half-open convention as `updateHeight` and `insert`.
    @discardableResult
    func remove(at index: Int, count: Int, viewportMinY: CGFloat) -> CGFloat {
        guard count > 0, index >= 0, index < rows.count else { return 0 }
        let upperBound = min(index + count, rows.count)
        let removalY = rows[index].minY
        let delta = rows[index..<upperBound].reduce(CGFloat(0)) { $0 + $1.height + metrics.rowSpacing }
        rows.removeSubrange(index..<upperBound)
        retile(from: index)
        rebuildIndex()
        return removalY <= viewportMinY ? -delta : 0
    }

    func removeSuffix(from index: Int) {
        guard index < rows.count else { return }
        rows.removeSubrange(index...)
        retile(from: index)
        rebuildIndex()
    }

    /// Apply a re-measured height. Returns the scroll-offset compensation the
    /// caller must add to keep the viewport visually still: non-zero only when
    /// the row lies entirely above the viewport top (its resize would otherwise
    /// push/pull everything the user is looking at).
    ///
    /// Height changes never alter row identity or order, so this does not call
    /// `rebuildIndex()` — that would be wasted work re-deriving an id → index
    /// map that hasn't changed.
    func updateHeight(id: String, to height: CGFloat, viewportMinY: CGFloat) -> CGFloat {
        guard let index = indexById[id] else { return 0 }
        let old = rows[index]
        guard old.height != height else { return 0 }
        let delta = height - old.height
        // A row's extent is the half-open range [minY, maxY): it occupies
        // every y up to, but not including, maxY. When old.maxY <= viewportMinY,
        // none of the row's pixels are at or past the viewport's top edge, so
        // it is entirely above the viewport (not merely "at" the boundary) and
        // its resize must be compensated to keep the visible content still.
        let isEntirelyAboveViewport = old.maxY <= viewportMinY
        rows[index].height = height
        retile(from: index)
        return isEntirelyAboveViewport ? delta : 0
    }

    /// Recompute minY for rows[from...] and the document height.
    private func retile(from index: Int) {
        var y: CGFloat
        if index == 0 {
            y = metrics.topPadding
        } else {
            let prev = rows[index - 1]
            y = prev.maxY + metrics.rowSpacing
        }
        for i in index..<rows.count {
            rows[i].minY = y
            y = rows[i].maxY + metrics.rowSpacing
        }
        documentHeight = rows.last?.maxY ?? 0
    }

    /// Binary search: index of the first row whose bottom edge is below `y`
    /// (i.e. the row occupying or first following that y-line). Nil when empty
    /// or `y` is past the last row.
    ///
    /// Uses the same half-open-interval convention as `updateHeight`: a row
    /// whose `maxY` exactly equals `y` is treated as entirely above `y`, not
    /// intersecting it, so the search requires `maxY > y` (strict).
    func firstRowIndex(intersectingY y: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        var lo = 0, hi = rows.count - 1
        guard rows[hi].maxY > y else { return nil }
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].maxY > y { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// The id of the topmost row intersecting the viewport top, used to
    /// remember the user's scroll position across sessions.
    func topVisibleRowId(viewportMinY: CGFloat) -> String? {
        firstRowIndex(intersectingY: viewportMinY).map { rows[$0].id }
    }

    /// Like `topVisibleRowId`, but walks forward over synthetic rows (the
    /// head pagination spinner, queued prompts, the composer spacer) to the
    /// first real message row at or below the viewport top.
    ///
    /// A remembered anchor names a message, so a synthetic id is not a usable
    /// answer — but neither is giving up. Scrolling to the top of a paginated
    /// transcript puts the pagination spinner at the viewport top, and simply
    /// discarding that update leaves a paused session with no anchor at all,
    /// which restoration then resolves as "go to the bottom". Returns nil
    /// only when every remaining row is synthetic, i.e. the viewport top is
    /// already inside the synthetic tail and there is no message below it to
    /// name.
    func firstNonSyntheticRowId(
        atOrBelow viewportMinY: CGFloat, syntheticIdPrefix: String
    ) -> String? {
        guard var index = firstRowIndex(intersectingY: viewportMinY) else { return nil }
        while index < rows.count, rows[index].id.hasPrefix(syntheticIdPrefix) {
            index += 1
        }
        guard index < rows.count else { return nil }
        return rows[index].id
    }

    /// Indices of rows that should have live hosting views: everything
    /// intersecting the viewport extended by `overscan` on both sides. Rows
    /// outside this range keep their measured heights but have no mounted
    /// view, bounding memory as the render window grows.
    func mountBand(viewportMinY: CGFloat, viewportHeight: CGFloat, overscan: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let lowY = viewportMinY - overscan
        let highY = viewportMinY + viewportHeight + overscan
        let first = firstRowIndex(intersectingY: lowY) ?? rows.count
        guard first < rows.count else { return rows.count..<rows.count }
        var last = first
        while last + 1 < rows.count, rows[last + 1].minY < highY {
            last += 1
        }
        return first..<(last + 1)
    }

    /// Rebuilds the id → index lookup, tolerating duplicate row ids rather
    /// than trapping (as `Dictionary(uniqueKeysWithValues:)` would). Duplicate
    /// ids should never happen, but this controller drives the live
    /// transcript in the user's daily-driver app: the legacy SwiftUI
    /// `ForEach` path merely degrades (collapses/misrenders rows) on
    /// duplicate ids, so a hard trap here would be a strictly harsher
    /// regression than silently keeping the last occurrence. The
    /// `assertionFailure` still makes the condition loud during development
    /// while staying safe in release.
    private func rebuildIndex() {
        indexById.removeAll(keepingCapacity: true)
        for (offset, row) in rows.enumerated() {
            if indexById[row.id] != nil {
                assertionFailure("duplicate row id \(row.id)")
            }
            indexById[row.id] = offset
        }
    }
}
