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
