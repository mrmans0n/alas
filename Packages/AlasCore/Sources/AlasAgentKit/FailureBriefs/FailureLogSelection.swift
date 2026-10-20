import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct FailureLogExcerpt: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let number: Int
        public let text: String

        public init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
    }

    public let lines: [Line]
    /// False when no error marker matched and `lines` is the output's tail.
    public let matchedErrors: Bool
    /// True when earlier lines that qualified for the excerpt were dropped.
    public let truncated: Bool

    public init(lines: [Line], matchedErrors: Bool, truncated: Bool) {
        self.lines = lines
        self.matchedErrors = matchedErrors
        self.truncated = truncated
    }
}

public enum FailureLogSelection: Sendable {
    public static let contextLines = 1
    public static let maximumLines = 40
    public static let fallbackLines = 15
    public static let maximumLineLength = 400

    private static let caseInsensitiveMarkers = try! NSRegularExpression(
        pattern: #"(?i)(?:\berror(?:\[[^\]]*\])?:|\bfatal:|\bpanic(?:ked)?\b|traceback \(most recent call last\)|\bnpm err!)"#
    )
    private static let caseSensitiveMarkers = try! NSRegularExpression(
        pattern: #"(?:\b[A-Z]\w*(?:Exception|Error)(?=:|$)|\bException in thread\b|\bFAIL(?:ED)?\b|✘|✗)"#
    )

    /// Input is run output that is already ANSI-stripped and tail-bounded.
    public static func select(_ output: String, inputTruncated: Bool = false) -> FailureLogExcerpt? {
        var lines = output.components(separatedBy: "\n")
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        let matches = lines.indices.filter { isErrorLine(lines[$0]) }

        let indices: [Int]
        let truncated: Bool
        if matches.isEmpty {
            indices = Array(lines.indices.suffix(fallbackLines))
            truncated = lines.count > fallbackLines
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
            lines: indices.map { .init(number: $0 + 1, text: String(lines[$0].prefix(maximumLineLength))) },
            matchedErrors: !matches.isEmpty,
            truncated: truncated || inputTruncated
        )
    }

    private static func isErrorLine(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return caseInsensitiveMarkers.firstMatch(in: line, range: range) != nil
            || caseSensitiveMarkers.firstMatch(in: line, range: range) != nil
    }
}
