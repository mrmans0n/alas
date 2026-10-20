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
}
