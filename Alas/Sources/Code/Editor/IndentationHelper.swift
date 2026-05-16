import Foundation

/// Pure helper for indentation decisions. Does not import AppKit.
struct IndentationHelper {

    struct NewlineEdit: Equatable {
        let replacement: String
        let selectedLocationDelta: Int
    }

    struct ClosingDelimiterEdit: Equatable {
        let replacementRange: NSRange
        let replacement: String
        let selectedLocationDelta: Int
    }

    static let pairedDelimiters: [Character: Character] = [
        "(": ")",
        "[": "]",
        "{": "}"
    ]

    static let closingDelimiters: Set<Character> = [")", "]", "}"]

    // MARK: - Newline

    static func newlineEdit(
        in text: String,
        selectedRange: NSRange,
        mode: IndentationMode
    ) -> NewlineEdit? {
        guard selectedRange.length == 0 else { return nil }

        let ns = text as NSString
        let cursor = selectedRange.location
        guard cursor >= 0, cursor <= ns.length else { return nil }

        let currentLineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
        let linePrefix = ns.substring(with: NSRange(location: currentLineRange.location, length: cursor - currentLineRange.location))
        let leadingWhitespace = leadingWhitespace(of: linePrefix)
        let indentUnit = indentUnit(in: text)

        let beforeCursor = String(linePrefix)
        let afterCursor = ns.substring(with: NSRange(location: cursor, length: NSMaxRange(currentLineRange) - cursor))

        let endsWithOpener: Bool
        let isBetweenPair: Bool

        if mode == .bracketAware {
            endsWithOpener = beforeCursor.last.map { Self.pairedDelimiters.keys.contains($0) } ?? false
            isBetweenPair = {
                guard let lastChar = beforeCursor.last,
                      let expectedCloser = Self.pairedDelimiters[lastChar] else { return false }
                return afterCursor.first == expectedCloser
            }()
        } else {
            endsWithOpener = false
            isBetweenPair = false
        }

        if mode == .bracketAware, isBetweenPair {
            let innerIndent = leadingWhitespace + indentUnit
            let replacement = "\n" + innerIndent + "\n" + leadingWhitespace
            let middleLineStart = cursor + 1 + innerIndent.count
            return NewlineEdit(replacement: replacement, selectedLocationDelta: middleLineStart - cursor)
        } else if mode == .bracketAware, endsWithOpener {
            let newIndent = leadingWhitespace + indentUnit
            let replacement = "\n" + newIndent
            return NewlineEdit(replacement: replacement, selectedLocationDelta: replacement.count)
        } else {
            let replacement = "\n" + leadingWhitespace
            return NewlineEdit(replacement: replacement, selectedLocationDelta: replacement.count)
        }
    }

    // MARK: - Closing delimiter

    static func closingDelimiterEdit(
        in text: String,
        selectedRange: NSRange,
        delimiter: Character,
        mode: IndentationMode
    ) -> ClosingDelimiterEdit? {
        guard mode == .bracketAware,
              Self.closingDelimiters.contains(delimiter),
              selectedRange.length == 0 else { return nil }

        let ns = text as NSString
        let cursor = selectedRange.location
        guard cursor >= 0, cursor <= ns.length else { return nil }

        let currentLineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
        let lineStart = currentLineRange.location
        let linePrefix = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))

        guard isWhitespaceOnly(linePrefix) else { return nil }

        let indentUnit = indentUnit(in: text)
        let currentIndent = linePrefix
        let dedented = dedent(currentIndent, by: indentUnit)

        guard dedented.count < currentIndent.count else { return nil }

        let replacementRange = NSRange(location: lineStart, length: currentIndent.count)
        let replacement = dedented + String(delimiter)
        let selectedLocationDelta = dedented.count + 1

        return ClosingDelimiterEdit(
            replacementRange: replacementRange,
            replacement: replacement,
            selectedLocationDelta: selectedLocationDelta
        )
    }

    // MARK: - Utilities

    static func leadingWhitespace(of string: String) -> String {
        var result = ""
        for char in string {
            if char == " " || char == "\t" {
                result.append(char)
            } else {
                break
            }
        }
        return result
    }

    static func isWhitespaceOnly(_ string: String) -> Bool {
        string.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func dedent(_ indent: String, by unit: String) -> String {
        if indent.hasPrefix(unit) {
            return String(indent.dropFirst(unit.count))
        }
        return indent
    }

    static func indentUnit(in text: String) -> String {
        let ns = text as NSString
        var hasTab = false
        var spaceRuns: [Int] = []

        ns.enumerateLines { line, _ in
            let ws = leadingWhitespace(of: line)
            if ws.contains("\t") {
                hasTab = true
            }
            if !ws.isEmpty {
                let spaces = ws.count - ws.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) }
                if spaces > 0 {
                    spaceRuns.append(spaces)
                }
            }
        }

        if hasTab {
            return "\t"
        }

        if spaceRuns.isEmpty {
            return "    "
        }

        let minSpace = spaceRuns.min() ?? 4
        // Snap to common indent widths
        if minSpace <= 2 {
            return String(repeating: " ", count: minSpace)
        } else {
            return "    "
        }
    }
}
