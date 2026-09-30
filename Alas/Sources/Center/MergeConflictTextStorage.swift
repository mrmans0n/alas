import AppKit
import SwiftUI

/// Shared helpers for producing themed, syntax-highlighted
/// `NSAttributedString`s for the merge editor columns. Pure functions
/// — no state of their own. Uses `TreeSitterHighlighter` for highlighting,
/// with regex fallback handled internally by the highlighter.
enum MergeConflictTextStorage {
    /// Whether a column must re-render: the text changed, or the theme did
    /// (including a code theme switch, which leaves the text untouched but
    /// changes every foreground and syntax attribute).
    static func needsRebuild(renderedText: String, text: String, renderedTheme: Theme?, theme: Theme) -> Bool {
        renderedText != text || renderedTheme != theme
    }

    /// Produces a themed attributed string for `text` with syntax
    /// highlighting based on `fileExtension`. Falls back to plain
    /// monospaced text when no language is registered for the extension.
    static func highlightedAttributedString(
        text: String,
        fileExtension: String,
        fontFamily: String,
        fontSize: CGFloat,
        theme: Theme
    ) -> NSMutableAttributedString {
        let font = CenterTypography.resolveCodeFont(family: fontFamily, size: fontSize)
        let editorTheme = EditorTheme(theme: theme)
        let base = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: editorTheme.defaultFG
            ]
        )

        let spans = TreeSitterHighlighter.highlight(source: text, fileExtension: fileExtension)
        for span in spans {
            guard span.range.location + span.range.length <= base.length else { continue }
            let attrs = editorTheme.attributes(for: span.capture)
            base.addAttributes(attrs, range: span.range)
        }
        return base
    }
}
