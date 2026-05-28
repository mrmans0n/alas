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
        case "css": return cssSpans(source: source)
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
        let nsSource = source as NSString
        var lines: [(range: NSRange, text: String)] = []
        var offset = 0
        while offset < nsSource.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: offset, length: 0))
            var contentRange = lineRange
            while contentRange.length > 0 {
                let char = nsSource.character(at: contentRange.location + contentRange.length - 1)
                guard char == 10 || char == 13 else { break }
                contentRange.length -= 1
            }
            lines.append((contentRange, nsSource.substring(with: contentRange)))
            offset = lineRange.location + lineRange.length
        }

        var spans: [HighlightSpan] = []
        var inHunk = false
        for index in lines.indices {
            let line = lines[index]
            if line.text.hasPrefix("diff ") {
                inHunk = false
            }
            let previous = index > lines.startIndex ? lines[lines.index(before: index)].text : nil
            let next = index < lines.index(before: lines.endIndex) ? lines[lines.index(after: index)].text : nil
            let nextNextIndex = lines.index(index, offsetBy: 2, limitedBy: lines.index(before: lines.endIndex))
            let nextNext = nextNextIndex.map { lines[$0].text }
            if let capture = diffCapture(for: line.text, previous: previous, next: next, nextNext: nextNext, inHunk: inHunk) {
                spans.append(HighlightSpan(range: line.range, capture: capture))
            }
            if line.text.hasPrefix("@@"), line.text.contains("@@") {
                inHunk = true
            }
        }
        return spans
    }

    private static func diffCapture(for line: String, previous: String?, next: String?, nextNext: String?, inHunk: Bool) -> HighlightCapture? {
        if line.hasPrefix("@@"), line.contains("@@") { return .keyword }
        if isDiffMetadata(line) { return .keyword }
        if line.hasPrefix("--- "), next?.hasPrefix("+++ ") == true, !inHunk || nextNext?.hasPrefix("@@") == true { return .keyword }
        if line.hasPrefix("+++ "), previous?.hasPrefix("--- ") == true, !inHunk || next?.hasPrefix("@@") == true { return .keyword }
        if !inHunk, line.hasPrefix("--- ") || line.hasPrefix("+++ ") { return .keyword }
        if line.hasPrefix("+") { return .string }
        if line.hasPrefix("-") { return .comment }
        return nil
    }

    private static func isDiffMetadata(_ line: String) -> Bool {
        [
            "diff ",
            "index ",
            "new file mode ",
            "deleted file mode ",
            "old mode ",
            "new mode ",
            "similarity index ",
            "dissimilarity index ",
            "rename from ",
            "rename to ",
            "copy from ",
            "copy to "
        ].contains(where: { line.hasPrefix($0) })
    }

    private static func cssSpans(source: String) -> [HighlightSpan] {
        let keywords = keywordSet(for: "css")
        let pattern = #"(/\*[\s\S]*?\*/)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(#(?:[0-9A-Fa-f]{3,8}|[A-Za-z_][A-Za-z0-9_-]*))|(\b\d+(?:\.\d+)?\b)|([A-Za-z_-][A-Za-z0-9_-]*)"#
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
            } else if match.range(at: 3).location != NSNotFound || match.range(at: 4).location != NSNotFound {
                capture = .number
            } else if keywords.contains(text) || keywords.contains(text.lowercased()) {
                capture = .keyword
            } else {
                capture = .plain
            }
            if capture != .plain {
                spans.append(HighlightSpan(range: match.range, capture: capture))
            }
        }
        return spans
    }

    private static func markupSpans(source: String) -> [HighlightSpan] {
        let pattern = #"(<!--[\s\S]*?-->)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(<\/?[A-Za-z][A-Za-z0-9:-]*)"#
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
        let attributePattern = #"\s+([A-Za-z_:][A-Za-z0-9_:.-]*)(?=\s*(?:=|/?>|\s))"#
        guard let attributeRegex = try? NSRegularExpression(pattern: attributePattern) else { return [] }
        let nsSource = source as NSString
        let protectedSpans = existingSpans.filter { $0.capture == .comment || $0.capture == .string }
        var spans: [HighlightSpan] = []
        for tagRange in openingTagRanges(source: source, protectedSpans: protectedSpans) {
            attributeRegex.enumerateMatches(in: source, range: tagRange) { attributeMatch, _, _ in
                guard let attributeMatch else { return }
                let range = attributeMatch.range(at: 1)
                guard range.location != NSNotFound,
                      !protectedSpans.contains(where: { contains($0.range, range) }),
                      !existingSpans.contains(where: { $0.capture == .attribute && $0.range == range }),
                      !spans.contains(where: { $0.range == range }) else { return }
                spans.append(HighlightSpan(range: range, capture: .attribute))
            }
        }
        return spans
    }

    private static func openingTagRanges(source: String, protectedSpans: [HighlightSpan]) -> [NSRange] {
        let nsSource = source as NSString
        var ranges: [NSRange] = []
        var offset = 0
        while offset < nsSource.length {
            guard nsSource.character(at: offset) == 60,
                  !protectedSpans.contains(where: { contains($0.range, NSRange(location: offset, length: 1)) }),
                  offset + 1 < nsSource.length else {
                offset += 1
                continue
            }
            let next = nsSource.character(at: offset + 1)
            guard isMarkupNameStart(next) else {
                offset += 1
                continue
            }
            var cursor = offset + 1
            var quote: unichar?
            while cursor < nsSource.length {
                let char = nsSource.character(at: cursor)
                if let currentQuote = quote {
                    if char == currentQuote { quote = nil }
                } else if char == 34 || char == 39 {
                    quote = char
                } else if char == 62 {
                    ranges.append(NSRange(location: offset, length: cursor - offset + 1))
                    offset = cursor
                    break
                }
                cursor += 1
            }
            offset += 1
        }
        return ranges
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func isMarkupNameStart(_ char: unichar) -> Bool {
        (char >= 65 && char <= 90) || (char >= 97 && char <= 122)
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
