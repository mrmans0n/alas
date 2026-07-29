import AppKit
import Testing
@testable import Alas

@MainActor
struct CompletionDocumentationRendererTests {
    @Test func rendersDocumentationWithMarkdownRenderer() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let result = CompletionDocumentationRenderer.render(
            "```swift\nfunc f() {}\n```",
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13
        )

        let range = (result.attributedString.string as NSString).range(of: "func")
        let color = result.attributedString.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor

        #expect(color != NSColor(theme.color("fg")))
    }

    @Test func completionMermaidUsesCompactAttachment() throws {
        let result = CompletionDocumentationRenderer.render(
            "```mermaid\ngraph TD; A-->B\n```",
            theme: try Theme.loadBundled(id: "cool-slate"),
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13
        )

        #expect(result.mermaidAttachments.first?.profile == .compact)
    }
}
