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
}
