import Foundation
import SwiftTreeSitter

/// Tree-sitter backed syntax highlighter. Produces `HighlightSpan`s
/// against the input string's UTF-16 NSRange space (which is what the
/// AppKit text system uses).
///
/// We rely on `Parser.parse(_:)`'s default UTF-16 encoding so
/// `Node.range` already yields valid `NSRange`s for the source — no
/// UTF-8 byte conversion is needed. (See `SwiftTreeSitter.Parser.parse`
/// and `Range<UInt32>.range` in `Encoding+Helpers.swift`.)
struct TreeSitterHighlighter {
    actor Session {
        private var parser: Parser?
        private var tree: MutableTree?
        private var fileExtension: String?
        private var previousText: String?

        func reset() {
            parser = nil
            tree = nil
            fileExtension = nil
            previousText = nil
        }

        func highlight(source: String, fileExtension ext: String, edits: [EditorTextEdit]) -> [HighlightSpan] {
            guard
                let language = LanguageRegistry.language(forFileExtension: ext),
                let query = LanguageRegistry.highlightQuery(forExtension: ext)
            else {
                reset()
                return RegexFallbackHighlighter.highlight(source: source, fileExtension: ext)
            }

            let parser = parser(for: language, fileExtension: ext)
            let nextTree: MutableTree?
            if let oldText = previousText,
               fileExtension == ext,
               let editedTree = tree,
               let incrementallyEditedTree = apply(edits: edits, oldText: oldText, newText: source, to: editedTree) {
                nextTree = parser.parse(tree: incrementallyEditedTree, string: source)
            } else {
                nextTree = parser.parse(source)
            }
            guard let nextTree, let root = nextTree.rootNode else {
                previousText = source
                tree = nil
                return []
            }

            tree = nextTree
            previousText = source
            fileExtension = ext
            return TreeSitterHighlighter.spans(query: query, root: root, tree: nextTree)
        }

        private func parser(for language: Language, fileExtension ext: String) -> Parser {
            if let parser, fileExtension == ext { return parser }
            let parser = Parser()
            do {
                try parser.setLanguage(language)
                self.parser = parser
                self.tree = nil
                self.previousText = nil
                self.fileExtension = ext
            } catch {
                self.parser = nil
            }
            return parser
        }

        private func apply(edits: [EditorTextEdit], oldText: String, newText: String, to tree: MutableTree) -> MutableTree? {
            guard !edits.isEmpty else { return oldText == newText ? tree : nil }
            var rollingText = oldText
            for edit in edits {
                guard let editedText = TextEditCoordinates.apply(edit, to: rollingText),
                      let inputEdit = TextEditCoordinates.inputEdit(for: edit, oldText: rollingText, newText: editedText) else {
                    return nil
                }
                tree.edit(inputEdit)
                rollingText = editedText
            }
            return rollingText == newText ? tree : nil
        }
    }

    /// Tokenize a full file. Returns highlight spans against `source`.
    static func highlight(source: String, fileExtension ext: String) -> [HighlightSpan] {
        guard
            let language = LanguageRegistry.language(forFileExtension: ext),
            let query = LanguageRegistry.highlightQuery(forExtension: ext)
        else {
            return RegexFallbackHighlighter.highlight(source: source, fileExtension: ext)
        }
        let parser = Parser()
        do {
            try parser.setLanguage(language)
        } catch {
            return []
        }
        guard let tree = parser.parse(source) else { return [] }
        guard let root = tree.rootNode else { return [] }
        return spans(query: query, root: root, tree: tree)
    }

    /// Per-line API used by the diff pane. Tokenizes a single line in
    /// isolation. Returns spans with offsets local to `line`.
    static func tokenize(line: String, fileExtension ext: String) -> [HighlightSpan] {
        highlight(source: line, fileExtension: ext)
    }

    private static func spans(query: Query, root: Node, tree: MutableTree) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        let cursor = query.execute(node: root, in: tree)
        while let match = cursor.next() {
            for capture in match.captures {
                let name = capture.nameComponents.first ?? ""
                guard !name.isEmpty else { continue }
                let cap = HighlightCapture.from(name: name)
                if cap == .plain { continue }
                spans.append(HighlightSpan(range: capture.node.range, capture: cap))
            }
        }
        return spans
    }
}

private enum RegexFallbackHighlighter {
    static func highlight(source: String, fileExtension ext: String) -> [HighlightSpan] {
        let language = language(forFileExtension: ext)
        guard language != "plain" else { return [] }
        switch language {
        case "diff": return diffSpans(source: source)
        case "markup": return markupSpans(source: source)
        default: break
        }
        let keywords = keywordSet(for: language)
        let pattern = #"(//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        var spans: [HighlightSpan] = []
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let match else { return }
            let text = nsSource.substring(with: match.range)
            let capture: HighlightCapture
            if match.range(at: 1).location != NSNotFound {
                capture = .comment
            } else if match.range(at: 2).location != NSNotFound {
                capture = .string
            } else if match.range(at: 3).location != NSNotFound {
                capture = .number
            } else if keywords.contains(text) || keywords.contains(text.lowercased()) {
                capture = .keyword
            } else if text.first?.isUppercase == true {
                capture = .type
            } else {
                capture = .plain
            }
            if capture != .plain {
                spans.append(HighlightSpan(range: match.range, capture: capture))
            }
        }
        return spans
    }

    private static func diffSpans(source: String) -> [HighlightSpan] {
        let pattern = #"(?m)^(@@.*@@|diff --git .*$|index .*$|--- .*$|\+\+\+ .*$|\+.*$|-.*$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        var spans: [HighlightSpan] = []
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let match else { return }
            let text = nsSource.substring(with: match.range)
            let capture: HighlightCapture
            if text.hasPrefix("+") {
                capture = text.hasPrefix("+++ ") ? .keyword : .string
            } else if text.hasPrefix("-") {
                capture = text.hasPrefix("--- ") ? .keyword : .comment
            } else {
                capture = .keyword
            }
            spans.append(HighlightSpan(range: match.range, capture: capture))
        }
        return spans
    }

    private static func markupSpans(source: String) -> [HighlightSpan] {
        let pattern = #"(<!--[\s\S]*?-->)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(<\/?[A-Za-z][A-Za-z0-9:-]*)|([A-Za-z_:][A-Za-z0-9_:.-]*)(?=\s*\=)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        var spans: [HighlightSpan] = []
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let match else { return }
            let capture: HighlightCapture
            if match.range(at: 1).location != NSNotFound {
                capture = .comment
            } else if match.range(at: 2).location != NSNotFound {
                capture = .string
            } else if match.range(at: 3).location != NSNotFound {
                capture = .keyword
            } else if match.range(at: 4).location != NSNotFound {
                capture = .attribute
            } else {
                capture = .plain
            }
            if capture != .plain {
                spans.append(HighlightSpan(range: match.range, capture: capture))
            }
        }
        spans.append(contentsOf: booleanAttributeSpans(source: source, existingSpans: spans))
        return spans
    }

    private static func booleanAttributeSpans(source: String, existingSpans: [HighlightSpan]) -> [HighlightSpan] {
        let tagPattern = #"<[A-Za-z][A-Za-z0-9:-]*(?:\s+[^<>]*?)?/?>"#
        let attributePattern = #"\s+([A-Za-z_:][A-Za-z0-9_:.-]*)(?=\s*(?:=|/?>|\s))"#
        guard let tagRegex = try? NSRegularExpression(pattern: tagPattern),
              let attributeRegex = try? NSRegularExpression(pattern: attributePattern) else { return [] }
        let nsSource = source as NSString
        var spans: [HighlightSpan] = []
        tagRegex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { tagMatch, _, _ in
            guard let tagMatch else { return }
            attributeRegex.enumerateMatches(in: source, range: tagMatch.range) { attributeMatch, _, _ in
                guard let attributeMatch else { return }
                let range = attributeMatch.range(at: 1)
                guard range.location != NSNotFound,
                      !existingSpans.contains(where: { $0.capture == .attribute && $0.range == range }),
                      !spans.contains(where: { $0.range == range }) else { return }
                spans.append(HighlightSpan(range: range, capture: .attribute))
            }
        }
        return spans
    }

    private static func language(forFileExtension ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "rs": return "rust"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "py": return "python"
        case "ts", "tsx", "js", "jsx": return "ts"
        case "kt", "kts": return "kotlin"
        case "diff", "patch": return "diff"
        case "html", "xml": return "markup"
        case "css", "scss", "sass": return "css"
        case "sql": return "sql"
        default: return "plain"
        }
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
        case "kotlin":
            return [
                "val", "var", "fun", "class", "interface", "object", "sealed", "open", "abstract", "override",
                "lateinit", "companion", "data", "enum", "annotation", "typealias", "import", "package",
                "if", "else", "when", "while", "do", "for", "in", "return", "break", "continue",
                "throw", "try", "catch", "finally", "true", "false", "null", "this", "super",
                "is", "as", "by", "where", "out", "reified", "inline", "noinline", "crossinline",
                "operator", "infix", "tailrec", "suspend", "internal", "public", "private", "protected",
                "expect", "actual", "const", "vararg", "dynamic", "external"
            ]
        case "css":
            return [
                "display", "flex", "grid", "block", "inline", "none", "color", "background", "border",
                "margin", "padding", "position", "relative", "absolute", "fixed", "var", "calc",
                "media", "import", "font", "width", "height", "min", "max"
            ]
        case "sql":
            return [
                "select", "from", "where", "join", "inner", "left", "right", "full", "outer", "on",
                "insert", "into", "update", "delete", "values", "set", "create", "alter", "drop",
                "table", "view", "index", "and", "or", "not", "null", "true", "false", "group",
                "by", "order", "having", "limit", "offset", "as", "distinct"
            ]
        default:
            return []
        }
    }
}
