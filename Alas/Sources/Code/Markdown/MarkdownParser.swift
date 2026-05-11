import Foundation
import Markdown

/// Thin wrapper over `swift-markdown`'s `Document.init(parsing:options:)`.
/// Provides a single, tested entry point so the renderer never has to
/// remember the option set. GFM tables, task lists, strikethrough, and
/// autolinks are enabled by default in current `swift-markdown` releases.
enum MarkdownParser {
    static func parse(_ source: String) -> Document {
        Document(parsing: source)
    }
}
