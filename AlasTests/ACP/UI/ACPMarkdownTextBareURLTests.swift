import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("ACPMarkdownText bare URL links")
struct ACPMarkdownTextBareURLTests {
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
}
