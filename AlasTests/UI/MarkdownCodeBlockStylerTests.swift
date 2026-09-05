import AppKit
import Testing
@testable import Alas

@Suite("Markdown code block styler")
@MainActor
struct MarkdownCodeBlockStylerTests {
    private let style = MarkdownCodeBlockStyle(
        baseFont: .systemFont(ofSize: 13),
        baseColor: .labelColor,
        monoFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
        bodyColor: .textColor,
        fenceColor: .secondaryLabelColor,
        backgroundColor: .windowBackgroundColor,
        borderColor: .separatorColor
    )

    private func storage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        storage.setAttributes(
            [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor],
            range: NSRange(location: 0, length: (text as NSString).length)
        )
        return storage
    }

    @Test("styles the body monospaced and the fences dimmed")
    func stylesBlock() throws {
        // "text\n" = 0..4, fence 5..12 ("```swift"), body 14..23, fence 24..26
        let storage = storage("text\n```swift\nlet x = 1\n```\nafter")
        MarkdownCodeBlockStyler.restyle(storage, in: nil, style: style)

        #expect(storage.attribute(.font, at: 16, effectiveRange: nil) as? NSFont == style.monoFont)
        #expect(storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont == style.monoFont)
        #expect(storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == style.fenceColor)
        #expect(storage.attribute(.foregroundColor, at: 16, effectiveRange: nil) as? NSColor == style.bodyColor)
    }

    @Test("leaves text outside a block at the base attributes")
    func resetsOutsideBlock() {
        let storage = storage("text\n```swift\nlet x = 1\n```\nafter")
        MarkdownCodeBlockStyler.restyle(storage, in: nil, style: style)

        #expect(storage.attribute(.font, at: 1, effectiveRange: nil) as? NSFont == style.baseFont)
        #expect(storage.attribute(.font, at: 29, effectiveRange: nil) as? NSFont == style.baseFont)
    }

    @Test("removing a fence restores base attributes")
    func restoresAfterFenceRemoval() {
        let storage = storage("```\ncode\n```")
        MarkdownCodeBlockStyler.restyle(storage, in: nil, style: style)
        #expect(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont == style.monoFont)

        storage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "")
        MarkdownCodeBlockStyler.restyle(storage, in: nil, style: style)
        #expect(storage.attribute(.font, at: 1, effectiveRange: nil) as? NSFont == style.baseFont)
    }

    @Test("returns the blocks it found")
    func returnsBlocks() {
        let blocks = MarkdownCodeBlockStyler.restyle(storage("```\na\n```"), in: nil, style: style)
        #expect(blocks.count == 1)
    }

    @Test("preserves chip attachment attributes")
    func preservesChips() {
        let storage = storage("x\n```\na\n```")
        storage.addAttribute(.attachmentURI, value: "file:///tmp/A.swift", range: NSRange(location: 0, length: 1))
        MarkdownCodeBlockStyler.restyle(storage, in: nil, style: style)

        #expect(storage.attribute(.attachmentURI, at: 0, effectiveRange: nil) as? String == "file:///tmp/A.swift")
    }
}
