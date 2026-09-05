import AppKit
import Testing
@testable import Alas

@Suite("Code box surface opt-in")
@MainActor
struct MarkdownCodeBoxSurfaceOptInTests {
    private let theme = Theme(id: "test", name: "Test", tokens: [:])

    @Test("the standard style uses the transcript's code block colours")
    func standardStyleMatchesTranscript() {
        let style = MarkdownCodeBlockStyle.standard(
            theme: theme,
            baseFont: .systemFont(ofSize: 12),
            baseColor: .labelColor,
            monoSize: 12
        )

        #expect(style.monoFont.isFixedPitch)
        #expect(style.cornerRadius == 6)
        #expect(style.borderWidth == 0.5)
        #expect(style.backgroundColor.alphaComponent < 1)
    }

    @Test("the standard style keeps the surface's own base font")
    func standardStyleKeepsBaseFont() {
        let base = NSFont.systemFont(ofSize: 11)
        let style = MarkdownCodeBlockStyle.standard(
            theme: theme,
            baseFont: base,
            baseColor: .labelColor,
            monoSize: 11
        )

        #expect(style.baseFont == base)
        #expect(style.monoFont != base)
    }
}
