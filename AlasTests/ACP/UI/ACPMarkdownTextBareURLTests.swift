import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("ACPMarkdownText bare URL links")
struct ACPMarkdownTextBareURLTests {
    @Test("mermaid recognition uses the first case-insensitive fence token")
    func mermaidFenceRecognition() {
        #expect(ACPMarkdownText.parse("""
        ```MERMAID title=Architecture
        graph TD; A-->B
        ```
        """) == [.mermaid(source: "graph TD; A-->B")])

        #expect(ACPMarkdownText.parse("""
        ```swift mermaid
        graph TD; A-->B
        ```
        """) == [.code(language: "swift mermaid", body: "graph TD; A-->B")])

        #expect(ACPMarkdownText.parse("""
        ```mermaid
        ```
        """) == [.code(language: "mermaid", body: "")])
    }

    @Test("tilde fenced URL parses as code block")
    func tildeFencedURLParsesAsCodeBlock() {
        let blocks = ACPMarkdownText.parse("""
        ~~~sh
        curl https://example.com/api
        ~~~
        """)
        #expect(blocks == [
            .code(language: "sh", body: "curl https://example.com/api"),
        ])
    }

    @Test("tilde fence closer rejects trailing non-whitespace text")
    func tildeFenceCloserRejectsTrailingNonWhitespaceText() {
        let blocks = ACPMarkdownText.parse("""
        ~~~sh
        curl https://example.com/api
        ~~~not-a-close
        curl https://example.com/next
        ~~~
        """)
        #expect(blocks == [
            .code(language: "sh", body: """
            curl https://example.com/api
            ~~~not-a-close
            curl https://example.com/next
            """),
        ])
    }

    @Test("four-space indented tilde fence stays paragraph text")
    func fourSpaceIndentedTildeFenceStaysParagraphText() {
        let blocks = ACPMarkdownText.parse("""
            ~~~
            curl https://example.com/api
            ~~~
        """)
        #expect(blocks == [
            .paragraph("    ~~~\n    curl https://example.com/api\n    ~~~"),
        ])
    }

    @Test("bare https URL carries a link attribute")
    func bareURLCarriesLinkAttribute() throws {
        let attributed = NSAttributedString(
            ACPMarkdownText.inlineMarkdown("See https://example.com/path for details.")
        )
        let range = (attributed.string as NSString).range(of: "https://example.com/path")
        try #require(range.location != NSNotFound)
        let url = attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com/path")
    }

    @Test("existing Markdown link and bare URL both remain clickable")
    func existingMarkdownLinkAndBareURLRemainClickable() throws {
        let attributed = NSAttributedString(
            ACPMarkdownText.inlineMarkdown("See [docs](https://example.com/docs) and https://example.com/raw.")
        )
        let docsRange = (attributed.string as NSString).range(of: "docs")
        let rawRange = (attributed.string as NSString).range(of: "https://example.com/raw")
        try #require(docsRange.location != NSNotFound)
        try #require(rawRange.location != NSNotFound)
        let docsURL = attributed.attribute(.link, at: docsRange.location, effectiveRange: nil) as? URL
        let rawURL = attributed.attribute(.link, at: rawRange.location, effectiveRange: nil) as? URL
        #expect(docsURL?.absoluteString == "https://example.com/docs")
        #expect(rawURL?.absoluteString == "https://example.com/raw")
    }

    @Test("inline code URL is not clickable")
    func inlineCodeURLIsNotClickable() throws {
        let attributed = NSAttributedString(
            ACPMarkdownText.inlineMarkdown("Run `curl https://example.com/api`.")
        )
        let range = (attributed.string as NSString).range(of: "https://example.com/api")
        try #require(range.location != NSNotFound)
        let url = attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        #expect(url == nil)
    }

    @Test("bracketed bare URL is clickable")
    func bracketedBareURLIsClickable() throws {
        let attributed = NSAttributedString(
            ACPMarkdownText.inlineMarkdown("See [https://example.com].")
        )
        let range = (attributed.string as NSString).range(of: "https://example.com")
        try #require(range.location != NSNotFound)
        let url = attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com")
    }

    @Test("emphasized bare URL is clickable")
    func emphasizedBareURLIsClickable() throws {
        let attributed = NSAttributedString(
            ACPMarkdownText.inlineMarkdown("See **https://example.com/strong**.")
        )
        let range = (attributed.string as NSString).range(of: "https://example.com/strong")
        try #require(range.location != NSNotFound)
        let url = attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com/strong")
    }

    @Test("trailing punctuation is not part of the link")
    func trailingPunctuationIsNotPartOfLink() throws {
        let attributed = NSAttributedString(
            ACPMarkdownText.inlineMarkdown("Open (https://example.com/path), then stop.")
        )
        let range = (attributed.string as NSString).range(of: "https://example.com/path")
        try #require(range.location != NSNotFound)
        var effectiveRange = NSRange(location: 0, length: 0)
        let url = attributed.attribute(.link, at: range.location, effectiveRange: &effectiveRange) as? URL
        #expect(url?.absoluteString == "https://example.com/path")
        #expect(effectiveRange == range)
    }

    @Test("bare URL with markdown delimiter stays one link")
    func bareURLWithMarkdownDelimiterStaysOneLink() throws {
        let attributed = NSAttributedString(
            ACPMarkdownText.inlineMarkdown("Open https://example.com/foo*bar* now.")
        )
        let range = (attributed.string as NSString).range(of: "https://example.com/foo*bar*")
        try #require(range.location != NSNotFound)
        var effectiveRange = NSRange(location: 0, length: 0)
        let url = attributed.attribute(.link, at: range.location, effectiveRange: &effectiveRange) as? URL
        #expect(url?.absoluteString == "https://example.com/foo*bar*")
        #expect(effectiveRange == range)
    }

    @Test("non-memoized inline markdown does not populate cache")
    func nonMemoizedInlineMarkdownDoesNotPopulateCache() {
        ACPMarkdownText.removeAllInlineCacheObjectsForTesting()

        _ = ACPMarkdownText.inlineMarkdown("streamed **prefix**", memoize: false)
        #expect(ACPMarkdownText.inlineCacheInsertionCountForTesting == 0)

        _ = ACPMarkdownText.inlineMarkdown("stable **block**")
        #expect(ACPMarkdownText.inlineCacheInsertionCountForTesting == 1)

        _ = ACPMarkdownText.inlineMarkdown("stable **block**")
        #expect(ACPMarkdownText.inlineCacheInsertionCountForTesting == 1)
    }
}
