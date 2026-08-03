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

    /// Insert rows before the current first row. Returns the y-delta every
    /// pre-existing row moved down by — the exact amount the scroll offset
    /// must grow to keep the viewport visually still.
    func prepend(rows newRows: [(id: String, height: CGFloat)]) -> CGFloat {
        guard !newRows.isEmpty else { return 0 }
        let delta = newRows.reduce(CGFloat(0)) { $0 + $1.height + metrics.rowSpacing }
        rows.insert(
            contentsOf: newRows.map { RowLayout(id: $0.id, height: $0.height, minY: 0) },
            at: 0
        )
        retile(from: 0)
        rebuildIndex()
        return delta
    }

    func append(rows newRows: [(id: String, height: CGFloat)]) {
        guard !newRows.isEmpty else { return }
        let firstNewIndex = rows.count
        rows.append(
            contentsOf: newRows.map { RowLayout(id: $0.id, height: $0.height, minY: 0) }
        )
        retile(from: firstNewIndex)
        rebuildIndex()
    }

    func removeSuffix(from index: Int) {
        guard index < rows.count else { return }
        rows.removeSubrange(index...)
        retile(from: index)
        rebuildIndex()
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

    private func rebuildIndex() {
        indexById = Dictionary(
            uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) }
        )
    }
}
