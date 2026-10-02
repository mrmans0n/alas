import AppKit
import SwiftUI

/// Maps `HighlightCapture` cases to `NSAttributedString` attribute
/// dictionaries, drawing colors from the existing `Theme` system. Centralizes
/// editor styling so feature code (highlighter, diagnostics, hover) does not
/// reach into theme tokens directly.
///
/// Not marked `Sendable` on purpose: it holds NSColor-bridged values via
/// `Theme`, and is used only on the main thread by the editor coordinator.
struct EditorTheme {
    let theme: Theme

    private var palette: CodePalette? { theme.codePalette }

    var defaultFG: NSColor { palette?.fg ?? nsColor("fg") }
    var bg: NSColor { palette?.bg ?? nsColor("bg-1") }
    var faint: NSColor { palette?.comment ?? nsColor("fg-faint") }
    var gutterFG: NSColor { palette?.gutterFG ?? nsColor("fg-faint") }
    /// Default keeps AppKit's system selection color.
    var selection: NSColor { palette?.selection ?? .selectedTextBackgroundColor }

    /// Foreground attributes for a syntax-highlight capture.
    func attributes(for capture: HighlightCapture) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: color(for: capture)]
    }

    /// Squiggle attributes for a diagnostic of the given LSP severity
    /// (1 = error, 2 = warning, else info/hint).
    func diagnosticAttributes(severity: Int?) -> [NSAttributedString.Key: Any] {
        let style = NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue
        let color: NSColor
        switch severity {
        case 1: color = nsColor("del")
        case 2: color = nsColor("warn")
        default: color = nsColor("info")
        }
        return [
            .underlineStyle: style,
            .underlineColor: color
        ]
    }

    /// The one capture→color mapping for every code surface. On added or
    /// deleted diff lines (`onChangedLine`), comments use the default
    /// foreground so they stay legible over the row tint.
    func color(for capture: HighlightCapture, onChangedLine: Bool = false) -> NSColor {
        if capture == .comment, onChangedLine { return defaultFG }
        if let palette {
            switch capture {
            case .keyword:     return palette.keyword
            case .type:        return palette.type
            case .function:    return palette.function
            case .string:      return palette.string
            case .number:      return palette.number
            case .comment:     return palette.comment
            case .constant:    return palette.constant
            case .attribute:   return palette.attribute
            case .variable, .parameter, .property, .operator, .punctuation, .plain:
                return palette.fg
            }
        }
        switch capture {
        case .keyword:                       return nsColor("syntax-keyword")
        case .type:                          return nsColor("syntax-type")
        case .function:                      return nsColor("syntax-function")
        case .string:                        return nsColor("add")
        case .number:                        return nsColor("mod")
        case .comment:                       return nsColor("fg-faint")
        case .attribute, .constant:          return nsColor("syntax-keyword")
        case .variable, .parameter, .property,
             .operator, .punctuation, .plain:
            return defaultFG
        }
    }

    /// A theme token as an sRGB drawing color; see `NSColor.drawingColor(_:)`.
    private func nsColor(_ token: String) -> NSColor {
        theme.nsColor(token)
    }
}
