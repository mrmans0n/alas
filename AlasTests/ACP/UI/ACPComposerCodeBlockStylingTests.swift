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

    @Test("closing an unclosed block dirties the tail it stopped covering")
    func closingABlockExtendsDirtyRange() throws {
        // The opener never moves — only the closer appears — so comparing
        // opener locations alone reports "nothing changed" and leaves "tail"
        // wearing the body styling it had while the block ran to end of text.
        let after = "```\nbody\n```\ntail"
        let previous = MarkdownFenceEditing.blocks(in: "```\nbody\ntail")
        let current = MarkdownFenceEditing.blocks(in: after)
        #expect(previous.first?.closeFenceRange == nil)
        #expect(current.first?.closeFenceRange != nil)
        #expect(previous.first?.openFenceRange.location == current.first?.openFenceRange.location)

        let length = (after as NSString).length
        let range = try #require(ACPMarkdownLiveStyler.dirtyRange(
            previous: previous,
            current: current,
            storageLength: length
        ))

        // "tail" starts at 13; the range has to reach it and run to the end.
        #expect(range.location <= 13)
        #expect(NSMaxRange(range) == length)
    }

    @Test("deleting a closer dirties the tail the block just absorbed")
    func unclosingABlockExtendsDirtyRange() throws {
        let after = "```\nbody\ntail"
        let previous = MarkdownFenceEditing.blocks(in: "```\nbody\n```\ntail")
        let current = MarkdownFenceEditing.blocks(in: after)
        #expect(previous.first?.openFenceRange.location == current.first?.openFenceRange.location)

        let length = (after as NSString).length
        let range = try #require(ACPMarkdownLiveStyler.dirtyRange(
            previous: previous,
            current: current,
            storageLength: length
        ))

        #expect(range.location <= 9)
        #expect(NSMaxRange(range) == length)
    }

    @Test("a persisted draft's fenced block is styled once the code box style arrives")
    func initialDraftFenceIsStyledOnFirstUpdate() throws {
        let draft = ACPComposerDraft(segments: [.text("intro\n```\nlet x = 1\n```")])
        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: draft,
            focusRequest: 0,
            sendOnEnter: true,
            typography: typography,
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: { _, _, _, _, _ in true }
        )
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        coordinator.textView = textView

        // `makeNSView`'s order: typography first, then the persisted draft —
        // both before `updateNSView` has handed the view its code box style.
        textView.applyChatTypography(typography)
        coordinator.restoreInitialDraft(into: textView)

        // `updateNSView`'s first pass, where the style finally shows up.
        let style = Self.codeBlockStyle(typography: typography)
        textView.markdownFencesEnabled = true
        textView.markdownCodeBlockStyle = style
        coordinator.codeBlockStyle = style
        textView.applyChatTypography(typography)

        let storage = try #require(textView.textStorage)
        let block = try #require(MarkdownFenceEditing.blocks(in: storage.string).first)
        #expect(storage.attribute(.font, at: block.openFenceRange.location, effectiveRange: nil)
            as? NSFont == style.monoFont)
        #expect(storage.attribute(.font, at: block.bodyRange.location, effectiveRange: nil)
            as? NSFont == style.monoFont)
        // Prose above the block keeps the ordinary chat font.
        #expect(storage.attribute(.font, at: 0, effectiveRange: nil)
            as? NSFont == typography.appKitFont())
    }

    @Test("a settled composer does not restyle again on later renders")
    func settledComposerDoesNotRestyleOnEveryRender() throws {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let style = Self.codeBlockStyle(typography: typography)
        let plain: [NSAttributedString.Key: Any] = [
            .font: typography.appKitFont(),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.markdownFencesEnabled = true
        textView.markdownCodeBlockStyle = style
        let storage = try #require(textView.textStorage)
        storage.setAttributedString(NSAttributedString(string: "```\nx\n```", attributes: plain))

        // The style's arrival restyles once…
        textView.applyChatTypography(typography)
        #expect(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == style.monoFont)

        // …and every later `updateNSView` pass is a no-op, so SwiftUI renders
        // don't each re-parse and re-attribute the whole storage.
        storage.setAttributedString(NSAttributedString(string: "```\nx\n```", attributes: plain))
        textView.applyChatTypography(typography)

        #expect(storage.attribute(.font, at: 0, effectiveRange: nil)
            as? NSFont == typography.appKitFont())
    }

    @Test("the composer's code block style threads the configured chat font family through")
    func codeBlockStyleThreadsConfiguredFontFamily() {
        let theme = Theme(id: "test", name: "Test", tokens: [:])
        let configured = ACPChatTypography(fontFamily: "Menlo", fontSize: 13)

        let style = ACPInputField.codeBlockStyle(theme: theme, baseFont: configured.appKitFont(), typography: configured)

        #expect(style.monoFont == CenterTypography.resolveCodeFont(family: "Menlo", size: configured.codeSize))
        #expect(style.monoFont != .monospacedSystemFont(ofSize: configured.codeSize, weight: .regular))
    }

    @Test("the default (unconfigured) chat font still yields system mono")
    func codeBlockStyleDefaultsToSystemMono() {
        let theme = Theme(id: "test", name: "Test", tokens: [:])

        let style = ACPInputField.codeBlockStyle(theme: theme, baseFont: typography.appKitFont(), typography: typography)

        #expect(style.monoFont == .monospacedSystemFont(ofSize: typography.codeSize, weight: .regular))
    }

    private static func codeBlockStyle(typography: ACPChatTypography) -> MarkdownCodeBlockStyle {
        MarkdownCodeBlockStyle(
            baseFont: typography.appKitFont(),
            baseColor: .labelColor,
            monoFont: .monospacedSystemFont(ofSize: typography.codeSize, weight: .regular),
            bodyColor: .labelColor,
            fenceColor: .secondaryLabelColor,
            backgroundColor: .windowBackgroundColor,
            borderColor: .separatorColor
        )
    }
}
