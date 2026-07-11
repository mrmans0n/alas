import Testing
@testable import Alas

struct DiffReviewRenderBudgetTests {
    private func addOnlyModel(lineCount: Int) -> DiffDisplayModel {
        let lines = (1...lineCount).map {
            ParsedDiff.Hunk.Line(kind: .add, text: "let v\($0) = \($0)", oldNumber: nil, newNumber: $0)
        }
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(header: "@@ -0,0 +1,\(lineCount) @@", oldStart: 0, newStart: 1, lines: lines)
        ])
        return DiffDisplayModelBuilder.build(diff: diff, filePath: "a.swift")
    }

    /// A single hunk that is entirely unchanged context, long enough to trigger
    /// the builder's context-run collapse (default threshold 12, edge count 3).
    private func contextOnlyModel(lineCount: Int) -> DiffDisplayModel {
        let lines = (1...lineCount).map {
            ParsedDiff.Hunk.Line(kind: .context, text: "let v\($0) = \($0)", oldNumber: $0, newNumber: $0)
        }
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(header: "@@ -1,\(lineCount) +1,\(lineCount) @@", oldStart: 1, newStart: 1, lines: lines)
        ])
        return DiffDisplayModelBuilder.build(diff: diff, filePath: "a.swift")
    }

    @Test func countsPostCollapseRowsAcrossGroups() {
        let model = addOnlyModel(lineCount: 3)
        #expect(DiffReviewRenderBudget.renderedRowCount(of: model) == 3)
    }

    @Test func collapsedContextRunCountsAsOneRow() {
        // 40 unchanged lines collapse to: 3 edge + 1 collapsed + 3 edge = 7 rows.
        let model = contextOnlyModel(lineCount: 40)
        let count = DiffReviewRenderBudget.renderedRowCount(of: model)
        #expect(count == 7)
        #expect(count < 40)
    }

    @Test func rowCountAtCapIsNotOverBudget() {
        #expect(DiffReviewRenderBudget.isOverBudget(rowCount: DiffReviewRenderBudget.maxRenderedRows) == false)
    }

    @Test func rowCountAboveCapIsOverBudget() {
        #expect(DiffReviewRenderBudget.isOverBudget(rowCount: DiffReviewRenderBudget.maxRenderedRows + 1) == true)
    }

    @Test func smallRowCountIsNotOverBudget() {
        #expect(DiffReviewRenderBudget.isOverBudget(rowCount: 10) == false)
    }

    @Test func smallModelIsNotOverBudget() {
        #expect(DiffReviewRenderBudget.isOverBudget(addOnlyModel(lineCount: 5)) == false)
    }

    @Test func modelAboveCapIsOverBudget() {
        let model = addOnlyModel(lineCount: DiffReviewRenderBudget.maxRenderedRows + 1)
        #expect(DiffReviewRenderBudget.isOverBudget(model) == true)
    }
}
