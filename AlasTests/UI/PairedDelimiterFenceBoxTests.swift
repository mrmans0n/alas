import AppKit
import Testing
@testable import Alas

@Suite("Paired delimiter code box drawing")
@MainActor
struct PairedDelimiterFenceBoxTests {
    private func makeTextView(_ text: String) -> PairedDelimiterTextView {
        let textView = PairedDelimiterTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.markdownFencesEnabled = true
        textView.markdownCodeBlockStyle = MarkdownCodeBlockStyle(
            baseFont: .systemFont(ofSize: 13),
            baseColor: .labelColor,
            monoFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
            bodyColor: .textColor,
            fenceColor: .secondaryLabelColor,
            backgroundColor: .windowBackgroundColor,
            borderColor: .separatorColor
        )
        textView.string = text
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    @Test("a fenced block yields one full-width rect")
    func oneRectPerBlock() throws {
        let textView = makeTextView("```\nlet x = 1\n```")
        let rects = textView.codeBlockBackgroundRects()

        #expect(rects.count == 1)
        let rect = try #require(rects.first)
        #expect(rect.height > 0)
        let container = try #require(textView.textContainer)
        let expectedWidth = container.size.width - container.lineFragmentPadding * 2
        #expect(abs(rect.width - expectedWidth) < 0.5)
    }

    @Test("two blocks yield two rects")
    func twoRects() {
        let textView = makeTextView("```\na\n```\n\n```\nb\n```")
        #expect(textView.codeBlockBackgroundRects().count == 2)
    }

    @Test("no fences yields no rects")
    func noRects() {
        #expect(makeTextView("just prose").codeBlockBackgroundRects().isEmpty)
    }

    @Test("no rects when fences are disabled")
    func disabledYieldsNoRects() {
        let textView = makeTextView("```\na\n```")
        textView.markdownFencesEnabled = false
        #expect(textView.codeBlockBackgroundRects().isEmpty)
    }
}
