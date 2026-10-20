import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPCodeLanguage: Sendable {
    public static func highlighterExtension(for label: String?) -> String? {
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

    public static func highlighterExtension(forPath path: String?) -> String? {
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
