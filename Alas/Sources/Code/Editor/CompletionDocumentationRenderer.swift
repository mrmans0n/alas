import Foundation
import Markdown

@MainActor
enum CompletionDocumentationRenderer {
    static func text(_ markup: LSPMarkup?) -> String? {
        switch markup {
        case .plain(let text), .markupContent(_, let text): text
        case nil: nil
        }
    }
    static func render(
        _ documentation: String,
        theme: Theme,
        monospacedFontFamily: String,
        monospacedFontSize: Int
    ) -> MarkdownRenderResult {
        MarkdownRenderer().render(
            document: Document(parsing: documentation),
            theme: theme,
            monospacedFontFamily: monospacedFontFamily,
            monospacedFontSize: monospacedFontSize,
            baseDirectory: URL(fileURLWithPath: "/"),
            mermaidProfile: .compact
        )
    }
}
