import Foundation
import AlasModel

public struct CodeReviewFinding: Equatable, Sendable {
    public enum Anchor: Equatable, Sendable {
        /// New-side lines inside one of the file's hunks.
        case line(start: Int, end: Int)
        case file
    }

    public let path: String
    public let anchor: Anchor
    public let body: String

    public init(path: String, anchor: Anchor, body: String) {
        self.path = path
        self.anchor = anchor
        self.body = body
    }
}

public struct CodeReviewResult: Equatable, Sendable {
    public let verdict: ReviewVerdict
    public let summary: String
    public let findings: [CodeReviewFinding]
    /// Ids of earlier findings the reviewer reports fixed.
    public let resolvedIDs: [String]

    public init(verdict: ReviewVerdict, summary: String, findings: [CodeReviewFinding], resolvedIDs: [String]) {
        self.verdict = verdict
        self.summary = summary
        self.findings = findings
        self.resolvedIDs = resolvedIDs
    }

    /// `request_changes` is never clean; `comment` is clean only without findings.
    public var isClean: Bool { verdict == .approve || (verdict == .comment && findings.isEmpty) }
}

public enum CodeReviewResultParser {
    public enum Failure: Error, Equatable {
        case noResult
        case malformed(String)
    }

    /// Takes the last JSON object in the reviewer's final message: the last
    /// fenced block that parses, else the whole message, else the latest
    /// line-starting `{` that parses through to the end.
    public static func parse(_ finalMessage: String, diff: CodeReviewDiff) -> Result<CodeReviewResult, Failure> {
        guard let object = lastJSONObject(in: finalMessage) else { return .failure(.noResult) }
        return result(from: object, diff: diff)
    }

    // MARK: - Locating the block

    private static func lastJSONObject(in message: String) -> [String: Any]? {
        let lines = message.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for block in fencedBlocks(in: lines).reversed() {
            if let object = jsonObject(block) { return object }
        }
        if let object = jsonObject(message.trimmingCharacters(in: .whitespacesAndNewlines)) { return object }
        for start in lines.indices.reversed()
        where lines[start].drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("{") {
            if let object = jsonObject(lines[start...].joined(separator: "\n")) { return object }
        }
        return nil
    }

    /// Contents of fenced blocks tagged `json` or untagged, in order. A
    /// block closes on a bare fence at least as long as its opener.
    private static func fencedBlocks(in lines: [Substring]) -> [String] {
        var blocks: [String] = []
        var index = 0
        while index < lines.count {
            let opener = lines[index].drop(while: { $0 == " " || $0 == "\t" })
            let ticks = opener.prefix(while: { $0 == "`" }).count
            guard ticks >= 3 else { index += 1; continue }
            let info = opener.dropFirst(ticks).trimmingCharacters(in: .whitespaces).lowercased()
            var body: [Substring] = []
            var cursor = index + 1
            var closed = false
            while cursor < lines.count {
                let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                if candidate.count >= ticks, candidate.allSatisfy({ $0 == "`" }) {
                    closed = true
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            if closed, info.isEmpty || info == "json" {
                blocks.append(body.joined(separator: "\n"))
            }
            index = cursor + 1
        }
        return blocks
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: - Mapping

    private static func result(from object: [String: Any], diff: CodeReviewDiff) -> Result<CodeReviewResult, Failure> {
        let verdict: ReviewVerdict
        let rawVerdict = object["verdict"] as? String
        switch rawVerdict {
        case "approve"?: verdict = .approve
        case "request_changes"?: verdict = .requestChanges
        case "comment"?: verdict = .comment
        default: return .failure(.malformed("unknown verdict: \(rawVerdict ?? "missing")"))
        }

        var rawFindings: [Any] = []
        if let value = object["findings"], !(value is NSNull) {
            guard let list = value as? [Any] else { return .failure(.malformed("findings is not a list")) }
            rawFindings = list
        }

        var findings: [CodeReviewFinding] = []
        var outsideDiff: [String] = []
        for case let entry as [String: Any] in rawFindings {
            guard let path = (entry["path"] as? String).flatMap(nonBlank),
                  let body = (entry["body"] as? String).flatMap(nonBlank)
            else { continue }
            let line = integer(entry["line"])
            guard let file = diff.file(at: path) else {
                let location = line.map { "\(path):\($0)" } ?? path
                outsideDiff.append("- \(location): \(body)")
                continue
            }
            guard let line, file.contains(line: line) else {
                findings.append(CodeReviewFinding(path: path, anchor: .file, body: body))
                continue
            }
            let end = max(integer(entry["end_line"]) ?? line, line)
            findings.append(CodeReviewFinding(path: path, anchor: .line(start: line, end: end), body: body))
        }

        var summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !outsideDiff.isEmpty {
            let folded = (["Not in this diff:"] + outsideDiff).joined(separator: "\n")
            summary = summary.isEmpty ? folded : "\(summary)\n\n\(folded)"
        }
        let resolved = (object["resolved"] as? [Any])?.compactMap { $0 as? String } ?? []
        return .success(CodeReviewResult(verdict: verdict, summary: summary, findings: findings, resolvedIDs: resolved))
    }

    /// JSON numbers only; a Bool bridged through `NSNumber` is not a line.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
