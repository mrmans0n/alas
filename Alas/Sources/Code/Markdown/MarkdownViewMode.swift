import Foundation

/// View mode for a markdown editor tab. Persisted in `EditorTabState`
/// and in `AppConfig.markdown.defaultViewMode`. Raw values are part of
/// the on-disk format — do not rename.
enum MarkdownViewMode: String, Codable, Equatable, Sendable, CaseIterable {
    case editor, split, preview

    /// Cycle order used by the `⌘⇧M` shortcut: editor → split → preview → editor.
    func next() -> MarkdownViewMode {
        switch self {
        case .editor:  return .split
        case .split:   return .preview
        case .preview: return .editor
        }
    }
}
