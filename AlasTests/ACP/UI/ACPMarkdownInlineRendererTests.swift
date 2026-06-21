import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP markdown inline renderer")
struct ACPMarkdownInlineRendererTests {
    @Test("badge image size is capped with aspect ratio")
    func badgeImageSizeIsCapped() {
        let size = ACPMarkdownInlineRenderer.displaySize(
            original: CGSize(width: 300, height: 60),
            isSubscript: true
        )
        #expect(size.width == 90)
        #expect(size.height == 18)
    }

    @Test("normal inline image size is capped")
    func normalInlineImageSizeIsCapped() {
        let size = ACPMarkdownInlineRenderer.displaySize(
            original: CGSize(width: 600, height: 300),
            isSubscript: false
        )
        #expect(size.width == 160)
        #expect(size.height == 80)
    }

    @Test("display size keeps minimum pixel dimension")
    func displaySizeKeepsMinimumPixelDimension() {
        let size = ACPMarkdownInlineRenderer.displaySize(
            original: CGSize(width: 100_000, height: 1),
            isSubscript: true
        )
        #expect(size.width >= 1)
        #expect(size.height >= 1)
    }

    @Test("badge markup produces placeholder and metadata")
    func badgeMarkupProducesPlaceholderAndMetadata() throws {
        let plan = ACPMarkdownInlineRenderer.makePlan(
            "**<sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub> Preserve streamed text**"
        )
        let image = try #require(plan.images.first)

        #expect(plan.markdownSource.contains(image.placeholder))
        #expect(image.alt == "P2 Badge")
        #expect(image.source == "https://img.shields.io/badge/P2-yellow?style=flat")
        #expect(image.isSubscript)
        #expect(plan.markdownSource.hasPrefix("**"))
        #expect(plan.markdownSource.hasSuffix("**"))
    }

    @Test("subscript text strips tags")
    func subscriptTextStripsTags() {
        let plain = ACPMarkdownInlineRenderer.plainText("Before <sub>small</sub> after")
        #expect(plain == "Before small after")
    }

    @Test("malformed subscript remains visible")
    func malformedSubscriptRemainsVisible() {
        let plain = ACPMarkdownInlineRenderer.plainText("Before <sub>small after")
        #expect(plain == "Before <sub>small after")
    }

    @Test("inline code image syntax stays text")
    func inlineCodeImageSyntaxStaysText() {
        let plan = ACPMarkdownInlineRenderer.makePlan("Use `![alt](https://example.com/a.png)` literally")
        #expect(plan.images.isEmpty)
        #expect(ACPMarkdownInlineRenderer.plainText("Use `![alt](https://example.com/a.png)` literally")
            .contains("![alt](https://example.com/a.png)"))
    }

    @Test("bold can span badge placeholder")
    func boldCanSpanBadgePlaceholder() throws {
        let attributed = ACPMarkdownInlineRenderer.makeAttributedString(
            source: "**<sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub> Preserve streamed text**",
            theme: try Theme.loadBundled(id: "cool-slate"),
            typography: ACPChatTypography(fontFamily: "", fontSize: 11),
            role: .body
        )
        let textRange = (attributed.string as NSString).range(of: "Preserve streamed text")
        try #require(textRange.location != NSNotFound)
        let font = attributed.attribute(.font, at: textRange.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("subscript text receives baseline offset")
    func subscriptTextReceivesBaselineOffset() throws {
        let attributed = ACPMarkdownInlineRenderer.makeAttributedString(
            source: "Before <sub>small</sub> after",
            theme: try Theme.loadBundled(id: "cool-slate"),
            typography: ACPChatTypography(fontFamily: "", fontSize: 11),
            role: .body
        )
        let range = (attributed.string as NSString).range(of: "small")
        try #require(range.location != NSNotFound)
        let baseline = attributed.attribute(.baselineOffset, at: range.location, effectiveRange: nil) as? CGFloat
        #expect((baseline ?? 0) < 0)
    }

    @Test("inline code receives fixed pitch font")
    func inlineCodeReceivesFixedPitchFont() throws {
        let attributed = ACPMarkdownInlineRenderer.makeAttributedString(
            source: "Use `configId` now",
            theme: try Theme.loadBundled(id: "cool-slate"),
            typography: ACPChatTypography(fontFamily: "", fontSize: 11),
            role: .body
        )
        let range = (attributed.string as NSString).range(of: "configId")
        try #require(range.location != NSNotFound)
        let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }
}
