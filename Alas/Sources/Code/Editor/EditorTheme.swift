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

    var defaultFG: NSColor { nsColor("fg") }
    var bg: NSColor { nsColor("bg-1") }
    var faint: NSColor { nsColor("fg-faint") }

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

    private func color(for capture: HighlightCapture) -> NSColor {
        switch capture {
        case .keyword:                       return nsColor("syntax-keyword")
        case .type:                          return nsColor("syntax-type")
        case .function:                      return nsColor("syntax-function")
        case .string:                        return nsColor("add")
        case .number:                        return nsColor("mod")
        case .comment:                       return nsColor("fg-faint")
        case .attribute:                     return nsColor("syntax-keyword")
        case .constant, .variable,
             .parameter, .property,
             .operator, .punctuation, .plain:
            return defaultFG
        }
    }

    /// Bridge `theme.color(_:)` (SwiftUI `Color`) to `NSColor`. Works on
    /// macOS 12+; the project deploys to macOS 14.
    private func nsColor(_ token: String) -> NSColor {
        NSColor(theme.color(token))
    }
}
