import Foundation

struct DiffReviewLineAnchor: Equatable, Hashable, Sendable {
    struct SelectedLine: Equatable, Hashable, Sendable {
        let side: DiffReviewInlineFeedbackSide
        let line: Int
        let isChange: Bool
    }

    let path: String
    let side: DiffReviewInlineFeedbackSide
    let line: Int
    let endLine: Int?
    let rowIndex: Int
    let endRowIndex: Int
    let selectedLines: [SelectedLine]
    let selectedText: String

    init(
        path: String,
        side: DiffReviewInlineFeedbackSide,
        line: Int,
        endLine: Int? = nil,
        rowIndex: Int,
        endRowIndex: Int? = nil,
        selectedLines: [SelectedLine]? = nil,
        selectedText: String
    ) {
        self.path = path
        self.side = side
        self.line = line
        self.endLine = endLine
        self.rowIndex = rowIndex
        self.endRowIndex = endRowIndex ?? rowIndex
        self.selectedLines = selectedLines ?? [
            SelectedLine(side: side, line: line, isChange: side != .unknown),
        ]
        self.selectedText = selectedText
    }
}
