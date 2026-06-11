import Testing
@testable import Alas

struct DiffInlineHighlighterTests {
    @Test func highlightsChangedWordInSingleLineReplacement() {
        let result = DiffInlineHighlighter.highlightDeleteAdd(
            old: "let mode = \"unified\"",
            new: "let mode = layout"
        )

        #expect(result.oldSpans.map { $0.text(in: "let mode = \"unified\"") } == ["\"unified\""])
        #expect(result.newSpans.map { $0.text(in: "let mode = layout") } == ["layout"])
    }

    @Test func returnsFullLineSpansWhenLinesAreCompletelyDifferent() {
        let result = DiffInlineHighlighter.highlightDeleteAdd(
            old: "final class Renderer {}",
            new: "import SwiftUI"
        )

        #expect(result.oldSpans == [DiffInlineSpan(start: 0, length: 23)])
        #expect(result.newSpans == [DiffInlineSpan(start: 0, length: 14)])
    }
}
