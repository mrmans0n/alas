import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite("PairedTextEditor markdown styling")
@MainActor
struct PairedTextEditorMarkdownStylingTests {
    private let style = MarkdownCodeBlockStyle(
        baseFont: .systemFont(ofSize: 13),
        baseColor: .labelColor,
        monoFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
        bodyColor: .textColor,
        fenceColor: .secondaryLabelColor,
        backgroundColor: .windowBackgroundColor,
        borderColor: .separatorColor
    )

    @Test("styling off leaves the storage unstyled and fences inert")
    func stylingOffIsPlain() {
        var text = "```\ncode\n```"
        let editor = PairedTextEditor(text: Binding(get: { text }, set: { text = $0 }))
        let (_, textView) = editor.makeBackingView()
        editor.applyConfigurationForTesting(to: textView)

        #expect(textView.markdownFencesEnabled == false)
        #expect(textView.markdownCodeBlockStyle == nil)
        #expect(textView.codeBlockBackgroundRects().isEmpty)
        // Nothing was styled: the whole storage keeps the editor's own font.
        let storage = textView.textStorage
        #expect(storage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont != style.monoFont)
    }

    @Test("styling on enables fences and applies block attributes")
    func stylingOnStylesBlocks() throws {
        var text = "```\ncode\n```"
        let editor = PairedTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            codeBlockStyle: style
        )
        let (_, textView) = editor.makeBackingView()
        editor.applyConfigurationForTesting(to: textView)

        #expect(textView.markdownFencesEnabled)
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont == style.monoFont)
    }
}
