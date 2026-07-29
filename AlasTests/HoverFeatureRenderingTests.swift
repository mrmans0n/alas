import Testing
import AppKit
import Markdown
@testable import Alas

@MainActor
struct HoverFeatureRenderingTests {
    @Test func rendersMarkdownProseWithThemeForeground() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let document = Document(parsing: "Hello, world.")
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let s = result.attributedString
        let color = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let expected = NSColor(theme.color("fg"))
        #expect(color == expected)
    }

    @Test func rendersCodeBlockMonospaced() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let document = Document(parsing: "```swift\nlet x = 1\n```")
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let s = result.attributedString
        let range = (s.string as NSString).range(of: "let x = 1")
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func highlightsSwiftCodeBlockKeyword() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let document = Document(parsing: "```swift\nfunc f() {}\n```")
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let s = result.attributedString
        let range = (s.string as NSString).range(of: "func")
        let color = s.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        let defaultFG = NSColor(theme.color("fg"))
        #expect(color != defaultFG)
    }

    @Test func rendersPlainContentAsMonospaced() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let wrappedInBackticks = "`let x: Int`"
        let document = Document(parsing: wrappedInBackticks)
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let s = result.attributedString
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func hoverContentViewUsesThemeBackground() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let document = Document(parsing: "Hello")
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let view = HoverFeatureTesting.makeHoverContainer(
            result: result,
            theme: theme
        )
        let bgColor = view.backgroundColor
        let expected = NSColor(theme.color("bg-1"))
        #expect(bgColor == expected)
    }

    @Test func popoverSizeShrinksToSmallContent() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let tiny = Document(parsing: "x")
        let tinyResult = MarkdownRenderer().render(
            document: tiny, theme: theme,
            monospacedFontFamily: "SF Mono", monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let tinySize = HoverFeatureTesting.computePreferredSize(for: tinyResult)
        // No 360 x 220 floor: a single character should not produce a giant box.
        #expect(tinySize.width < 360)
        #expect(tinySize.height < 220)
        // AppKit padding gives a small natural minimum; just assert positive.
        #expect(tinySize.width > 0)
        #expect(tinySize.height > 0)
    }

    @Test func popoverSizeClampsLargeContent() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let huge = Document(parsing: String(repeating: "very long line of text that just keeps going on and on and on forever ", count: 30))
        let hugeResult = MarkdownRenderer().render(
            document: huge, theme: theme,
            monospacedFontFamily: "SF Mono", monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let hugeSize = HoverFeatureTesting.computePreferredSize(for: hugeResult)
        #expect(hugeSize.width <= 520)
        #expect(hugeSize.height <= 400)
    }

    @Test func hoverMermaidUsesCompactAttachment() throws {
        let result = MarkdownRenderer().render(
            document: Document(parsing: "```mermaid\ngraph TD; A-->B\n```"),
            theme: try Theme.loadBundled(id: "cool-slate"),
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/"),
            mermaidProfile: .compact
        )
        let attachment = try #require(result.mermaidAttachments.first?.attachment)
        let cell = attachment.mermaidCell
        let frame = NSRect(
            origin: .zero,
            size: NSSize(width: 500, height: cell.cellSize.height)
        )
        let loadingSize = HoverFeatureTesting.computePreferredSize(for: result)

        #expect(attachment.profile == .compact)
        #expect(cell.layoutFrames(in: frame).body.height == 180)
        #expect(loadingSize.height <= 400)

        cell.apply(.rendered(
            MermaidRenderedDiagram(
                image: NSImage(size: NSSize(width: 80, height: 40)),
                pixelSize: CGSize(width: 160, height: 80),
                byteCost: 160 * 80 * 4
            )
        ))
        let renderedFrame = NSRect(
            origin: .zero,
            size: NSSize(width: 500, height: cell.cellSize.height)
        )

        #expect(cell.layoutFrames(in: renderedFrame).body.height == 180)
        #expect(HoverFeatureTesting.computePreferredSize(for: result) == loadingSize)
    }
}
