import Foundation
import Testing
@testable import Alas

@Suite("ACPBareURLLinkifier")
struct ACPBareURLLinkifierTests {
    @Test("rewrites bare https URL to Markdown autolink")
    func rewritesBareURL() {
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            "See https://example.com/path for details.",
            preserveFencedCodeBlocks: true
        )
        #expect(output == "See <https://example.com/path> for details.")
    }

    @Test("preserves existing Markdown links and autolinks")
    func preservesExistingMarkdownLinks() {
        let input = "See [docs](https://example.com/docs) and <https://example.com/raw>."
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == input)
    }

    @Test("skips inline code spans")
    func skipsInlineCode() {
        let input = "Run `curl https://example.com/api` and then open https://example.com/docs."
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == "Run `curl https://example.com/api` and then open <https://example.com/docs>.")
    }

    @Test("skips fenced code blocks")
    func skipsFencedCodeBlocks() {
        let input = """
        Before https://example.com/start.

        ```sh
        curl https://example.com/api
        ```

        After https://example.com/end.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Before <https://example.com/start>.

        ```sh
        curl https://example.com/api
        ```

        After <https://example.com/end>.
        """)
    }

    @Test("excludes trailing prose punctuation")
    func excludesTrailingPunctuation() {
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            "Open (https://example.com/path), then stop.",
            preserveFencedCodeBlocks: true
        )
        #expect(output == "Open (<https://example.com/path>), then stop.")
    }

    @Test("does not rewrite scheme-less or non-web URLs")
    func ignoresUnsupportedURLs() {
        let input = "Visit example.com, mailto:test@example.com, and file:///tmp/a."
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == input)
    }
}
