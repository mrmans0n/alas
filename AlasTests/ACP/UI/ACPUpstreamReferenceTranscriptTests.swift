import AppKit
import Foundation
import Testing
@testable import Alas

// @MainActor: drives ACPMarkdownInlineNSTextView, AppKit main-thread-only APIs.
@MainActor
@Suite("ACP transcript upstream reference chips")
struct ACPUpstreamReferenceTranscriptTests {
    private let theme = Theme(id: "test", name: "Test", tokens: ["fg": "#ffffff", "fg-muted": "#aaaaaa", "accent": "#5fb7c4"])

    private func rendered(_ source: String) -> NSMutableAttributedString {
        ACPMarkdownInlineRenderer.makeAttributedString(
            source: source, theme: theme, typography: .default, role: .body
        )
    }

    @Test("rendered user text chips plain references but not inline code or links")
    func renderedExclusions() async {
        let store = await UpstreamReferenceFixtures.store()
        let text = rendered("fixes #12, not `#13` or [#14](https://example.com)")

        let count = ACPUpstreamReferenceChip.chipifyRendered(
            text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github)
        )

        #expect(count == 1)
        #expect(ACPUpstreamReferenceChip.plainText(of: text) == "fixes #12, not #13 or #14")
    }

    @Test("copying a transcript selection spells chips out instead of U+FFFC")
    func transcriptCopy() async {
        let store = await UpstreamReferenceFixtures.store()
        let text = rendered("see #12 please")
        ACPUpstreamReferenceChip.chipifyRendered(text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github))
        let textView = ACPMarkdownInlineNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(text)
        let board = NSPasteboard(name: .init("alas-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        textView.selectAll(nil)

        #expect(textView.writeSelection(to: board, types: [.string]))
        #expect(board.string(forType: .string) == "see #12 please")
    }

    @Test("a paragraph with a chip measures wider than its text alone")
    func measuresChipWidth() async {
        let store = await UpstreamReferenceFixtures.store()
        let sentence = "this is a plain paragraph of text with no reference in it"
        let plain = ACPMarkdownInlineNSTextView(frame: .zero)
        plain.textStorage?.setAttributedString(rendered(sentence))
        let chipped = ACPMarkdownInlineNSTextView(frame: .zero)
        let text = rendered("\(sentence) #12")
        ACPUpstreamReferenceChip.chipifyRendered(text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github))
        chipped.textStorage?.setAttributedString(text)

        #expect(chipped.naturalFittingSize().width > plain.naturalFittingSize().width + 30)
    }
}
