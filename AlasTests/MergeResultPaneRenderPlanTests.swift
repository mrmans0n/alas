import Foundation
import Testing
@testable import Alas

struct MergeResultPaneRenderPlanTests {
    @Test func conflictColumnRebuildsOnThemeOnlyChangeButNotOnIdenticalUpdate() throws {
        let plain = try Theme.loadBundled(id: "cool-slate")
        var solarized = plain
        solarized.codePalette = try #require(CodePalette.loadBundled(id: "solarized-dark"))

        #expect(MergeConflictTextStorage.needsRebuild(
            renderedText: "let a = 1", text: "let a = 1", renderedTheme: plain, theme: solarized))
        #expect(!MergeConflictTextStorage.needsRebuild(
            renderedText: "let a = 1", text: "let a = 1", renderedTheme: plain, theme: plain))
    }

    @Test func renderedTextOmitsOnlyFinalNewlineWhenFileHasNoTrailingNewline() {
        let rows = [
            MergeRegionVisualLayout.VisualRow(content: "one", sourceLineNumber: 1),
            MergeRegionVisualLayout.VisualRow(content: "two", sourceLineNumber: 2),
        ]

        let rendered = MergeResultPaneRenderPlan.renderedText(
            rows: rows,
            endsWithNewline: false
        )

        #expect(rendered.text == "one\ntwo")
        #expect(rendered.rowRanges == [
            NSRange(location: 0, length: 4),
            NSRange(location: 4, length: 3),
        ])
    }

    @Test func rowKindsArePrecomputedFromVisualConflictRanges() {
        let range = MergeRegionVisualLayout.VisualConflictRange(
            conflictOrdinal: 2,
            localRows: 10 ..< 12,
            baseRows: 4 ..< 6,
            resultRows: 2 ..< 8,
            resultLocalRows: 2 ..< 4,
            resultRemoteRows: 6 ..< 8,
            remoteRows: 14 ..< 16
        )

        let kinds = MergeResultPaneRenderPlan.rowKinds(conflictRanges: [range])

        #expect(kinds[2] == .local(ordinal: 2, withinIndex: 0))
        #expect(kinds[3] == .local(ordinal: 2, withinIndex: 1))
        #expect(kinds[4] == .base)
        #expect(kinds[5] == .base)
        #expect(kinds[6] == .remote(ordinal: 2, withinIndex: 0))
        #expect(kinds[7] == .remote(ordinal: 2, withinIndex: 1))
        #expect(kinds[8] == nil)
    }
}
