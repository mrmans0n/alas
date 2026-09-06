import Foundation

/// Path validation and payload caps for the remote changes/files surface.
///
/// Every path here arrives from a paired device, so containment is enforced on
/// the resolved (symlink-followed) path, not the string. `.git` is excluded
/// entirely: a worktree's git config can hold remote URLs with embedded
/// credentials.
enum RemoteWorktreeFileAccess {
    static let maxFileBytes = 512 * 1024
    static let maxDiffLines = 2_000
    static let maxChangedFiles = 500
    /// Overall byte budget for a diff payload, on top of the line-count cap.
    /// A single pathological line (e.g. minified/generated code) can stay
    /// under `maxDiffLines` while still being megabytes long, so the line
    /// count alone doesn't bound the wire payload — this does. Matches
    /// `maxFileBytes`'s order of magnitude: a diff is not expected to need a
    /// materially larger budget than a single whole file.
    static let maxDiffBytes = 512 * 1024
    /// Per-line cap: a single line longer than this is truncated with a
    /// marker rather than shipped whole (or dropped silently), so one huge
    /// line can't itself blow the byte budget before the accountant even
    /// gets a chance to stop it.
    static let maxDiffLineBytes = 64 * 1024
    private static let lineTruncationMarker = "…(line truncated)"

    /// Normalizes a client-supplied worktree-relative path: trims surrounding
    /// whitespace/newlines and rejects the same shapes `resolve` rejects
    /// (empty, absolute, upward traversal, `.git`). Returns the normalized
    /// relative path string (e.g. `"src/file.txt"`, no leading/trailing
    /// slashes) or nil when the path is invalid.
    ///
    /// Callers that need to gate access on a path (ignore checks, diff
    /// pathspecs) MUST use this same normalized string — not the raw
    /// caller-supplied path — so the string that decided "is this allowed"
    /// is identical to the string used to actually read/diff the file.
    /// `resolve(path:in:)` calls this internally to build its URL.
    static func normalizedRelativePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        guard !components.contains(".."), !components.contains(".git") else { return nil }

        return components.joined(separator: "/")
    }

    /// Returns the on-disk URL for a worktree-relative path, or nil when the
    /// path is empty, absolute, traverses upward, names `.git`, or resolves
    /// outside the worktree through a symlink.
    static func resolve(path: String, in worktreeRoot: URL) -> URL? {
        guard let normalized = normalizedRelativePath(path) else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        let candidate = components.reduce(worktreeRoot) { $0.appendingPathComponent($1) }
        let resolvedRoot = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { return nil }

        // Check that no component of the resolved path is .git (case-insensitive),
        // including via symlink aliases or case variations. This is the actual
        // security boundary: we check the canonical (symlink-resolved) path,
        // not just the user's input string.
        let resolvedRelativePath = String(resolved.path.dropFirst(rootPath.count))
        let resolvedComponents = resolvedRelativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !resolvedComponents.contains(where: { $0.lowercased() == ".git" }) else { return nil }

        return candidate
    }

    /// Truncates a single line's `text` to `maxDiffLineBytes` UTF-8 bytes,
    /// appending a marker, when it individually exceeds the cap. Keeps the
    /// line (rather than dropping it) so the diff shape (add/delete/context)
    /// stays intact — only the payload is bounded.
    private static func clampedLine(_ line: ParsedDiff.Hunk.Line) -> ParsedDiff.Hunk.Line {
        let bytes = line.text.utf8
        guard bytes.count > maxDiffLineBytes else { return line }
        let markerBytes = lineTruncationMarker.utf8.count
        let keep = max(0, maxDiffLineBytes - markerBytes)
        // Byte-prefix a String's UTF-8 view safely: decode only up to the
        // last complete scalar within `keep` bytes rather than slicing
        // mid-codepoint.
        var prefixByteCount = 0
        var truncatedScalars = String.UnicodeScalarView()
        for scalar in line.text.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard prefixByteCount + scalarByteCount <= keep else { break }
            truncatedScalars.append(scalar)
            prefixByteCount += scalarByteCount
        }
        var result = ParsedDiff.Hunk.Line(
            kind: line.kind,
            text: String(truncatedScalars) + lineTruncationMarker,
            oldNumber: line.oldNumber,
            newNumber: line.newNumber)
        result.noTrailingNewline = line.noTrailingNewline
        return result
    }

    /// Caps a diff at `maxDiffLines` total lines AND `maxDiffBytes` total
    /// UTF-8 bytes of line text, whichever comes first — dropping whole
    /// trailing lines from the hunk that crosses either cap, and truncating
    /// (not shipping whole or dropping silently) any single line that alone
    /// exceeds `maxDiffLineBytes`. Reports whether anything was dropped or
    /// clamped so the client can render a truncation footer.
    static func truncateHunks(_ hunks: [ParsedDiff.Hunk]) -> (hunks: [ParsedDiff.Hunk], truncated: Bool) {
        var remainingLines = maxDiffLines
        var remainingBytes = maxDiffBytes
        var kept: [ParsedDiff.Hunk] = []
        var truncated = false

        hunkLoop: for hunk in hunks {
            if remainingLines <= 0 || remainingBytes <= 0 {
                truncated = true
                break
            }
            var keptLines: [ParsedDiff.Hunk.Line] = []
            for rawLine in hunk.lines {
                if remainingLines <= 0 || remainingBytes <= 0 {
                    truncated = true
                    break
                }
                let line = clampedLine(rawLine)
                if line.text != rawLine.text { truncated = true }
                keptLines.append(line)
                remainingLines -= 1
                remainingBytes -= line.text.utf8.count
            }
            if !keptLines.isEmpty {
                kept.append(ParsedDiff.Hunk(
                    header: hunk.header,
                    oldStart: hunk.oldStart,
                    newStart: hunk.newStart,
                    lines: keptLines))
            }
            if keptLines.count < hunk.lines.count {
                truncated = true
                break hunkLoop
            }
        }
        return (kept, truncated)
    }

    /// Caps a change list at `maxChangedFiles` entries.
    static func truncateFiles(_ files: [ChangedFile]) -> (files: [ChangedFile], truncated: Bool) {
        guard files.count > maxChangedFiles else { return (files, false) }
        return (Array(files.prefix(maxChangedFiles)), true)
    }

    /// Result of an off-main-actor file read for the remote contents
    /// surface. Deliberately independent of the wire protocol type so this
    /// file has no dependency on `Remote/Protocol`.
    enum FileReadOutcome: Equatable {
        case notFound
        case tooLarge(byteSize: Int)
        case binary(byteSize: Int)
        case text(String)
    }

    /// Stats, caps, reads, and UTF-8-decodes `url` entirely off the caller's
    /// actor. The size cap is checked against a cheap `stat` result — BEFORE
    /// any `Data(contentsOf:)` — so a client naming a huge file never forces
    /// a full read. Callers on `@MainActor` (`AppState`) must `await` this
    /// rather than reading the file directly, so an unbounded read never
    /// blocks the UI thread.
    static func readFileContents(at url: URL) async -> FileReadOutcome {
        await Task.detached(priority: .userInitiated) {
            guard let size = fileByteSize(at: url) else { return .notFound }
            guard size <= maxFileBytes else { return .tooLarge(byteSize: size) }
            guard let data = try? Data(contentsOf: url) else { return .notFound }
            guard !GitService.looksBinary(data) else { return .binary(byteSize: data.count) }
            guard let text = String(data: data, encoding: .utf8) else {
                return .binary(byteSize: data.count)
            }
            return .text(text)
        }.value
    }

    /// Sniffs whether `url` looks binary without reading the whole file, off
    /// the caller's actor. `GitService.looksBinary` only ever inspects the
    /// first 8 KB, so a full read buys nothing here but main-thread risk on
    /// a large file.
    static func looksBinaryOnDisk(at url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let sample = (try? handle.read(upToCount: 8192)) ?? Data()
            return GitService.looksBinary(sample)
        }.value
    }

    private static func fileByteSize(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.intValue
    }
}
