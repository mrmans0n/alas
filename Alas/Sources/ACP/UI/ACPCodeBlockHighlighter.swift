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

        return canonicalExtension(for: normalized)
    }

    static func highlighterExtension(forPath path: String?) -> String? {
        guard let path else { return nil }
        let ext = LanguageRegistry.highlighterExtension(forPath: path)
        guard !ext.isEmpty else { return nil }
        return supportedHighlighterExtension(ext)
    }

    private static func canonicalExtension(for normalized: String) -> String? {
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
        case "htm": return "htm"
        case "xml": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "sass": return "sass"
        case "rb", "ruby": return "rb"
        case "lua": return "lua"
        case "php": return "php"
        case "hcl": return "hcl"
        case "tf", "terraform": return "tf"
        case "tfvars": return "tfvars"
        case "dockerfile": return "dockerfile"
        case "sql": return "sql"
        case "cs", "csharp", "c#": return "cs"
        case "scala": return "scala"
        case "r": return "r"
        case "dart": return "dart"
        case "ex", "exs", "elixir": return "ex"
        case "erl", "erlang": return "erl"
        case "hs", "haskell": return "hs"
        case "clj", "cljs", "cljc", "edn", "clojure": return "clj"
        case "jl", "julia": return "jl"
        case "zig": return "zig"
        case "ps1", "pwsh", "powershell": return "ps1"
        case "groovy", "gradle": return "groovy"
        case "objc", "objective-c", "objectivec", "m", "mm": return "m"
        case "graphql", "gql": return "graphql"
        case "proto", "protobuf": return "proto"
        case "svelte": return "svelte"
        case "ini", "dosini", "properties", "cfg": return "ini"
        case "make", "makefile", "mk": return "mk"
        case "cmake": return "cmake"
        // No tree-sitter-perl grammar exists (see ThirdParty/treesitter-pack's
        // Cargo.toml for why), so Perl fences stay plain.
        case "pl", "perl":
            return nil
        default:
            return nil
        }
    }

    private static func supportedHighlighterExtension(_ ext: String) -> String? {
        let normalized = ext.lowercased()
        if LanguageRegistry.language(forFileExtension: normalized) != nil {
            return normalized
        }
        // `xml`, `scss`, and `sql` used to need a case here too, back when
        // they had no tree-sitter grammar and only `RegexFallbackHighlighter`
        // could render them; now they resolve through the branch above like
        // any other grammar-backed extension. `diff`/`patch` and `sass` (no
        // grammar of its own — `scss` covers only the SCSS dialect) still
        // rely purely on that fallback, so they stay listed here.
        switch normalized {
        case "diff", "patch", "sass":
            return normalized
        default:
            return nil
        }
    }
}

enum ACPToolOutputSyntax {
    static func highlighterExtension(content: String, locations: [String]) -> String? {
        if let fencedLanguage = wholeOutputFenceLanguage(content) {
            return fencedLanguage
        }
        if looksLikeDiff(content) {
            return "diff"
        }
        guard locations.count == 1 else {
            return nil
        }
        return ACPCodeLanguage.highlighterExtension(forPath: locations[0])
    }

    private static func wholeOutputFenceLanguage(_ content: String) -> String? {
        var lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = lines.first, first.hasPrefix("```"),
              let language = ACPCodeLanguage.highlighterExtension(for: String(first.dropFirst(3))) else {
            return nil
        }
        lines.removeFirst()
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        guard lines.last == "```" else { return nil }
        return language
    }

    private static func looksLikeDiff(_ content: String) -> Bool {
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard !lines.isEmpty else { return false }
        if lines.contains(where: { $0.hasPrefix("diff --git ") }) {
            return true
        }
        if lines.contains(where: isUnifiedHunkHeader) {
            return true
        }

        for index in lines.indices {
            let line = lines[index]
            guard line.hasPrefix("--- ") else { continue }
            let path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPathLikeDiffHeader(path) else { continue }
            let tail = lines[lines.index(after: index)...].prefix(8)
            let hasRemoval = tail.contains { isDiffChangeLine($0, marker: "-") }
            let hasAddition = tail.contains { isDiffChangeLine($0, marker: "+") }
            if hasRemoval || hasAddition {
                return true
            }
        }
        return false
    }

    private static func isUnifiedHunkHeader(_ line: String) -> Bool {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 4,
              parts[0] == "@@",
              isUnifiedRange(parts[1], marker: "-"),
              isUnifiedRange(parts[2], marker: "+"),
              parts[3] == "@@" else {
            return false
        }
        return true
    }

    private static func isUnifiedRange(_ token: String, marker: Character) -> Bool {
        guard token.first == marker else { return false }
        let range = token.dropFirst()
        guard !range.isEmpty else { return false }
        let segments = range.split(separator: ",", omittingEmptySubsequences: false)
        guard segments.count == 1 || segments.count == 2 else { return false }
        return segments.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isPathLikeDiffHeader(_ path: String) -> Bool {
        path.contains("/") || !(path as NSString).pathExtension.isEmpty
    }

    private static func isDiffChangeLine(_ line: String, marker: Character) -> Bool {
        guard line.first == marker else { return false }
        if marker == "-", line.hasPrefix("--- ") { return false }
        if marker == "+", line.hasPrefix("+++ ") { return false }

        let body = line.dropFirst()
        guard let first = body.first else { return false }
        guard first.isWhitespace else { return true }

        let indentation = body.prefix(while: { $0.isWhitespace })
        let rest = body.dropFirst(indentation.count)
        guard rest.contains(where: { !$0.isWhitespace }) else { return false }
        return indentation.count > 1 || indentation.contains("\t")
    }
}

enum ACPCodeBlockHighlighter {
    static func attributedString(
        code: String,
        language: String?,
        theme: Theme,
        fontFamily: String = ACPChatTypography.default.fontFamily,
        fontSize: CGFloat = 12
    ) -> NSAttributedString {
        let editorTheme = EditorTheme(theme: theme)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: CenterTypography.resolveCodeFont(family: fontFamily, size: fontSize),
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
