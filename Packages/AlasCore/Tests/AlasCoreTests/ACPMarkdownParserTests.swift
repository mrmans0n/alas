import Testing
@testable import AlasCore

struct ACPMarkdownParserTests {
    @Test(arguments: [
        ("Finding\n\n<!-- codex-code-review-finding:v1 -->", "Finding\n\n"),
        ("Before<!-- hidden\nmetadata -->after", "Before\nafter"),
        ("a<!-- one -->b<!-- two -->c", "abc"),
        ("Visible<!-- unfinished", "Visible"),
        ("`<!-- literal -->`<!-- hidden -->", "`<!-- literal -->`"),
        ("`` `<!-- literal -->` ``<!-- hidden -->", "`` `<!-- literal -->` ``"),
        ("`before\n<!-- literal -->\nafter`<!-- hidden -->", "`before\n<!-- literal -->\nafter`"),
        ("``before\n`<!-- literal -->`\nafter``", "``before\n`<!-- literal -->`\nafter``"),
        ("`unmatched\n<!-- hidden -->", "`unmatched\n"),
        ("`before\n\n<!-- metadata -->\nafter`", "`before\n\n\nafter`"),
        ("`before\n# Heading `\n<!-- metadata -->", "`before\n# Heading `\n"),
        ("`before\n> quote `\n<!-- metadata -->", "`before\n> quote `\n"),
        ("`before\n- [ ] task `\n<!-- metadata -->", "`before\n- [ ] task `\n"),
        ("`before\n```html\n<!-- literal -->\n```\nafter`", "`before\n```html\n<!-- literal -->\n```\nafter`"),
        ("# Heading `\n<!-- metadata -->\nafter`", "# Heading `\n\nafter`"),
        ("```html\n<!-- literal -->\n```\n<!-- hidden -->", "```html\n<!-- literal -->\n```\n"),
        ("~~~html\n<!-- literal -->\n~~~\n<!-- hidden -->", "~~~html\n<!-- literal -->\n~~~\n"),
        (#"\<!-- literal -->"#, #"\<!-- literal -->"#)
    ])
    func hidesMetadataWithoutRemovingCode(input: String, expected: String) {
        #expect(ACPMarkdownParser.hidingHTMLComments(input) == expected)
    }

    @Test(arguments: [
        ("| `open <!-- metadata --> | close` |", "| `open  | close` |"),
        ("| `open <!-- metadata --> | other |\n| close` | other |",
         "| `open  | other |\n| close` | other |"),
        ("| `<!-- literal -->` | <!-- metadata --> |", "| `<!-- literal -->` |  |")
    ])
    func tableCellsHaveIndependentCodeSpans(row: String, expected: String) {
        let header = "| First | Second |\n| --- | --- |\n"
        let visible = ACPMarkdownParser.hidingHTMLComments(header + row)
        #expect(visible == header + expected)
    }

    @Test(arguments: [
        ("| <!-- hidden | Visible |", [["", "Visible"]]),
        ("| <!-- hidden | Visible --> |", [["", "Visible -->"]]),
        ("| Visible | <!-- hidden\n| Next | Row |", [["Visible", ""], ["Next", "Row"]])
    ])
    func tableCellsHaveIndependentComments(row: String, expected: [[String]]) {
        let header = "| First | Second |\n| --- | --- |\n"
        let visible = ACPMarkdownParser.hidingHTMLComments(header + row)
        #expect(ACPMarkdownParser.parse(visible) == [.table(header: ["First", "Second"], rows: expected)])
    }

    @Test(arguments: [
        ("\n\nVisible", [ACPMarkdownParser.Block.paragraph("Visible")]),
        ("\n# Visible", [.heading(level: 1, text: "Visible")]),
        ("\n- [ ] Visible", [.taskList([.init(isChecked: false, text: "Visible")])]),
        ("\n![Visible](image.png)", [.image(alt: "Visible", source: "image.png")]),
        ("\n```html\n<!-- literal -->\n```", [.code(language: "html", body: "<!-- literal -->")]),
        ("\n> Visible", [.quote("Visible")]),
        ("\n\n| Header |\n| --- |\n| Visible |", [.table(header: ["Header"], rows: [["Visible"]])])
    ])
    func unfinishedCommentsDoNotConsumeFollowingBlocks(suffix: String, expected: [ACPMarkdownParser.Block]) {
        let visible = ACPMarkdownParser.hidingHTMLComments("Intro <!--" + suffix)
        #expect(ACPMarkdownParser.parse(visible) == [.paragraph("Intro ")] + expected)
    }

    @Test
    func multilineQuoteCommentsPreserveQuoteStructure() {
        let visible = ACPMarkdownParser.hidingHTMLComments("> Before <!--\n> metadata --> Visible")
        #expect(ACPMarkdownParser.parse(visible) == [.quote("Before\n Visible")])
    }

    @Test
    func prosePipesDoNotSplitMultilineCodeSpans() {
        let source = "`before | text\n<!-- literal -->\nafter`"
        #expect(ACPMarkdownParser.hidingHTMLComments(source) == source)
    }
}
