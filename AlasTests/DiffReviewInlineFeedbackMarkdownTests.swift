import Testing
@testable import Alas

@Suite("DiffReviewInlineFeedbackMarkdown")
struct DiffReviewInlineFeedbackMarkdownTests {
    @MainActor
    @Test("review plain text retains Mermaid source")
    func reviewPlainTextRetainsSource() {
        let source = """
        ```mermaid
        graph TD; A-->B
        ```
        """

        #expect(DiffReviewInlineFeedbackMarkdown.plainText(source).contains("graph TD; A-->B"))
    }
}
