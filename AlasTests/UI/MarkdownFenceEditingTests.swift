import Foundation
import Testing
@testable import Alas

@Suite("Markdown fence parsing")
struct MarkdownFenceEditingTests {
    @Test("parses a closed block")
    func closedBlock() throws {
        let blocks = MarkdownFenceEditing.blocks(in: "```\ncode\n```")
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.openFenceRange == NSRange(location: 0, length: 3))
        #expect(block.bodyRange == NSRange(location: 4, length: 5))
        #expect(block.closeFenceRange == NSRange(location: 9, length: 3))
        #expect(block.infoString == "")
        #expect(block.outerRange == NSRange(location: 0, length: 12))
    }

    @Test("captures the info string")
    func infoString() throws {
        let blocks = MarkdownFenceEditing.blocks(in: "```swift\nlet x = 1\n```")
        let block = try #require(blocks.first)
        #expect(block.infoString == "swift")
        #expect(block.openFenceRange == NSRange(location: 0, length: 8))
        #expect(block.bodyRange == NSRange(location: 9, length: 10))
        #expect(block.closeFenceRange == NSRange(location: 19, length: 3))
    }

    @Test("an unclosed block runs to end of text")
    func unclosedBlock() throws {
        let blocks = MarkdownFenceEditing.blocks(in: "```\ncode")
        let block = try #require(blocks.first)
        #expect(block.closeFenceRange == nil)
        #expect(block.bodyRange == NSRange(location: 4, length: 4))
        #expect(block.outerRange == NSRange(location: 0, length: 8))
    }

    @Test("a lone fence on the last line yields an empty body")
    func loneTrailingFence() throws {
        let blocks = MarkdownFenceEditing.blocks(in: "text\n```")
        let block = try #require(blocks.first)
        #expect(block.openFenceRange == NSRange(location: 5, length: 3))
        #expect(block.bodyRange == NSRange(location: 8, length: 0))
        #expect(block.closeFenceRange == nil)
    }

    @Test("parses back-to-back blocks independently")
    func backToBackBlocks() {
        let blocks = MarkdownFenceEditing.blocks(in: "```\na\n```\n```\nb\n```")
        #expect(blocks.count == 2)
        #expect(blocks.first?.outerRange == NSRange(location: 0, length: 9))
        #expect(blocks.last?.outerRange == NSRange(location: 10, length: 9))
    }

    @Test("allows up to three spaces of indent")
    func indentedFence() throws {
        let blocks = MarkdownFenceEditing.blocks(in: "  ```\na\n  ```")
        let block = try #require(blocks.first)
        #expect(block.openFenceRange == NSRange(location: 0, length: 5))
        #expect(block.closeFenceRange == NSRange(location: 8, length: 5))
    }

    @Test("four spaces of indent is not a fence")
    func overIndentedFence() {
        #expect(MarkdownFenceEditing.blocks(in: "    ```\na").isEmpty)
    }

    @Test("an info string containing a backtick is not a fence")
    func infoStringWithBacktick() {
        #expect(MarkdownFenceEditing.blocks(in: "``` `x`\ncode").isEmpty)
    }

    @Test("a fence with an info string cannot close a block")
    func infoStringCannotClose() throws {
        let blocks = MarkdownFenceEditing.blocks(in: "```\n```swift\n```")
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.closeFenceRange == NSRange(location: 13, length: 3))
    }

    @Test("plain text has no blocks")
    func plainText() {
        #expect(MarkdownFenceEditing.blocks(in: "just prose").isEmpty)
        #expect(MarkdownFenceEditing.blocks(in: "").isEmpty)
    }
}

@Suite("Markdown fence keystroke resolution")
struct MarkdownFenceResolveTests {
    private func resolve(_ inserted: String, _ text: String, _ range: NSRange) -> FenceEditAction {
        MarkdownFenceEditing.resolve(insertedText: inserted, in: text, selectedRange: range)
    }

    @Test("the third backtick opens a block")
    func thirdBacktickOpens() {
        #expect(resolve("`", "``", NSRange(location: 2, length: 0)) == .openBlock)
    }

    @Test("fewer than two preceding backticks falls through")
    func notEnoughBackticks() {
        #expect(resolve("`", "`", NSRange(location: 1, length: 0)) == .none)
        #expect(resolve("`", "", NSRange(location: 0, length: 0)) == .none)
    }

    @Test("more than two preceding backticks falls through")
    func tooManyBackticks() {
        #expect(resolve("`", "```", NSRange(location: 3, length: 0)) == .none)
    }

    @Test("a non-backtick keystroke falls through")
    func otherCharacter() {
        #expect(resolve("a", "``", NSRange(location: 2, length: 0)) == .none)
    }

    @Test("does not open a second block from inside one")
    func suppressedInsideBlock() {
        // Caret sits after "x``" on the body line of an open block.
        #expect(resolve("`", "```\nx``\n```", NSRange(location: 7, length: 0)) == .none)
    }

    @Test("the third backtick over a flanked selection wraps it")
    func wrapsFlankedSelection() {
        #expect(resolve("`", "``value``", NSRange(location: 2, length: 5)) == .wrapSelection)
    }

    @Test("a selection reaching into a block's interior falls through")
    func selectionReachingIntoABlockIsRefused() {
        // "``A\n```\nb``\n```": the selection starts at 2 — outside every
        // block, since the block's own opener only starts at 4 — but runs
        // through the opener and into the body. Checking containment at the
        // selection's start alone sees nothing and wraps, folding the block's
        // opener into a new outer fence.
        #expect(resolve("`", "``A\n```\nb``\n```", NSRange(location: 2, length: 7)) == .none)
    }

    @Test("a selection that swallows a whole block falls through")
    func selectionContainingAWholeBlockIsRefused() {
        // "``\n```\ncode\n```\n``": neither endpoint is inside the block —
        // the selection starts before its opener and ends after its closer —
        // yet the block sits entirely within the selection, so wrapping would
        // sweep both of its fence lines into the new outer one.
        #expect(resolve("`", "``\n```\ncode\n```\n``", NSRange(location: 2, length: 14)) == .none)
    }

    @Test("a selection next to a block, but not overlapping it, still wraps")
    func selectionAdjacentToABlockStillWraps() {
        // Counterweight to the two tests above: the overlap check must not
        // refuse a selection that merely sits below an existing block.
        #expect(resolve("`", "```\ncode\n```\n``value``", NSRange(location: 15, length: 5)) == .wrapSelection)
    }

    @Test("an unflanked selection falls through to inline pairing")
    func unflankedSelection() {
        #expect(resolve("`", "value", NSRange(location: 0, length: 5)) == .none)
        #expect(resolve("`", "`value`", NSRange(location: 1, length: 5)) == .none)
    }

    @Test("an out-of-bounds selection falls through")
    func invalidSelection() {
        #expect(resolve("`", "``", NSRange(location: 99, length: 0)) == .none)
    }

    @Test("counts the auto-paired closer parked after the caret")
    func trailingBacktickRun() {
        // Typed from an empty line: pair then step-over, nothing left after.
        #expect(MarkdownFenceEditing.trailingBacktickRun(at: 2, in: "``") == 0)
        // Typed after a word: the first backtick went native, the second
        // paired, so a closer sits after the caret.
        #expect(MarkdownFenceEditing.trailingBacktickRun(at: 5, in: "run```") == 1)
        #expect(MarkdownFenceEditing.trailingBacktickRun(at: 2, in: "``tail") == 0)
        #expect(MarkdownFenceEditing.trailingBacktickRun(at: 0, in: "`````") == 2)
        #expect(MarkdownFenceEditing.trailingBacktickRun(at: 99, in: "``") == 0)
    }
}

@Suite("Markdown fence containment")
struct MarkdownFenceContainmentTests {
    private let text = "```swift\nlet x = 1\n```"

    @Test("the info-string slot counts as inside")
    func infoSlotIsInside() {
        #expect(MarkdownFenceEditing.block(containing: 8, in: text) != nil)
    }

    @Test("a position part-way through the info string counts as inside")
    func midInfoStringIsInside() {
        // Caret between 's' and 'w' of "swift" — the author is still typing
        // the language tag. The whole slot is inside the block, not just the
        // one position at its end.
        #expect(MarkdownFenceEditing.block(containing: 4, in: text) != nil)
        #expect(MarkdownFenceEditing.block(containing: 3, in: text) != nil)
    }

    @Test("a position inside the opening backticks is still outside")
    func withinTheOpeningBackticksIsOutside() {
        // The run of backticks itself is the fence, not its interior.
        #expect(MarkdownFenceEditing.block(containing: 1, in: text) == nil)
        #expect(MarkdownFenceEditing.block(containing: 2, in: text) == nil)
    }

    @Test("the body counts as inside")
    func bodyIsInside() {
        #expect(MarkdownFenceEditing.block(containing: 12, in: text) != nil)
        #expect(MarkdownFenceEditing.block(containing: 19, in: text) != nil)
    }

    @Test("before the opening backticks is outside")
    func beforeOpenIsOutside() {
        #expect(MarkdownFenceEditing.block(containing: 0, in: text) == nil)
    }

    @Test("past the closing fence is outside")
    func afterCloseIsOutside() {
        #expect(MarkdownFenceEditing.block(containing: 22, in: "```\na\n```\ntail") == nil)
    }

    @Test("an unclosed block contains everything after it")
    func unclosedContainsTail() {
        #expect(MarkdownFenceEditing.block(containing: 8, in: "```\ncode") != nil)
    }
}
