import Foundation
import Testing
@testable import Alas

struct WebPageMetadataFetcherTests {
    @Test func extractsJiraMetadataAndIssueKey() {
        let html = """
        <html>
          <head>
            <meta content="ALAS-123" name="ajs-issue-key">
            <meta content="Fix sync &amp; retry behavior - Jira" property="og:title">
            <meta name="description" content="Retries fail after a network change.">
            <link href="https://jira.example.com/browse/ALAS-123" rel="canonical">
          </head>
        </html>
        """

        let result = WebPageMetadataFetcher.parse(
            html: html,
            url: URL(string: "https://jira.example.com/browse/ALAS-123?focused=true")!
        )

        #expect(result.providerLabel == "Jira")
        #expect(result.displayReference == "ALAS-123")
        #expect(result.title == "Fix sync & retry behavior")
        #expect(result.summary == "Retries fail after a network change.")
        #expect(result.canonicalURL.absoluteString == "https://jira.example.com/browse/ALAS-123")
    }

    @Test func extractsLinearOpenGraphMetadataAndRepositoryLink() {
        let html = """
        <html>
          <head>
            <meta property="og:title" content="ALAS-456 Improve mission setup | Linear">
            <meta property="og:description" content="Use the mrmans0n/alas repository.">
          </head>
          <body>
            <a href="https://github.com/mrmans0n/alas/issues/456">Related issue</a>
          </body>
        </html>
        """

        let result = WebPageMetadataFetcher.parse(
            html: html,
            url: URL(string: "https://linear.app/acme/issue/ALAS-456/improve-mission-setup")!
        )

        #expect(result.providerLabel == "Linear")
        #expect(result.displayReference == "ALAS-456")
        #expect(result.title == "ALAS-456 Improve mission setup")
        #expect(result.summary == "Use the mrmans0n/alas repository.")
        #expect(result.links.contains(URL(string: "https://github.com/mrmans0n/alas/issues/456")!))
    }

    @Test func extractsTrelloMetadataAndDecodesJSONLD() {
        let html = """
        <html>
          <head>
            <script type="application/ld+json">
              {
                "@type": "Task",
                "name": "Ship release on Trello",
                "description": "Verify checks, publish, and notify the team."
              }
            </script>
          </head>
        </html>
        """

        let result = WebPageMetadataFetcher.parse(
            html: html,
            url: URL(string: "https://trello.com/c/a1b2c3d4/42-ship-release")!
        )

        #expect(result.providerLabel == "Trello")
        #expect(result.displayReference == "a1b2c3d4")
        #expect(result.title == "Ship release")
        #expect(result.summary == "Verify checks, publish, and notify the team.")
    }

    @Test func rejectsOversizedResponses() async {
        let fetcher = WebPageMetadataFetcher { url in
            .init(
                data: Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1),
                url: url,
                mimeType: "text/html",
                textEncodingName: "utf-8"
            )
        }

        await #expect(throws: WebPageMetadataFetcher.FetchError.responseTooLarge) {
            try await fetcher.metadata(for: URL(string: "https://example.com/ticket/1")!)
        }
    }
}
