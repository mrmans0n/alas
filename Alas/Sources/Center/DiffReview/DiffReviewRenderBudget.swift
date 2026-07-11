import Foundation

/// Per-file render budget for the diff review surface.
///
/// A file whose post-collapse display model exceeds `maxRenderedRows` is not
/// auto-rendered; its section shows a placeholder with a "Show full diff"
/// action instead. This bounds the pathological case — a huge generated file,
/// frequently a single add/delete hunk — that would otherwise build one
/// enormous `NSTextView` document the moment it scrolls into view.
enum DiffReviewRenderBudget {
    /// Comfortably above any hand-authored file, well below the pathological range.
    static let maxRenderedRows = 20_000

    /// Total post-collapse rows across all hunks. A collapsed context run counts
    /// as the single row that represents it, matching what the view renders.
    static func renderedRowCount(of model: DiffDisplayModel) -> Int {
        model.groups.reduce(0) { $0 + $1.rows.count }
    }

    static func isOverBudget(rowCount: Int) -> Bool {
        rowCount > maxRenderedRows
    }

    static func isOverBudget(_ model: DiffDisplayModel) -> Bool {
        isOverBudget(rowCount: renderedRowCount(of: model))
    }
}
