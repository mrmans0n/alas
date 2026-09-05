import AppKit
import Testing
@testable import Alas

@Suite("ACP composer code block styling")
@MainActor
struct ACPComposerCodeBlockStylingTests {
    private let typography = ACPChatTypography.default

    @Test("inline styling skips text inside a code block")
    func inlineStylingSkipsBlocks() {
        let source = "**out**\n```\n**in**\n```"
        let storage = NSTextStorage(string: source)
        let blocks = MarkdownFenceEditing.blocks(in: source).map(\.outerRange)

        ACPMarkdownLiveStyler.restyle(storage, in: nil, typography: typography, excluding: blocks)

        let boldFont = typography.appKitFont(traits: .boldFontMask)
        // "**out**" starts at 0; "**in**" starts at 12.
        #expect(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont == boldFont)
        #expect(storage.attribute(.font, at: 14, effectiveRange: nil) as? NSFont != boldFont)
    }

    @Test("with no exclusions the styler behaves exactly as before")
    func noExclusionsIsUnchanged() {
        let storage = NSTextStorage(string: "**bold**")
        ACPMarkdownLiveStyler.restyle(storage, in: nil, typography: typography)

        #expect(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
            == typography.appKitFont(traits: .boldFontMask))
    }

    @Test("a new fence extends the dirty range to end of storage")
    func fenceChangeExtendsDirtyRange() {
        let before = MarkdownFenceEditing.blocks(in: "a\nb\nc")
        let after = MarkdownFenceEditing.blocks(in: "a\n```\nc")
        #expect(before.isEmpty)
        #expect(after.count == 1)

        let range = ACPMarkdownLiveStyler.dirtyRange(
            previous: before,
            current: after,
            storageLength: 7
        )
        #expect(range == NSRange(location: 2, length: 5))
    }

    @Test("an unchanged fence set produces no extra dirty range")
    func unchangedFencesProduceNoRange() {
        let blocks = MarkdownFenceEditing.blocks(in: "```\na\n```")
        #expect(ACPMarkdownLiveStyler.dirtyRange(
            previous: blocks,
            current: blocks,
            storageLength: 9
        ) == nil)
    }
}
