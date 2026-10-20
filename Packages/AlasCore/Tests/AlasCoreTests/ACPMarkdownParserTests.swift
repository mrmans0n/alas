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
        ("```html\n<!-- literal -->\n```\n<!-- hidden -->", "```html\n<!-- literal -->\n```\n"),
        ("~~~html\n<!-- literal -->\n~~~\n<!-- hidden -->", "~~~html\n<!-- literal -->\n~~~\n"),
        (#"\<!-- literal -->"#, #"\<!-- literal -->"#)
    ])
    func hidesMetadataWithoutRemovingCode(input: String, expected: String) {
        #expect(ACPMarkdownParser.hidingHTMLComments(input) == expected)
    }
}
