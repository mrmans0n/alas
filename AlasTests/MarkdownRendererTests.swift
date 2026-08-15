import Testing
import AppKit
@testable import Alas

@MainActor
struct MarkdownRendererTests {
    static func render(_ source: String) throws -> MarkdownRenderResult {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let parsed = MarkdownParser.parse(source)
        return MarkdownRenderer().render(
            document: parsed.document,
            frontmatter: parsed.frontmatter,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
    }

    @Test func rendersPlainParagraph() throws {
        let r = try MarkdownRendererTests.render("Hello, world.")
        #expect(r.attributedString.string.contains("Hello, world."))
    }

    @Test func appliesBoldFontTrait() throws {
        let r = try MarkdownRendererTests.render("**bold**")
        let s = r.attributedString
        let boldRange = (s.string as NSString).range(of: "bold")
        let font = s.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func appliesItalicFontTrait() throws {
        let r = try MarkdownRendererTests.render("*it*")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "it")
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    @Test func appliesStrikethroughAttribute() throws {
        let r = try MarkdownRendererTests.render("~~gone~~")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "gone")
        let style = s.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int
        #expect((style ?? 0) != 0)
    }

    @Test func appliesMonospaceForInlineCode() throws {
        let r = try MarkdownRendererTests.render("`code`")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "code")
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func consumesSubscriptHTMLTags() throws {
        let r = try MarkdownRendererTests.render("Before <sub><sub>P2</sub></sub> after")
        let s = r.attributedString
        #expect(s.string.contains("Before P2 after"))
        #expect(!s.string.contains("<sub>"))
        #expect(!s.string.contains("</sub>"))

        let range = (s.string as NSString).range(of: "P2")
        let baseline = s.attribute(.baselineOffset, at: range.location, effectiveRange: nil) as? CGFloat
        #expect((baseline ?? 0) < 0)
    }

    @Test func linkRunCarriesURLAttribute() throws {
        let r = try MarkdownRendererTests.render("[example](https://example.com)")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "example")
        let url = s.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com")
    }

    @Test func rendersHeadingLargerThanBody() throws {
        let r = try MarkdownRendererTests.render("# Title")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "Title")
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        // h1 should be visibly larger than the system body font.
        #expect((font?.pointSize ?? 0) > NSFont.systemFontSize)
    }

    @Test func recordsAnchorSlugForHeading() throws {
        let r = try MarkdownRendererTests.render("## Hello World")
        let range = r.anchorRanges["hello-world"]
        #expect(range != nil)
        let nsString = r.attributedString.string as NSString
        if let range {
            #expect(nsString.substring(with: range).contains("Hello World"))
        }
    }

    @Test func slugifyHandlesPunctuationAndCase() throws {
        let r = try MarkdownRendererTests.render("### What's Up, Doc?")
        // Slug rule: lowercase, spaces and punctuation collapsed to "-",
        // edges trimmed. Apostrophes drop, comma+space collapses to "-".
        #expect(r.anchorRanges["whats-up-doc"] != nil)
    }

    @Test func duplicateHeadingSlugsAreDisambiguated() throws {
        let r = try MarkdownRendererTests.render("""
        ## Install
        first
        ## Install
        second
        ## Install
        third
        """)
        // First heading keeps the bare slug; later ones get -1, -2 suffixes
        // (matching GitHub's behavior).
        let nsString = r.attributedString.string as NSString
        guard let first = r.anchorRanges["install"],
              let second = r.anchorRanges["install-1"],
              let third = r.anchorRanges["install-2"] else {
            Issue.record("expected install / install-1 / install-2 anchors")
            return
        }
        // They point at three distinct ranges, in source order.
        #expect(first.location < second.location)
        #expect(second.location < third.location)
        #expect(nsString.substring(with: first).contains("Install"))
        #expect(nsString.substring(with: second).contains("Install"))
        #expect(nsString.substring(with: third).contains("Install"))
    }

    @Test func rendersUnorderedListBullets() throws {
        let r = try MarkdownRendererTests.render("- one\n- two")
        let s = r.attributedString.string
        #expect(s.contains("• one"))
        #expect(s.contains("• two"))
    }

    @Test func rendersOrderedListNumbers() throws {
        let r = try MarkdownRendererTests.render("1. one\n2. two")
        let s = r.attributedString.string
        #expect(s.contains("1. one"))
        #expect(s.contains("2. two"))
    }

    @Test func rendersTaskListCheckboxes() throws {
        let r = try MarkdownRendererTests.render("- [x] done\n- [ ] todo")
        let s = r.attributedString.string
        #expect(s.contains("☑ done"))
        #expect(s.contains("☐ todo"))
    }

    @Test func rendersNestedUnorderedList() throws {
        let r = try MarkdownRendererTests.render("- a\n  - b")
        let s = r.attributedString.string
        // Both items should appear with bullets. Nesting indentation is added
        // via "  " before deeper bullets; checking presence of both is enough.
        #expect(s.contains("• a"))
        #expect(s.contains("• b"))
    }

    @Test func blockquotePreservesLinkAttributes() throws {
        let r = try MarkdownRendererTests.render("> see [docs](https://example.com)")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "docs")
        let url = s.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        // The "│ " rebuild must not strip the inline link attribute.
        #expect(url?.absoluteString == "https://example.com")
    }

    @Test func rendersBlockquoteWithIndent() throws {
        let r = try MarkdownRendererTests.render("> quoted")
        let s = r.attributedString.string
        // Blockquote prefix is a vertical bar character.
        #expect(s.contains("│ quoted"))
    }

    @Test func rendersThematicBreak() throws {
        let r = try MarkdownRendererTests.render("---")
        let s = r.attributedString.string
        // A horizontal-rule run of box-drawing characters is emitted.
        #expect(s.contains(String(repeating: "─", count: 8)))
    }

    @Test func rendersFencedCodeBlockMonospaced() throws {
        let r = try MarkdownRendererTests.render("```\nlet x = 1\n```")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "let x = 1")
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func highlightsSwiftCodeBlockKeyword() throws {
        let r = try MarkdownRendererTests.render("```swift\nfunc f() {}\n```")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "func")
        let color = s.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        // Keyword color is "syntax-keyword". Just confirm it is NOT the default
        // fg ("fg") — any non-default color means the highlighter ran.
        let theme = try Theme.loadBundled(id: "cool-slate")
        let defaultFG = NSColor(theme.color("fg"))
        #expect(color != defaultFG)
    }

    @Test func highlightsNewGrammarCodeBlocks() throws {
        // Regression coverage for the 2026-08 grammar additions: each of
        // these fence labels must resolve through fenceLanguageToExtension
        // and actually highlight, not just render monospaced plain text.
        let theme = try Theme.loadBundled(id: "cool-slate")
        let defaultFG = NSColor(theme.color("fg"))
        let cases: [(label: String, source: String, needle: String)] = [
            ("csharp", "public class Greeter {}", "class"),
            ("elixir", "defmodule Greeter do\nend", "defmodule"),
            ("graphql", "query GetUser { user { name } }", "query"),
            ("zig", "pub fn greet() void {}", "pub"),
            ("ini", "[server]\nhost = localhost", "server")
        ]
        for testCase in cases {
            let r = try MarkdownRendererTests.render("```\(testCase.label)\n\(testCase.source)\n```")
            let s = r.attributedString
            let range = (s.string as NSString).range(of: testCase.needle)
            try #require(range.location != NSNotFound, "\(testCase.label): needle not found in rendered output")
            let color = s.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            #expect(color != defaultFG, "\(testCase.label) did not highlight")
        }
    }

    @Test func unknownLanguageRemainsPlainMonospaced() throws {
        let r = try MarkdownRendererTests.render("```neverheardofit\nfoo\n```")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "foo")
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func mermaidFenceEmitsAttachmentReference() throws {
        let result = try Self.render("""
        ```mermaid
        graph TD; A-->B
        ```
        """)

        #expect(result.mermaidAttachments.count == 1)
        #expect(
            result.mermaidAttachments[0].id
                == "mermaid-\(MarkdownRenderer.stableMermaidSourceKey("graph TD; A-->B"))"
        )
        #expect(result.mermaidAttachments[0].source == "graph TD; A-->B")
        #expect(result.mermaidAttachments[0].profile == .full)
        #expect(result.attributedString.string.contains("graph TD") == false)
    }

    @Test func mermaidAttachmentIDSurvivesEarlierDifferentDiagram() throws {
        let target = "graph TD; Target-->Done"
        let base = try Self.render("""
        ```mermaid
        \(target)
        ```
        """)
        let withEarlierDiagram = try Self.render("""
        ```mermaid
        graph TD; Earlier-->Diagram
        ```

        ```mermaid
        \(target)
        ```
        """)

        let targetID = try #require(base.mermaidAttachments.first?.id)
        let shiftedTargetID = try #require(
            withEarlierDiagram.mermaidAttachments.first { $0.source == target }?.id
        )

        #expect(targetID == shiftedTargetID)
    }

    @Test func duplicateMermaidAttachmentIDsUseSourceLocation() throws {
        let source = "graph TD; Same-->Diagram"
        let result = try Self.render("""
        ```mermaid
        \(source)
        ```

        ```mermaid
        \(source)
        ```
        """)

        #expect(result.mermaidAttachments.count == 2)
        #expect(result.mermaidAttachments[0].source == source)
        #expect(result.mermaidAttachments[1].source == source)
        #expect(result.mermaidAttachments[0].id != result.mermaidAttachments[1].id)
        #expect(result.mermaidAttachments[0].id.contains(MarkdownRenderer.stableMermaidSourceKey(source)))
        #expect(result.mermaidAttachments[1].id.contains(MarkdownRenderer.stableMermaidSourceKey(source)))
    }

    @Test func emptyMermaidFenceRemainsCode() throws {
        let result = try Self.render("```mermaid\n```")

        #expect(result.mermaidAttachments.isEmpty)
    }

    @Test func ordinaryFenceRemainsCode() throws {
        let result = try Self.render("```swift\nlet value = 1\n```")

        #expect(result.mermaidAttachments.isEmpty)
        #expect(result.attributedString.string.contains("let value = 1"))
    }

    private func tableBlock(at substring: String, in attributed: NSAttributedString) -> NSTextTableBlock? {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        return style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.last
    }

    @Test func rendersTableAsNativeTextTable() throws {
        let source = """
        | h1 | h2 |
        | - | - |
        | a | b |
        | longer | x |
        """
        let r = try MarkdownRendererTests.render(source)
        let s = r.attributedString.string

        #expect(s.contains("h1"))
        #expect(s.contains("h2"))
        #expect(s.contains("longer"))
        #expect(!s.contains("|-"))

        let headerBlock = tableBlock(at: "h1", in: r.attributedString)
        let bodyBlock = tableBlock(at: "longer", in: r.attributedString)
        #expect(headerBlock != nil)
        #expect(bodyBlock != nil)
        #expect(headerBlock?.startingRow == 0)
        #expect(bodyBlock?.startingRow == 2)
        #expect(headerBlock?.backgroundColor != nil)
        #expect(bodyBlock?.backgroundColor != nil)
        #expect(headerBlock?.borderColor(for: .minX) != nil)
    }

    @Test func rendersFrontmatterAsNativeMetadataTable() throws {
        let r = try MarkdownRendererTests.render("""
        ---
        title: Example
        date: 2026-05-21
        ---

        # Body
        """)
        let s = r.attributedString.string

        #expect(s.contains("Key"))
        #expect(s.contains("Value"))
        #expect(s.contains("title"))
        #expect(s.contains("Example"))
        #expect(s.contains("Body"))
        #expect(!s.contains("---"))

        let keyBlock = tableBlock(at: "Key", in: r.attributedString)
        let titleBlock = tableBlock(at: "title", in: r.attributedString)
        let exampleBlock = tableBlock(at: "Example", in: r.attributedString)
        #expect(keyBlock != nil)
        #expect(titleBlock != nil)
        #expect(exampleBlock != nil)
        #expect(keyBlock?.startingRow == 0)
        #expect(titleBlock?.startingRow == 1)
        #expect(exampleBlock?.startingColumn == 1)
        #expect(keyBlock?.backgroundColor != nil)
        #expect(titleBlock?.borderColor(for: .minX) != nil)
    }

    @Test func renderingWithoutFrontmatterStaysUnchanged() throws {
        let withNoFrontmatter = try MarkdownRendererTests.render("Hello\n\n---\n\nWorld")
        let directDocument = MarkdownParser.parseDocument("Hello\n\n---\n\nWorld")
        let theme = try Theme.loadBundled(id: "cool-slate")
        let direct = MarkdownRenderer().render(
            document: directDocument,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )

        #expect(withNoFrontmatter.attributedString.string == direct.attributedString.string)
    }

    @Test func tableCellsPreserveInlineMarkdownAttributes() throws {
        let source = """
        | Link | Styled |
        | - | - |
        | [docs](https://example.com) | **bold** `code` |
        """
        let r = try MarkdownRendererTests.render(source)
        let s = r.attributedString

        let linkRange = (s.string as NSString).range(of: "docs")
        let url = s.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        let linkBlock = tableBlock(at: "docs", in: s)
        #expect(linkBlock != nil)
        #expect(url?.absoluteString == "https://example.com")

        let boldRange = (s.string as NSString).range(of: "bold")
        let boldFont = s.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let boldBlock = tableBlock(at: "bold", in: s)
        #expect(boldBlock != nil)
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        let codeRange = (s.string as NSString).range(of: "code")
        let codeFont = s.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        let codeBackground = s.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
        let codeBlock = tableBlock(at: "code", in: s)
        let boldBackground = s.attribute(.backgroundColor, at: boldRange.location, effectiveRange: nil) as? NSColor
        #expect(codeBlock != nil)
        #expect(codeFont?.isFixedPitch == true)
        #expect(codeBackground != nil)
        #expect(codeBackground != boldBackground)
    }

    @Test func tableHeaderCellsPreserveInlineMarkdownFonts() throws {
        let source = """
        | `code` | *italic* |
        | - | - |
        | value | value |
        """
        let r = try MarkdownRendererTests.render(source)
        let s = r.attributedString

        let codeRange = (s.string as NSString).range(of: "code")
        let codeFont = s.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        let codeBackground = s.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
        let codeBlock = tableBlock(at: "code", in: s)
        #expect(codeBlock != nil)
        #expect(codeFont?.isFixedPitch == true)
        #expect(codeBackground != nil)

        let italicRange = (s.string as NSString).range(of: "italic")
        let italicFont = s.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        let italicBlock = tableBlock(at: "italic", in: s)
        #expect(italicBlock != nil)
        #expect(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    @Test func tableCellsUseGFMColumnAlignment() throws {
        let source = """
        | Left | Center | Right |
        | :--- | :----: | ----: |
        | L0 | C0 | R0 |
        """
        let r = try MarkdownRendererTests.render(source)
        let s = r.attributedString

        let leftRange = (s.string as NSString).range(of: "L0")
        let centerRange = (s.string as NSString).range(of: "C0")
        let rightRange = (s.string as NSString).range(of: "R0")

        let leftStyle = s.attribute(.paragraphStyle, at: leftRange.location, effectiveRange: nil) as? NSParagraphStyle
        let centerStyle = s.attribute(.paragraphStyle, at: centerRange.location, effectiveRange: nil) as? NSParagraphStyle
        let rightStyle = s.attribute(.paragraphStyle, at: rightRange.location, effectiveRange: nil) as? NSParagraphStyle

        #expect(leftStyle?.alignment == .left)
        #expect(centerStyle?.alignment == .center)
        #expect(rightStyle?.alignment == .right)
    }

    @Test func rendersLocalImageAsAttachment() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-md-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("dot.png")
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: imageURL)
        }

        let theme = try Theme.loadBundled(id: "cool-slate")
        let r = MarkdownRenderer().render(
            document: MarkdownParser.parseDocument("![alt](dot.png)"),
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: tmp
        )
        // Locate the attachment character (Unicode Object Replacement Character = 0xFFFC).
        let attachChar = String(UnicodeScalar(0xFFFC)!)
        #expect(r.attributedString.string.contains(attachChar))
    }

    @Test func rendersRemoteImagePlaceholderAndRecordsRef() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let r = MarkdownRenderer().render(
            document: MarkdownParser.parseDocument("![logo](https://example.com/logo.png)"),
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        #expect(r.remoteImages.count == 1)
        #expect(r.remoteImages.first?.url.absoluteString == "https://example.com/logo.png")
    }

    @Test func brokenLocalImageRendersAltText() throws {
        let r = try MarkdownRendererTests.render("![alt-text](nope-\(UUID().uuidString).png)")
        let s = r.attributedString.string
        #expect(s.contains("alt-text"))
    }
}
