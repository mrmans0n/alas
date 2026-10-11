import AppKit
import Foundation

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
