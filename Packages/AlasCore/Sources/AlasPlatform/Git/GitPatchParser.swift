import Foundation

/// One file's change, read from an exact single-file git patch.
public struct GitFilePatch: Equatable, Sendable {
    public enum Change: String, Codable, Equatable, Hashable, Sendable { case modified, added, deleted, renamed }

    /// The old name in git form, without the `a/` prefix. Nil when the file was added.
    public let oldPath: String?
    /// The new name in git form, without the `b/` prefix. Nil when the file was deleted.
    public let newPath: String?
    public let change: Change
    /// The hunks, with old and new line numbers and `noTrailingNewline`. Never binary and without a metadata summary.
    public let diff: ParsedDiff
    public let added: Int
    public let removed: Int
}

/// Why a text is not an exact single-file git patch.
public enum GitFilePatchFailure: String, Codable, Equatable, Hashable, Error, Sendable {
    case truncated, malformedHeader, malformedPath, pathMismatch, malformedHunk, noHunks
}

/// A strict parser for the single-file git patches that ACP adapters attach to tool calls.
///
/// Unlike `DiffParser`, which renders whatever git printed, it rejects any patch whose headers
/// disagree or whose hunks do not add up, so a caller can trust the hunks as the exact change.
/// The hunk rules follow the Codex adapter's `hunkText`.
public enum GitPatchParser {
    private static let noNewlineMarker = "\\ No newline at end of file"
    /// The largest hunk number accepted, as in JavaScript's `Number.isSafeInteger`.
    private static let maxLineNumber = 9_007_199_254_740_991

    /// `path` with backslashes made forward slashes and leading "/" dropped, as git headers name it.
    public static func gitPath(_ path: String) -> String {
        let slashed = path.replacingOccurrences(of: "\\", with: "/")
        return String(slashed.drop { $0 == "/" })
    }

    public static func parse(_ text: String, path: String) -> Result<GitFilePatch, GitFilePatchFailure> {
        do {
            return try .success(parsePatch(text, path: path))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Patch

    private static func parsePatch(_ text: String, path: String) throws(GitFilePatchFailure) -> GitFilePatch {
        // Split on scalars: a `\r\n` pair is one Character, and hunk lines keep their `\r`.
        var lines = text.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        guard lines.count >= 2, lines.last?.isEmpty == true else { throw .truncated }
        lines.removeLast()

        guard let diffGitPayload = dropPrefix("diff --git ", from: lines[0]) else { throw .malformedHeader }
        var index = 1

        var newFileMode = false
        var deletedFileMode = false
        var renameFrom: String?
        var renameTo: String?
        var sawFileHeaders = false
        var oldHeader: String?
        var newHeader: String?

        while index < lines.count {
            let line = lines[index]
            index += 1
            if let rest = dropPrefix("--- ", from: line) {
                oldHeader = try fileHeaderName(rest, prefix: "a/")
                guard index < lines.count, let plus = dropPrefix("+++ ", from: lines[index]) else {
                    throw .malformedHeader
                }
                newHeader = try fileHeaderName(plus, prefix: "b/")
                index += 1
                sawFileHeaders = true
                break
            }
            if let mode = dropPrefix("new file mode ", from: line) {
                guard !newFileMode, isMode(mode) else { throw .malformedHeader }
                newFileMode = true
            } else if let mode = dropPrefix("deleted file mode ", from: line) {
                guard !deletedFileMode, isMode(mode) else { throw .malformedHeader }
                deletedFileMode = true
            } else if let mode = dropPrefix("old mode ", from: line) ?? dropPrefix("new mode ", from: line) {
                guard isMode(mode) else { throw .malformedHeader }
            } else if let score = dropPrefix("similarity index ", from: line)
                ?? dropPrefix("dissimilarity index ", from: line) {
                guard isPercentage(score) else { throw .malformedHeader }
            } else if let name = dropPrefix("rename from ", from: line) {
                guard renameFrom == nil else { throw .malformedHeader }
                renameFrom = try extendedHeaderName(name)
            } else if let name = dropPrefix("rename to ", from: line) {
                guard renameTo == nil else { throw .malformedHeader }
                renameTo = try extendedHeaderName(name)
            } else if let hashes = dropPrefix("index ", from: line) {
                guard isIndexLine(hashes) else { throw .malformedHeader }
            } else {
                throw .malformedHeader
            }
        }

        // Header consistency.
        let isRename = renameFrom != nil || renameTo != nil
        if newFileMode && deletedFileMode { throw .malformedHeader }
        if isRename {
            guard renameFrom != nil, renameTo != nil, !newFileMode, !deletedFileMode else { throw .malformedHeader }
        }
        if sawFileHeaders {
            guard (oldHeader == nil) == newFileMode, (newHeader == nil) == deletedFileMode else {
                throw .malformedHeader
            }
            if isRename {
                guard oldHeader == renameFrom, newHeader == renameTo else { throw .malformedHeader }
            } else if let oldHeader, let newHeader, oldHeader != newHeader {
                throw .malformedHeader
            }
        }

        // Git names an added or deleted file on both sides of `diff --git`.
        let expectedOld = renameFrom ?? oldHeader ?? newHeader
        let expectedNew = renameTo ?? newHeader ?? oldHeader
        let names = try diffGitNames(diffGitPayload, expectedOld: expectedOld, expectedNew: expectedNew)

        let oldPath = newFileMode ? nil : names.old
        let newPath = deletedFileMode ? nil : names.new
        let change: GitFilePatch.Change = newFileMode ? .added
            : deletedFileMode ? .deleted
            : isRename ? .renamed
            : .modified

        guard (newPath ?? oldPath) == gitPath(path) else { throw .pathMismatch }
        guard index < lines.count else { throw .noHunks }

        let hunks = try parseHunks(lines, from: index)
        var added = 0
        var removed = 0
        for line in hunks.lazy.flatMap(\.lines) {
            switch line.kind {
            case .add: added += 1
            case .delete: removed += 1
            case .context: break
            }
        }
        return GitFilePatch(
            oldPath: oldPath,
            newPath: newPath,
            change: change,
            diff: ParsedDiff(hunks: hunks),
            added: added,
            removed: removed
        )
    }

    // MARK: - Names

    /// Reads a `---` or `+++` name: `/dev/null` (nil), a quoted token with an optional tab and
    /// trailing text, or an unquoted name that ends at the first tab.
    private static func fileHeaderName(_ rest: String, prefix: String) throws(GitFilePatchFailure) -> String? {
        let name: String
        if rest.unicodeScalars.first == "\"" {
            var cursor = rest.startIndex
            guard let decoded = GitQuotedPath.decode(in: rest, index: &cursor) else { throw .malformedPath }
            let tail = rest.unicodeScalars[cursor...]
            guard tail.isEmpty || tail.first == "\t" else { throw .malformedHeader }
            name = decoded
        } else {
            name = String(String.UnicodeScalarView(rest.unicodeScalars.prefix { $0 != "\t" }))
            if name == "/dev/null" { return nil }
        }
        guard let stripped = dropPrefix(prefix, from: name), !stripped.isEmpty else { throw .malformedHeader }
        return stripped
    }

    /// Reads a `rename from` or `rename to` name, which has no prefix and no trailing text.
    private static func extendedHeaderName(_ rest: String) throws(GitFilePatchFailure) -> String {
        guard rest.unicodeScalars.first == "\"" else {
            guard !rest.isEmpty else { throw .malformedHeader }
            return rest
        }
        var cursor = rest.startIndex
        guard let decoded = GitQuotedPath.decode(in: rest, index: &cursor) else { throw .malformedPath }
        guard cursor == rest.endIndex, !decoded.isEmpty else { throw .malformedHeader }
        return decoded
    }

    /// Finds the split of the `diff --git` payload whose sides equal the expected names. An unquoted
    /// name can contain spaces, so every space is a candidate. Without expected names (a patch with
    /// neither `---`/`+++` nor rename lines), the sides must name the same file.
    private static func diffGitNames(
        _ payload: String,
        expectedOld: String?,
        expectedNew: String?
    ) throws(GitFilePatchFailure) -> (old: String, new: String) {
        let scalars = payload.unicodeScalars
        for split in scalars.indices where scalars[split] == " " {
            let left = String(String.UnicodeScalarView(scalars[..<split]))
            let right = String(String.UnicodeScalarView(scalars[scalars.index(after: split)...]))
            guard let old = diffGitSide(left, prefix: "a/"), let new = diffGitSide(right, prefix: "b/") else {
                continue
            }
            if let expectedOld, let expectedNew {
                if old == expectedOld, new == expectedNew { return (old, new) }
            } else if old == new {
                return (old, new)
            }
        }
        var cursor = payload.startIndex
        if scalars.first == "\"", GitQuotedPath.decode(in: payload, index: &cursor) == nil {
            throw .malformedPath
        }
        throw .malformedHeader
    }

    private static func diffGitSide(_ side: String, prefix: String) -> String? {
        let name: String
        if side.unicodeScalars.first == "\"" {
            var cursor = side.startIndex
            guard let decoded = GitQuotedPath.decode(in: side, index: &cursor), cursor == side.endIndex else {
                return nil
            }
            name = decoded
        } else {
            name = side
        }
        guard let stripped = dropPrefix(prefix, from: name), !stripped.isEmpty else { return nil }
        return stripped
    }

    // MARK: - Hunks

    private struct HunkRange {
        /// The number the header names.
        let start: Int
        /// The first line of the range; an empty range starts after `start`.
        let first: Int
        let count: Int
    }

    private static func parseHunks(_ lines: [String], from start: Int) throws(GitFilePatchFailure) -> [ParsedDiff.Hunk] {
        var hunks: [ParsedDiff.Hunk] = []
        var index = start
        /// The first old line after the previous hunk.
        var oldEnd = 1
        /// The line count change of the previous hunks.
        var offset = 0

        while index < lines.count {
            let header = lines[index]
            guard let ranges = hunkHeader(header) else { throw .malformedHunk }
            let (old, new) = ranges
            guard old.first >= oldEnd, new.first - old.first == offset else { throw .malformedHunk }
            oldEnd = old.first + old.count
            offset += new.count - old.count
            index += 1

            var oldLeft = old.count
            var newLeft = new.count
            var oldNumber = old.start
            var newNumber = new.start
            var body: [ParsedDiff.Hunk.Line] = []

            while oldLeft > 0 || newLeft > 0 {
                guard index < lines.count else { throw .truncated }
                let line = lines[index]
                index += 1
                let text = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst()))
                switch line.unicodeScalars.first {
                case nil, " ":
                    guard oldLeft > 0, newLeft > 0 else { throw .malformedHunk }
                    body.append(.init(kind: .context, text: text, oldNumber: oldNumber, newNumber: newNumber))
                    oldLeft -= 1
                    newLeft -= 1
                    oldNumber += 1
                    newNumber += 1
                case "-":
                    guard oldLeft > 0 else { throw .malformedHunk }
                    body.append(.init(kind: .delete, text: text, oldNumber: oldNumber, newNumber: nil))
                    oldLeft -= 1
                    oldNumber += 1
                case "+":
                    guard newLeft > 0 else { throw .malformedHunk }
                    body.append(.init(kind: .add, text: text, oldNumber: nil, newNumber: newNumber))
                    newLeft -= 1
                    newNumber += 1
                case "\\":
                    try markNoTrailingNewline(line, in: &body)
                default:
                    throw .malformedHunk
                }
            }
            while index < lines.count, lines[index].unicodeScalars.first == "\\" {
                try markNoTrailingNewline(lines[index], in: &body)
                index += 1
            }
            hunks.append(ParsedDiff.Hunk(header: header, oldStart: old.start, newStart: new.start, lines: body))
        }
        return hunks
    }

    private static func markNoTrailingNewline(
        _ line: String,
        in body: inout [ParsedDiff.Hunk.Line]
    ) throws(GitFilePatchFailure) {
        guard line.unicodeScalars.elementsEqual(noNewlineMarker.unicodeScalars), !body.isEmpty else {
            throw .malformedHunk
        }
        body[body.count - 1].noTrailingNewline = true
    }

    /// Parses `@@ -start[,count] +start[,count] @@` followed by optional section text.
    private static func hunkHeader(_ line: String) -> (old: HunkRange, new: HunkRange)? {
        let bytes = Array(line.utf8)
        var position = 0

        func consume(_ literal: String) -> Bool {
            let expected = Array(literal.utf8)
            guard bytes[position...].starts(with: expected) else { return false }
            position += expected.count
            return true
        }
        func number() -> Int? {
            var value = 0
            let first = position
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) {
                value = value * 10 + Int(bytes[position] - UInt8(ascii: "0"))
                guard value <= maxLineNumber else { return nil }
                position += 1
            }
            return position > first ? value : nil
        }
        func range() -> HunkRange? {
            guard let start = number() else { return nil }
            var count = 1
            if consume(",") {
                guard let parsed = number() else { return nil }
                count = parsed
            }
            if count == 0 { return HunkRange(start: start, first: start + 1, count: 0) }
            return start == 0 ? nil : HunkRange(start: start, first: start, count: count)
        }

        guard consume("@@ -"), let old = range(), consume(" +"), let new = range(), consume(" @@") else {
            return nil
        }
        return (old, new)
    }

    // MARK: - Helpers

    /// `line` without `prefix`, compared by scalars so a combining mark cannot hide a prefix.
    private static func dropPrefix(_ prefix: String, from line: String) -> String? {
        guard line.unicodeScalars.starts(with: prefix.unicodeScalars) else { return nil }
        return String(String.UnicodeScalarView(line.unicodeScalars.dropFirst(prefix.unicodeScalars.count)))
    }

    private static func isMode(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { ("0"..."7").contains($0) }
    }

    private static func isPercentage(_ text: String) -> Bool {
        guard let digits = dropSuffix("%", from: text) else { return false }
        return !digits.isEmpty && digits.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// `<hex>..<hex>` with an optional ` <mode>`.
    private static func isIndexLine(_ text: String) -> Bool {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && isMode(String(parts[1]))) else { return false }
        let hashes = parts[0].components(separatedBy: "..")
        return hashes.count == 2 && hashes.allSatisfy { hash in
            !hash.isEmpty && hash.unicodeScalars.allSatisfy { $0.properties.isASCIIHexDigit }
        }
    }

    private static func dropSuffix(_ suffix: String, from text: String) -> String? {
        guard text.hasSuffix(suffix) else { return nil }
        return String(text.dropLast(suffix.count))
    }
}
