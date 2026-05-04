import Foundation

enum TokenKind: Equatable { case keyword, type, string, number, comment, function, plain }

struct Token: Equatable {
    let text: String
    let kind: TokenKind
}

enum SimpleHighlighter {
    static func language(forFile path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "rust"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "py": return "python"
        case "ts", "tsx", "js", "jsx": return "ts"
        default: return "plain"
        }
    }

    static func tokenize(_ source: String, language: String) -> [Token] {
        let keywords = keywordSet(for: language)
        let pattern = #"""
        (//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)
        """#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        guard let regex else { return [Token(text: source, kind: .plain)] }
        var tokens: [Token] = []
        let nsSource = source as NSString
        var lastIndex = 0
        regex.enumerateMatches(in: source, options: [], range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let m = match else { return }
            if m.range.location > lastIndex {
                let plain = nsSource.substring(with: NSRange(location: lastIndex, length: m.range.location - lastIndex))
                tokens.append(Token(text: plain, kind: .plain))
            }
            let text = nsSource.substring(with: m.range)
            let kind: TokenKind
            if m.range(at: 1).location != NSNotFound {
                kind = .comment
            } else if m.range(at: 2).location != NSNotFound {
                kind = .string
            } else if m.range(at: 3).location != NSNotFound {
                kind = .number
            } else if keywords.contains(text) {
                kind = .keyword
            } else if text.first?.isUppercase == true {
                kind = .type
            } else {
                kind = .plain
            }
            tokens.append(Token(text: text, kind: kind))
            lastIndex = m.range.location + m.range.length
        }
        if lastIndex < nsSource.length {
            tokens.append(Token(text: nsSource.substring(from: lastIndex), kind: .plain))
        }
        return tokens
    }

    private static func keywordSet(for language: String) -> Set<String> {
        switch language {
        case "swift":
            return ["func", "let", "var", "if", "else", "guard", "return", "for", "in",
                    "while", "do", "try", "throw", "throws", "import", "struct", "class",
                    "enum", "protocol", "extension", "switch", "case", "default", "self",
                    "init", "private", "public", "internal", "fileprivate", "static",
                    "true", "false", "nil", "as", "is", "where"]
        case "rust":
            return ["fn", "let", "mut", "pub", "use", "mod", "struct", "enum", "impl",
                    "trait", "if", "else", "match", "for", "in", "while", "loop", "return",
                    "as", "ref", "self", "Self", "true", "false", "Some", "None", "Ok", "Err"]
        case "json":
            return ["true", "false", "null"]
        case "ts":
            return ["function", "const", "let", "var", "if", "else", "return", "for",
                    "while", "class", "interface", "type", "import", "export", "from",
                    "as", "extends", "implements", "true", "false", "null", "undefined"]
        case "python":
            return ["def", "class", "if", "elif", "else", "for", "while", "return", "try",
                    "except", "finally", "import", "from", "as", "with", "yield",
                    "True", "False", "None", "lambda", "pass", "break", "continue"]
        default: return []
        }
    }
}
