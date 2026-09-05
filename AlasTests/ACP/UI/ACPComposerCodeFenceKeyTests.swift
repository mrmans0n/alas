import AppKit
import Testing
@testable import Alas

@Suite("ACP composer code fence key handling")
@MainActor
struct ACPComposerCodeFenceKeyTests {
    private func makeTextView(_ text: String, caret: Int) -> ACPNSTextView {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.markdownFencesEnabled = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return textView
    }

    @Test("the caret in a block body is reported as inside")
    func bodyIsInsideBlock() {
        let textView = makeTextView("```\ncode\n```", caret: 5)
        #expect(textView.fencedBlockRange(containing: 5) != nil)
    }

    @Test("the info-string slot is reported as inside")
    func infoSlotIsInsideBlock() {
        let textView = makeTextView("```swift\ncode\n```", caret: 8)
        #expect(textView.fencedBlockRange(containing: 8) != nil)
    }

    @Test("a caret part-way through the info string is reported as inside")
    func partialInfoSlotIsInsideBlock() {
        // Half-typed language tag: the caret sits between 's' and 'w' of
        // "swift". ⏎ here has to insert a newline, not submit the message.
        let textView = makeTextView("```swift\ncode\n```", caret: 4)
        #expect(textView.fencedBlockRange(containing: 4) != nil)
    }

    @Test("a caret before the opening backticks is outside")
    func beforeFenceIsOutside() {
        let textView = makeTextView("```\ncode\n```", caret: 0)
        #expect(textView.fencedBlockRange(containing: 0) == nil)
    }

    @Test("a caret past the closing fence is outside")
    func afterFenceIsOutside() {
        let textView = makeTextView("```\ncode\n```\ntail", caret: 16)
        #expect(textView.fencedBlockRange(containing: 16) == nil)
    }

    @Test("fences disabled reports everything as outside")
    func disabledIsAlwaysOutside() {
        let textView = makeTextView("```\ncode\n```", caret: 5)
        textView.markdownFencesEnabled = false
        #expect(textView.fencedBlockRange(containing: 5) == nil)
    }
}
