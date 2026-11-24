import Foundation
import AlasFoundation

/// `git diff --no-color base...head` output split per file, with the
/// new-side line ranges each file's hunks cover.
public struct CodeReviewDiff: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        /// The new path (`b/` stripped), or the old path for a deletion.
        public let path: String
        /// The file's full `diff --git` block.
        public let patch: String
        /// New-side line ranges of its hunks.
        public let newLineRanges: [ClosedRange<Int>]

        public init(path: String, patch: String, newLineRanges: [ClosedRange<Int>]) {
            self.path = path
            self.patch = patch
            self.newLineRanges = newLineRanges
        }

        public func contains(line: Int) -> Bool {
            newLineRanges.contains { $0.contains(line) }
        }
    }

    public let files: [File]

    public init(rawDiff: String) {
        var blocks: [[Substring]] = []
        for line in rawDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                blocks.append([line])
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        files = blocks.map(Self.file(fromBlock:))
    }

    /// Files in diff order until adding the next patch would pass `cap`
    /// characters. Everything from that file on is omitted, by path.
    public func included(cap: Int) -> (included: [File], omitted: [String]) {
        var total = 0
        for (index, file) in files.enumerated() {
            let (sum, overflow) = total.addingReportingOverflow(file.patch.count)
            if overflow || sum > cap {
                return (Array(files[..<index]), files[index...].map(\.path))
            }
            total = sum
        }
        return (files, [])
    }

    public func file(at path: String) -> File? {
        files.first { $0.path == path }
    }

    private static func file(fromBlock lines: [Substring]) -> File {
        var oldPath: String?
        var newPath: String?
        var ranges: [ClosedRange<Int>] = []
        var inHunks = false
        for line in lines {
            if line.hasPrefix("@@ ") {
                inHunks = true
                if let range = newLineRange(hunkHeader: line) { ranges.append(range) }
            } else if !inHunks {
                if line.hasPrefix("+++ ") {
                    newPath = strippedPath(line.dropFirst(4), prefix: "b/")
                } else if line.hasPrefix("--- ") {
                    oldPath = strippedPath(line.dropFirst(4), prefix: "a/")
                }
            }
        }
        let path = newPath ?? oldPath ?? headerPath(lines.first ?? "")
        let trimmed = lines.last?.isEmpty == true ? lines.dropLast() : lines[...]
        return File(path: path, patch: trimmed.joined(separator: "\n"), newLineRanges: ranges)
    }

    /// nil for `/dev/null`. Git C-quotes paths with non-ASCII characters,
    /// quotes or backslashes (`"b/caf\303\251.swift"`); those are decoded
    /// before the prefix comes off.
    private static func strippedPath(_ raw: Substring, prefix: String) -> String? {
        let value = decodedPath(raw.hasSuffix("\t") ? String(raw.dropLast()) : String(raw))
        guard value != "/dev/null" else { return nil }
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// `diff --git a/<old> b/<new>` for blocks without `---`/`+++` lines
    /// (binary files, pure renames, mode changes); either path may be quoted.
    private static func headerPath(_ header: Substring) -> String {
        let rest = String(header.dropFirst("diff --git ".count))
        if rest.hasSuffix("\""), let range = rest.range(of: " \"b/", options: .backwards) {
            let quoted = String(rest[rest.index(after: range.lowerBound)...])
            return String(decodedPath(quoted).dropFirst("b/".count))
        }
        if let range = rest.range(of: " b/", options: .backwards) {
            return String(rest[range.upperBound...])
        }
        return rest
    }

    /// The path a C-quoted Git name stands for; anything else as it is.
    private static func decodedPath(_ raw: String) -> String {
        var index = raw.startIndex
        guard raw.hasPrefix("\""), let decoded = GitQuotedPath.decode(in: raw, index: &index) else { return raw }
        return decoded
    }

    /// `@@ -a,b +c,d @@` covers `c...(c + d - 1)`; `d` defaults to 1, and 0
    /// (a pure deletion) covers nothing.
    private static func newLineRange(hunkHeader: Substring) -> ClosedRange<Int>? {
        guard let token = hunkHeader.split(separator: " ").first(where: { $0.hasPrefix("+") }) else { return nil }
        let parts = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
        let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        guard count > 0 else { return nil }
        return start...(start + count - 1)
    }
}
