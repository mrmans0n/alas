import Foundation
import Testing
@testable import Alas

struct MergeSyntaxHighlighterTests {
    @Test func documentSpansAreSplitAndClippedPerLine() {
        // "ab\ncde\nf": a comment spanning "b\ncd" and a keyword on "f".
        let spans = [
            HighlightSpan(range: NSRange(location: 1, length: 4), capture: .comment),
            HighlightSpan(range: NSRange(location: 7, length: 1), capture: .keyword),
        ]

        let lines = MergeSyntaxHighlighter.split(spans, lineLengths: [2, 3, 1])

        #expect(lines == [
            [.init(location: 1, length: 1, capture: .comment)],
            [.init(location: 0, length: 2, capture: .comment)],
            [.init(location: 0, length: 1, capture: .keyword)],
        ])
    }
}
