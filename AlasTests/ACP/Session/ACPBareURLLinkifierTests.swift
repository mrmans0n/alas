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

    @Test("linkifies missing reference-style link text")
    func linkifiesMissingReferenceStyleLinkText() {
        let input = "See [https://example.com][ref] and then https://example.org."
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == "See [<https://example.com>][ref] and then <https://example.org>.")
    }

    @Test("linkifies bracketed URL text without a reference definition")
    func linkifiesBracketedURLTextWithoutReferenceDefinition() {
        let input = "See [https://example.com] and then https://example.org."
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == "See [<https://example.com>] and then <https://example.org>.")
    }

    @Test("preserves defined reference-style and shortcut link text")
    func preservesDefinedReferenceLinkText() {
        let input = """
        See [https://example.com][ref] and [https://shortcut.example].

        [ref]: https://target.example
        [https://shortcut.example]: https://shortcut-target.example
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == input)
    }

    @Test("preserves defined shortcut reference followed by punctuation")
    func preservesDefinedShortcutReferenceWithPunctuation() {
        let input = """
        See [https://example.com].

        [https://example.com]: https://target.example
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == input)
    }

    @Test("linkifies shortcut text when the matching no-destination definition is invalid")
    func linkifiesShortcutTextWhenNoDestinationDefinitionIsInvalid() {
        let input = """
        [https://example.com]:

        [https://example.com]
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        [https://example.com]:

        [<https://example.com>]
        """)
    }

    @Test("preserves reference definitions and indented continuations")
    func preservesReferenceDefinitionsAndContinuations() {
        let input = """
        [inline]: https://example.com/path "https://title.example"
        [continued]:
          https://continued.example/path
          "https://continued-title.example"

        See https://prose.example.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        [inline]: https://example.com/path "https://title.example"
        [continued]:
          https://continued.example/path
          "https://continued-title.example"

        See <https://prose.example>.
        """)
    }

    @Test("preserves inline links with nested brackets in label")
    func preservesInlineLinksWithNestedBracketsInLabel() {
        let input = "See [see [nested] https://example.com](https://target.example) and https://example.org."
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == "See [see [nested] https://example.com](https://target.example) and <https://example.org>.")
    }

    @Test("preserves inline links with quoted title containing URL")
    func preservesInlineLinksWithQuotedTitleContainingURL() {
        let input = #"See [x](https://target.example "title) https://example.com")"#
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == input)
    }

    @Test("preserves inline links with apostrophe in destination")
    func preservesInlineLinksWithApostropheInDestination() {
        let input = "See [x](https://example.com/it's)"
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

    @Test("skips inline code spans with multiple backticks")
    func skipsMultiBacktickInlineCode() {
        let input = "Run ``curl https://example.com/api`` and then open https://example.com/docs."
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == "Run ``curl https://example.com/api`` and then open <https://example.com/docs>.")
    }

    @Test("skips inline code spans across lines")
    func skipsMultilineInlineCode() {
        let input = """
        Run `curl
        https://example.com/api`
        Then open https://example.com/docs.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Run `curl
        https://example.com/api`
        Then open <https://example.com/docs>.
        """)
    }

    @Test("treats unmatched single backtick as literal text")
    func treatsUnmatchedSingleBacktickAsLiteralText() {
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            "Typo ` before https://example.com",
            preserveFencedCodeBlocks: true
        )
        #expect(output == "Typo ` before <https://example.com>")
    }

    @Test("treats unmatched double backtick as literal text")
    func treatsUnmatchedDoubleBacktickAsLiteralText() {
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            "Typo `` before https://example.com",
            preserveFencedCodeBlocks: true
        )
        #expect(output == "Typo `` before <https://example.com>")
    }

    @Test("treats multiline unmatched code delimiter as literal text")
    func treatsMultilineUnmatchedCodeDelimiterAsLiteralText() {
        let input = """
        Typo ` before
        https://example.com
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Typo ` before
        <https://example.com>
        """)
    }

    @Test("does not carry unmatched code span across blank line")
    func doesNotCarryUnmatchedCodeSpanAcrossBlankLine() {
        let input = """
        Typo ` starts here

        Open https://example.com/docs before ` another tick.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Typo ` starts here

        Open <https://example.com/docs> before ` another tick.
        """)
    }

    @Test("rewrites fenced URLs when fence preservation is disabled")
    func rewritesFencedURLsWhenFencePreservationIsDisabled() {
        let input = """
        ```sh
        curl https://example.com/api
        ```
        Run `curl https://example.com/inline` and open https://example.com/docs.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: false
        )
        #expect(output == """
        ```sh
        curl <https://example.com/api>
        ```
        Run `curl https://example.com/inline` and open <https://example.com/docs>.
        """)
    }

    @Test("does not carry unmatched code span across blank line when fence preservation is disabled")
    func doesNotCarryUnmatchedCodeSpanAcrossBlankLineWhenFencePreservationIsDisabled() {
        let input = """
        Typo ` starts here

        Open https://example.com/docs before ` another tick.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: false
        )
        #expect(output == """
        Typo ` starts here

        Open <https://example.com/docs> before ` another tick.
        """)
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

    @Test("does not treat four-space indented backtick line as fence")
    func ignoresFourSpaceIndentedBacktickFenceLine() {
        let input = """
        Before https://example.com/start.

            ```
        https://example.com/not-code
            ```

        After https://example.com/end.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Before <https://example.com/start>.

            ```
        <https://example.com/not-code>
            ```

        After <https://example.com/end>.
        """)
    }

    @Test("does not close longer backtick fence with shorter backtick fence")
    func keepsLongerBacktickFenceOpenAcrossShorterFence() {
        let input = """
        Before https://example.com/start.

        ````sh
        curl https://example.com/api
        ```
        curl https://example.com/after-shorter-fence
        ````

        After https://example.com/end.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Before <https://example.com/start>.

        ````sh
        curl https://example.com/api
        ```
        curl https://example.com/after-shorter-fence
        ````

        After <https://example.com/end>.
        """)
    }

    @Test("does not close backtick fence with trailing text")
    func keepsBacktickFenceOpenAcrossClosingFenceWithTrailingText() {
        let input = """
        Before https://example.com/start.

        ```swift
        curl https://example.com/api
        ```not-a-close
        curl https://example.com/after-invalid-close
        ```

        After https://example.com/end.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Before <https://example.com/start>.

        ```swift
        curl https://example.com/api
        ```not-a-close
        curl https://example.com/after-invalid-close
        ```

        After <https://example.com/end>.
        """)
    }

    @Test("skips tilde fenced code blocks")
    func skipsTildeFencedCodeBlocks() {
        let input = """
        Before https://example.com/start.

        ~~~sh
        curl https://example.com/api
        ~~~

        After https://example.com/end.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Before <https://example.com/start>.

        ~~~sh
        curl https://example.com/api
        ~~~

        After <https://example.com/end>.
        """)
    }

    @Test("does not close tilde fence with trailing text")
    func keepsTildeFenceOpenAcrossClosingFenceWithTrailingText() {
        let input = """
        Before https://example.com/start.

        ~~~sh
        curl https://example.com/api
        ~~~not-a-close
        curl https://example.com/after-invalid-close
        ~~~

        After https://example.com/end.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Before <https://example.com/start>.

        ~~~sh
        curl https://example.com/api
        ~~~not-a-close
        curl https://example.com/after-invalid-close
        ~~~

        After <https://example.com/end>.
        """)
    }

    @Test("does not close longer tilde fence with shorter tilde fence")
    func keepsLongerTildeFenceOpenAcrossShorterFence() {
        let input = """
        Before https://example.com/start.

        ~~~~sh
        curl https://example.com/api
        ~~~
        curl https://example.com/after-shorter-fence
        ~~~~

        After https://example.com/end.
        """
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == """
        Before <https://example.com/start>.

        ~~~~sh
        curl https://example.com/api
        ~~~
        curl https://example.com/after-shorter-fence
        ~~~~

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

    @Test("rewrites bare http URL to Markdown autolink")
    func rewritesBareHTTPURL() {
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            "See http://example.com/path for details.",
            preserveFencedCodeBlocks: true
        )
        #expect(output == "See <http://example.com/path> for details.")
    }

    @Test("does not double-wrap malformed angle autolink")
    func doesNotDoubleWrapMalformedAngleAutolink() {
        let input = "Open <https://example.com"
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == input)
    }

    @Test("does not rewrite degenerate web URL")
    func doesNotRewriteDegenerateWebURL() {
        let input = "Open https://. and https://."
        let output = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            input,
            preserveFencedCodeBlocks: true
        )
        #expect(output == input)
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
