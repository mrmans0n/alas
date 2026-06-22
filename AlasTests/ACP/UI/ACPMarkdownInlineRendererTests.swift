import AppKit
import Foundation
import SwiftUI
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

    @Test("remote image sources are renderable")
    func remoteImageSourcesAreRenderable() {
        let image = ACPMarkdownInlineImage(
            placeholder: "\u{E000}ALAS_IMG_0\u{E000}",
            alt: "P2 Badge",
            source: "https://img.shields.io/badge/P2-yellow?style=flat",
            isSubscript: true
        )
        #expect(ACPMarkdownInlineRenderer.imageSourceKind(image.source) == .remote)
    }

    @Test("local image sources fall back without base directory")
    func localImageSourcesFallbackWithoutBaseDirectory() {
        #expect(ACPMarkdownInlineRenderer.imageSourceKind("assets/badge.png") == .local)
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

    @Test("subscript tags are case-insensitive")
    func subscriptTagsAreCaseInsensitive() throws {
        let plain = ACPMarkdownInlineRenderer.plainText("Before <SUB>small</SUB> after")
        #expect(plain == "Before small after")

        let plan = ACPMarkdownInlineRenderer.makePlan(
            "<SUB>![P3 Badge](https://img.shields.io/badge/P3-lightgrey?style=flat)</SUB>"
        )
        let image = try #require(plan.images.first)
        #expect(image.isSubscript)
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

    @Test("loaded image replacement preserves inherited link")
    func loadedImageReplacementPreservesInheritedLink() throws {
        let url = try #require(URL(string: "https://review.example"))
        let remoteImage = ACPMarkdownInlineRemoteImage(
            image: ACPMarkdownInlineImage(
                placeholder: "\u{E000}ALAS_IMG_0\u{E001}",
                alt: "P2",
                source: "https://img.shields.io/badge/P2-yellow?style=flat",
                isSubscript: true
            ),
            url: try #require(URL(string: "https://img.shields.io/badge/P2-yellow?style=flat"))
        )

        let image = NSImage(size: CGSize(width: 32, height: 16))
        let replacement = ACPMarkdownInlineRenderer.loadedImageString(
            for: image,
            isSubscript: true,
            attributes: [
                .link: url,
                .acpMarkdownInlineRemoteImage: remoteImage,
            ]
        )

        #expect(replacement.attribute(.link, at: 0, effectiveRange: nil) as? URL == url)
        #expect(replacement.attribute(.acpMarkdownInlineRemoteImage, at: 0, effectiveRange: nil) == nil)
    }

    @Test("inline provider thread comments render markdown body")
    func inlineProviderThreadCommentRendersMarkdownBody() throws {
        let comment = DiffInlineComment(
            id: "comment-1",
            author: "reviewer",
            body: """
            **<sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub> Preserve small horizontal scroll deltas**

            Use `leadingX` instead of **resetting** each event.
            """
        )
        let thread = DiffInlineCommentThread(
            id: "thread-1",
            filePath: "Sources/App.swift",
            newLine: 2,
            isResolved: false,
            isOutdated: false,
            comments: [comment]
        )

        let host = NSHostingView(
            rootView: DiffInlineCommentCard(thread: thread)
                .environment(\.theme, try Theme.loadBundled(id: "cool-slate"))
                .frame(width: 620, height: 260)
        )
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 260)
        host.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-inline-comment-markdown-comment-1", in: host) != nil)

        let renderedBody = allSubviews(of: host)
            .compactMap { $0 as? NSTextView }
            .map(\.string)
            .joined(separator: "\n")

        #expect(renderedBody.contains("Preserve small horizontal scroll deltas"))
        #expect(renderedBody.contains("Use leadingX instead of resetting each event."))
        #expect(!renderedBody.contains("**"))
        #expect(!renderedBody.contains("<sub>"))
        #expect(!renderedBody.contains("`leadingX`"))
        #expect(accessibilityLabel(in: host, containing: "**<sub>") == nil)
        #expect(accessibilityLabel(in: host, containing: "`leadingX`") == nil)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { subview(withAccessibilityIdentifier: identifier, in: $0) }.first
    }

    private func accessibilityLabel(in view: NSView, containing text: String) -> String? {
        if let label = view.accessibilityLabel(), label.contains(text) {
            return label
        }
        return view.subviews.lazy.compactMap { accessibilityLabel(in: $0, containing: text) }.first
    }
}
