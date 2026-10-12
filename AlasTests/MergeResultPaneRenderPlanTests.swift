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

        let rendered = MergePaneText.render(rows: rows, endsWithNewline: false)

        #expect(rendered.text == "one\ntwo")
        #expect(rendered.rowRanges == [
            NSRange(location: 0, length: 4),
            NSRange(location: 4, length: 3),
        ])
    }
}
