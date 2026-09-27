import Foundation

struct FailureLogExcerpt: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        let number: Int
        let text: String
    }

    let lines: [Line]
    /// False when no error marker matched and `lines` is the output's tail.
    let matchedErrors: Bool
    let truncated: Bool
}

enum FailureLogSelection {
    static let contextLines = 1
    static let maximumLines = 40
    static let fallbackLines = 15
    static let maximumLineLength = 400

    private static let caseInsensitiveMarkers = try! NSRegularExpression(
        pattern: #"(?i)(?:\berror(?:\[[^\]]*\])?:|\bfatal:|\bpanic(?:ked)?\b|traceback \(most recent call last\)|\bnpm err!)"#
    )
    private static let caseSensitiveMarkers = try! NSRegularExpression(
        pattern: #"(?:\b[A-Z]\w*(?:Exception|Error)(?=:|$)|\bException in thread\b|\bFAIL(?:ED)?\b|✘|✗)"#
    )

    /// Input is run output that is already ANSI-stripped and tail-bounded.
    static func select(_ output: String) -> FailureLogExcerpt? {
        var lines = output.components(separatedBy: "\n")
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        let privateKeyLines = privateKeyLineIndices(lines)
        let matches = lines.indices.filter { !privateKeyLines.contains($0) && isErrorLine(lines[$0]) }

        let indices: [Int]
        let truncated: Bool
        if matches.isEmpty {
            indices = Array(lines.indices.suffix(fallbackLines))
            truncated = false
        } else {
            var selected = IndexSet()
            for match in matches {
                selected.insert(integersIn: max(0, match - contextLines)...min(lines.count - 1, match + contextLines))
            }
            let ordered = Array(selected)
            indices = Array(ordered.suffix(maximumLines))
            truncated = ordered.count > maximumLines
        }

        return FailureLogExcerpt(
            lines: indices.map { index in
                let text = privateKeyLines.contains(index)
                    ? "[redacted private key]"
                    : LocalTextSafety.redactingCredentials(String(lines[index].prefix(maximumLineLength)))
                return .init(number: index + 1, text: text)
            },
            matchedErrors: !matches.isEmpty,
            truncated: truncated
        )
    }

    private static func isErrorLine(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return caseInsensitiveMarkers.firstMatch(in: line, range: range) != nil
            || caseSensitiveMarkers.firstMatch(in: line, range: range) != nil
    }

    private static func privateKeyLineIndices(_ lines: [String]) -> Set<Int> {
        var result = Set<Int>()
        var inside = false
        for (index, line) in lines.enumerated() {
            if line.contains("PRIVATE KEY-----") {
                result.insert(index)
                inside = line.contains("-----BEGIN")
            } else if inside {
                result.insert(index)
            }
        }
        return result
    }
}
