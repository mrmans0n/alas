import Testing
import AppKit
@testable import Alas

@MainActor
struct MarkdownRendererTests {
    static func render(_ source: String) throws -> MarkdownRenderResult {
        let theme = try Theme.loadBundled(id: "cool-slate")
        return MarkdownRenderer().render(
            document: MarkdownParser.parse(source),
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

    @Test func unknownLanguageRemainsPlainMonospaced() throws {
        let r = try MarkdownRendererTests.render("```neverheardofit\nfoo\n```")
        let s = r.attributedString
        let range = (s.string as NSString).range(of: "foo")
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func rendersTableAsAlignedMonospaceText() throws {
        let source = """
        | h1 | h2 |
        | - | - |
        | a | b |
        | longer | x |
        """
        let r = try MarkdownRendererTests.render(source)
        let s = r.attributedString.string
        // All cells appear.
        #expect(s.contains("h1"))
        #expect(s.contains("h2"))
        #expect(s.contains("longer"))
        // Aligned: the column for h1/longer is at least 6 wide, so "h1" is
        // followed by trailing spaces before the next cell separator.
        #expect(s.contains("h1    "))
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
            document: MarkdownParser.parse("![alt](dot.png)"),
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
            document: MarkdownParser.parse("![logo](https://example.com/logo.png)"),
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
