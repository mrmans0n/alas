import Foundation
import Testing
@testable import Alas

@Suite("ACPPastedText")
struct ACPPastedTextTests {
    @Test("collapses past 20 lines or 2,000 UTF-16 units", arguments: [
        (String(repeating: "a\n", count: 20), false),
        (String(repeating: "a\n", count: 20) + "a", true),
        (String(repeating: "a\r\n", count: 20), false),
        (String(repeating: "a\r\n", count: 21), true),
        (String(repeating: "x", count: 2_000), false),
        (String(repeating: "x", count: 2_001), true),
        (String(repeating: "😀", count: 1_001), true),
    ])
    func collapseThreshold(text: String, collapses: Bool) {
        #expect(ACPPastedTextPolicy.shouldCollapse(text) == collapses)
    }

    @Test("labels multi-line pastes by lines and single-line pastes by size")
    func label() {
        #expect(ACPPastedTextPolicy.label(ordinal: 3, content: "a\nb\nc\n") == "Pasted text #3 · 3 lines")
        #expect(ACPPastedTextPolicy.label(ordinal: 1, content: String(repeating: "x", count: 38_000))
            == "Pasted text #1 · 38 KB")
        #expect(ACPPastedTextPolicy.label(ordinal: 1, content: String(repeating: "x", count: 2_001) + "\n")
            == "Pasted text #1 · 1 line")
    }

    @Test("contents reject span sets that would badge the wrong text", arguments: [
        [ACPPastedTextSpan(ordinal: 1, utf16Offset: 4, utf16Length: 10)],
        [ACPPastedTextSpan(ordinal: 1, utf16Offset: 0, utf16Length: 0)],
        [ACPPastedTextSpan(ordinal: 1, utf16Offset: 0, utf16Length: 3),
         ACPPastedTextSpan(ordinal: 2, utf16Offset: 2, utf16Length: 2)],
        [ACPPastedTextSpan(ordinal: 1, utf16Offset: 0, utf16Length: 1),
         ACPPastedTextSpan(ordinal: 1, utf16Offset: 2, utf16Length: 1)],
        [ACPPastedTextSpan(ordinal: 1, utf16Offset: Int.max, utf16Length: 2)],
    ])
    func rejectsInvalidSpans(spans: [ACPPastedTextSpan]) {
        #expect(ACPPastedTextContents(text: "abcdef", spans: spans) == nil)
    }

    @Test("typed text drops pasted spans, and content slices by ordinal")
    func typedTextAndContent() throws {
        // "see 😀" is 6 UTF-16 units.
        let contents = try #require(ACPPastedTextContents(text: "see 😀LOG1 and LOG2!", spans: [
            ACPPastedTextSpan(ordinal: 2, utf16Offset: 15, utf16Length: 4),
            ACPPastedTextSpan(ordinal: 1, utf16Offset: 6, utf16Length: 4),
        ]))
        #expect(contents.content(ordinal: 1) == "LOG1")
        #expect(contents.content(ordinal: 2) == "LOG2")
        #expect(contents.typedText == "see 😀 and !")
    }

    @Test("a paste at the very start of the message is not a typed slash command")
    func leadingPasteBlocksCommand() throws {
        let contents = try #require(ACPPastedTextContents(text: "/review all of this", spans: [
            ACPPastedTextSpan(ordinal: 1, utf16Offset: 0, utf16Length: 19),
        ]))
        #expect(!contents.spansStart(atOrAfter: "/review ".utf16.count))
    }
}
