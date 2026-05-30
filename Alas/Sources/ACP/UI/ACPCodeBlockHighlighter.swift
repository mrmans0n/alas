import AppKit
import Foundation

enum ACPCodeLanguage {
    static func highlighterExtension(for label: String?) -> String? {
        guard let label else { return nil }
        var normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let first = normalized.split(whereSeparator: { $0.isWhitespace }).first {
            normalized = String(first)
        }
        normalized = normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            .lowercased()

        if normalized.hasPrefix("{"), normalized.hasSuffix("}") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        if normalized.hasPrefix(".") {
            normalized = String(normalized.dropFirst())
        }

        switch normalized {
        case "swift": return "swift"
        case "py", "python": return "py"
        case "js", "javascript", "mjs", "cjs": return "js"
        case "jsx": return "jsx"
        case "ts", "typescript": return "ts"
        case "tsx": return "tsx"
        case "sh", "bash", "shell", "zsh", "console", "terminal": return "sh"
        case "md", "markdown": return "md"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "rs", "rust": return "rs"
        case "go", "golang": return "go"
        case "java": return "java"
        case "kt", "kotlin": return "kt"
        case "kts": return "kts"
        case "c": return "c"
        case "h": return "h"
        case "cpp", "c++": return "cpp"
        case "cc": return "cc"
        case "cxx": return "cxx"
        case "hpp": return "hpp"
        case "hh": return "hh"
        case "hxx": return "hxx"
        case "diff": return "diff"
        case "patch": return "patch"
        case "html": return "html"
        case "xml": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "sass": return "sass"
        case "sql", "rb", "ruby", "php", "pl", "perl", "lua", "ex", "exs", "elixir", "dockerfile", "ini":
            return nil
        default: return nil
        }
    }
}

enum ACPCodeBlockHighlighter {
    static func attributedString(
        code: String,
        language: String?,
        theme: Theme,
        fontSize: CGFloat = 12
    ) -> NSAttributedString {
        let editorTheme = EditorTheme(theme: theme)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: editorTheme.defaultFG,
        ]
        let attributed = NSMutableAttributedString(string: code, attributes: baseAttributes)
        guard !code.isEmpty,
              let ext = ACPCodeLanguage.highlighterExtension(for: language) else {
            return attributed
        }

        let length = (code as NSString).length
        let spans = TreeSitterHighlighter.highlight(source: code, fileExtension: ext)
        for span in spans {
            guard span.range.location != NSNotFound,
                  span.range.location >= 0,
                  NSMaxRange(span.range) <= length else {
                continue
            }
            attributed.addAttributes(editorTheme.attributes(for: span.capture), range: span.range)
        }
        return attributed
    }
}
