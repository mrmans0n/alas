import CoreGraphics

/// Pure row-placement and viewport geometry for the AppKit diff scroller.
@MainActor
final class AppKitDiffTilingController {
    struct Metrics: Equatable {
        var rowSpacing: CGFloat = 0
        var topPadding: CGFloat = 0
        var bottomPadding: CGFloat = 0
    }

    struct Seed {
        let id: String
        let ownerID: String?
        let height: CGFloat
    }

    struct RowLayout: Equatable {
        let id: String
        let ownerID: String?
        var height: CGFloat
        var minY: CGFloat

        var maxY: CGFloat { minY + height }
    }

    private var metrics: Metrics
    private var rows: [RowLayout] = []
    private var indexByID: [String: Int] = [:]

    private(set) var documentHeight: CGFloat = 0

    init(metrics: Metrics = Metrics()) {
        self.metrics = metrics
    }

    var rowCount: Int { rows.count }

    func replaceAll(rows newRows: [Seed], metrics newMetrics: Metrics? = nil) {
        if let newMetrics {
            metrics = newMetrics
        }
        rows = newRows.map { .init(id: $0.id, ownerID: $0.ownerID, height: $0.height, minY: 0) }
        retile()
        rebuildIndex()
    }

    func row(withID id: String) -> RowLayout? {
        index(ofID: id).map { rows[$0] }
    }

    func index(ofID id: String) -> Int? {
        indexByID[id]
    }

    func updateHeight(id: String, to height: CGFloat, viewportMinY: CGFloat) -> CGFloat {
        guard let index = index(ofID: id), rows[index].height != height else { return 0 }
        let old = rows[index]
        let delta = height - old.height
        rows[index].height = height
        retile()
        return old.maxY <= viewportMinY ? delta : 0
    }

    func anchor(viewportMinY: CGFloat) -> AppKitDiffScrollAnchor? {
        guard let index = firstRowIndex(intersectingY: viewportMinY) else { return nil }
        let row = rows[index]
        return .init(rowID: row.id, intraRowOffset: viewportMinY - row.minY)
    }

    func viewportMinY(for anchor: AppKitDiffScrollAnchor?) -> CGFloat? {
        guard let anchor, let row = row(withID: anchor.rowID) else { return nil }
        let intraRowOffset = min(max(0, anchor.intraRowOffset), row.height)
        return min(max(0, row.minY + intraRowOffset), documentHeight)
    }

    func mountBand(viewportMinY: CGFloat, viewportHeight: CGFloat, overscan: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let lowY = viewportMinY - overscan
        let highY = viewportMinY + viewportHeight + overscan
        guard let first = firstRowIndex(intersectingRangeFrom: lowY, to: highY) else {
            let emptyIndex = firstRowIndex(afterY: lowY) ?? rows.count
            return emptyIndex..<emptyIndex
        }

        var upperBound = first + 1
        while upperBound < rows.count, rows[upperBound].minY < highY {
            upperBound += 1
        }
        return first..<upperBound
    }

    func activeOwnerID(viewportMinY: CGFloat, viewportHeight: CGFloat) -> String? {
        guard viewportHeight > 0, let index = firstRowIndex(intersectingY: viewportMinY) else { return nil }
        return rows[index].ownerID
    }

    func targetOffset(id: String, alignment: AppKitDiffScrollAlignment, viewportHeight: CGFloat) -> CGFloat? {
        guard let row = row(withID: id) else { return nil }
        let desired: CGFloat
        switch alignment {
        case .top:
            desired = row.minY
        case .center:
            desired = row.minY - (viewportHeight - row.height) / 2
        }
        return min(max(0, desired), max(0, documentHeight - viewportHeight))
    }

    /// Returns the row containing `y` under the half-open interval convention.
    private func firstRowIndex(intersectingY y: CGFloat) -> Int? {
        guard let index = firstRowIndex(afterY: y), rows[index].minY <= y else { return nil }
        return index
    }

    /// Returns the first row that intersects the half-open range `[lowY, highY)`.
    private func firstRowIndex(intersectingRangeFrom lowY: CGFloat, to highY: CGFloat) -> Int? {
        guard lowY < highY, let index = firstRowIndex(afterY: lowY), rows[index].minY < highY else {
            return nil
        }
        return index
    }

    /// Binary-searches for the first row with a bottom edge strictly after `y`.
    /// The result may be a later row when `y` lies in padding or spacing; callers
    /// that need an actual intersection must verify the corresponding min edge.
    private func firstRowIndex(afterY y: CGFloat) -> Int? {
        guard let last = rows.indices.last, rows[last].maxY > y else { return nil }
        var lower = 0
        var upper = last
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].maxY > y {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }

    private func retile() {
        var y = metrics.topPadding
        for index in rows.indices {
            rows[index].minY = y
            y = rows[index].maxY + metrics.rowSpacing
        }
        documentHeight = rows.isEmpty ? 0 : rows[rows.count - 1].maxY + metrics.bottomPadding
    }

    private func rebuildIndex() {
        var assertedIDs = Set<String>()
        for row in rows {
            assert(assertedIDs.insert(row.id).inserted, "duplicate AppKit diff row id \(row.id)")
        }
        indexByID = Self.lastIndexByID(for: rows.map(\.id))
    }

    static func lastIndexByID(for rowIDs: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, id) in rowIDs.enumerated() {
            result[id] = index
        }
        return result
    }
}
