import Foundation
import Darwin

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
    /// Cap on the RAW `git diff` subprocess output `GitService`'s diff
    /// methods capture, before `DiffParser` even runs — comfortably above
    /// `maxDiffBytes` (8x) so an ordinary large diff is captured in full and
    /// `truncateHunks` below still makes the exact truncation call; only a
    /// genuinely pathological diff (a multi-gigabyte generated file) is cut
    /// short here, before parsing ever materializes it into hunks. See
    /// `Process.runCapped`.
    static let maxDiffSubprocessBytes = maxDiffBytes * 8
    private static let lineTruncationMarker = "…(line truncated)"

    /// Normalizes a client-supplied worktree-relative path: rejects the same
    /// shapes `resolve` rejects (empty/whitespace-only, absolute, upward
    /// traversal, `.git`) and returns the ORIGINAL path's exact bytes (no
    /// leading/trailing slashes stripped beyond splitting on `/`) — not a
    /// trimmed copy. A real file can legitimately be named with leading or
    /// trailing whitespace; git does not trim filenames, so trimming here
    /// would silently resolve a client's exact selection to a DIFFERENT
    /// path than the one it asked for. Trimming is used only to decide
    /// whether the input is empty/meaningless, never to build the string
    /// callers actually resolve/serve.
    ///
    /// Callers that need to gate access on a path (ignore checks, diff
    /// pathspecs) MUST use this same normalized string — not the raw
    /// caller-supplied path — so the string that decided "is this allowed"
    /// is identical to the string used to actually read/diff the file.
    /// `resolve(path:in:)` calls this internally to build its URL.
    static func normalizedRelativePath(_ path: String) -> String? {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !path.hasPrefix("/") else { return nil }

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        guard !components.contains(".."), !components.contains(".git") else { return nil }

        return components.joined(separator: "/")
    }

    /// True when `url` itself — not whatever it may point to — is a
    /// symbolic link. `.isSymbolicLinkKey` is computed on the link itself
    /// (lstat semantics), not its resolved target, so this is accurate even
    /// for a dangling link. Local file/diff reads reject ANY symlink
    /// outright rather than resolving-and-rechecking the target: an ignore
    /// check against the alias name says nothing about the content actually
    /// served by transparently following the link at the OS level (e.g.
    /// `Data(contentsOf:)`), which is exactly the bypass shape already
    /// closed above for `.git` symlink aliases and for the SSH read path's
    /// `.symlink` outcome (mapped to `.notFound` rather than followed).
    static func isSymlink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
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
                // `clampedLine` only bounds a single line to
                // `maxDiffLineBytes` — that clamped size can still be
                // larger than what's left of the OVERALL `maxDiffBytes`
                // budget. Check the fit BEFORE appending (not just
                // `remainingBytes <= 0` at the top of the loop, which only
                // catches an ALREADY-exhausted budget) so the very last line
                // kept can never itself push the total past the cap.
                let lineByteCount = line.text.utf8.count
                guard lineByteCount <= remainingBytes else {
                    truncated = true
                    break
                }
                if line.text != rawLine.text { truncated = true }
                keptLines.append(line)
                remainingLines -= 1
                remainingBytes -= lineByteCount
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

    /// Number of bytes `looksBinaryOnDisk` sniffs — matches
    /// `GitService.looksBinary`'s own 8 KB inspection window, so a binary
    /// sniff never needs more than that.
    private static let binarySniffPrefixBytes = 8192

    /// Outcome of `openReadCapped`, the single-descriptor open+fstat+read
    /// primitive both `readFileContents` and `looksBinaryOnDisk` funnel
    /// through.
    private enum RawReadOutcome {
        case notFound
        case tooLarge(byteSize: Int)
        case data(Data)
    }

    /// Opens `url` and, on success, returns a descriptor already `fstat`-
    /// verified as a *regular file* — never a symlink, directory, FIFO, or
    /// other special file. Callers own the returned descriptor and must
    /// `close` it.
    ///
    /// `O_NOFOLLOW` rejects a symlink at the FINAL path component atomically
    /// with the open itself (no separate `lstat`-then-`open` gap to race).
    /// `O_NONBLOCK` prevents `open` from blocking forever on a FIFO with no
    /// writer — without it, opening a named pipe for reading blocks
    /// indefinitely, which (since `RemoteSessionGateway` serializes ordinary
    /// messages per connection) would hang every subsequent message on that
    /// connection too. `O_NONBLOCK` is a no-op for regular files, so it
    /// changes nothing about how the eventual read behaves once `fstat`
    /// confirms `S_IFREG`.
    ///
    /// This closes a specific time-of-check/time-of-use gap: `resolve()`
    /// already canonicalizes and validates the full path (including
    /// intermediate symlinks) once, up front. The remaining gap was that a
    /// LATER, separate operation (`Data(contentsOf:)`, or a separate `stat`
    /// call) re-resolved the same path string from scratch, giving a
    /// concurrently-running process a window to swap a path component for a
    /// symlink between the check and that later re-resolution. Threading a
    /// single already-opened descriptor through open → fstat (regular-file
    /// check) → read means there is no later re-resolution left to race:
    /// whatever the kernel resolved when `open` succeeded is exactly what
    /// every subsequent `fstat`/`read` call on that descriptor sees.
    ///
    /// Not perfect: `resolve()`'s own canonicalization (`resolvingSymlinksInPath`)
    /// and this `open` call are still two separate filesystem operations, so
    /// an intermediate directory component could theoretically be swapped
    /// for a symlink in between them. That residual window is far narrower
    /// than the one this closes (a single open syscall's worth of time, vs.
    /// the entire duration of an unrelated later read), and closing it
    /// completely would require a hand-rolled `openat`-per-component walk;
    /// not implemented here as disproportionate to the residual risk.
    private static func openRegularFileNoFollow(at url: URL) -> Int32? {
        let fd = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            return open(representation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Reads the ENTIRE contents of `url` via a single open/fstat/read
    /// sequence (see `openRegularFileNoFollow`), capped at `maxBytes`. The
    /// size check and the read both happen against the SAME already-opened
    /// descriptor — no re-`stat`, no re-`open` by path — so a concurrent
    /// write growing the file past the cap after `fstat` is still caught by
    /// the read loop's own running total rather than a stale earlier stat.
    private static func openReadCapped(at url: URL, maxBytes: Int) -> RawReadOutcome {
        guard let fd = openRegularFileNoFollow(at: url) else { return .notFound }
        defer { close(fd) }

        var status = stat()
        guard fstat(fd, &status) == 0 else { return .notFound }
        let statedSize = Int(clamping: status.st_size)
        if statedSize > maxBytes {
            return .tooLarge(byteSize: statedSize)
        }

        // Read via the SAME fd, capped at `maxBytes + 1` so a file that
        // grows past the cap after `fstat` (e.g. a concurrent writer) is
        // still caught here rather than silently served in full.
        var data = Data()
        data.reserveCapacity(min(statedSize, maxBytes) + 1)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxBytes {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                read(fd, pointer.baseAddress, pointer.count)
            }
            guard bytesRead > 0 else { break }
            data.append(contentsOf: buffer[0..<bytesRead])
        }
        if data.count > maxBytes {
            return .tooLarge(byteSize: data.count)
        }
        return .data(data)
    }

    /// Reads only the first `maxBytes` of `url` (or fewer if the file is
    /// smaller), via the same `openRegularFileNoFollow` open+fstat sequence,
    /// WITHOUT treating a larger total file size as an error — this is a
    /// bounded-prefix sniff, not a capped whole-file read. Returns nil when
    /// the path can't be opened as a validated regular file.
    private static func openReadPrefix(at url: URL, maxBytes: Int) -> Data? {
        guard let fd = openRegularFileNoFollow(at: url) else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
            read(fd, pointer.baseAddress, pointer.count)
        }
        guard bytesRead >= 0 else { return nil }
        return Data(buffer[0..<bytesRead])
    }

    /// Stats, caps, reads, and UTF-8-decodes `url` entirely off the caller's
    /// actor, via a single open/fstat/read sequence (`openReadCapped`) so no
    /// path is ever re-resolved between the size check and the actual read.
    /// Callers on `@MainActor` (`AppState`) must `await` this rather than
    /// reading the file directly, so an unbounded read never blocks the UI
    /// thread.
    static func readFileContents(at url: URL) async -> FileReadOutcome {
        await Task.detached(priority: .userInitiated) {
            switch openReadCapped(at: url, maxBytes: maxFileBytes) {
            case .notFound: return .notFound
            case .tooLarge(let byteSize): return .tooLarge(byteSize: byteSize)
            case .data(let data):
                guard !GitService.looksBinary(data) else { return .binary(byteSize: data.count) }
                guard let text = String(data: data, encoding: .utf8) else {
                    return .binary(byteSize: data.count)
                }
                return .text(text)
            }
        }.value
    }

    /// Sniffs whether `url` looks binary without reading the whole file, off
    /// the caller's actor, via the same `openRegularFileNoFollow` open+fstat
    /// sequence so a symlink or non-regular file (including a FIFO with no
    /// writer — see `openRegularFileNoFollow`'s doc comment) can never block
    /// or bypass validation here either. Reads only a bounded PREFIX
    /// (`openReadPrefix`), regardless of the file's total size — a file
    /// larger than the sniff window is not itself an error here, unlike the
    /// whole-file cap `readFileContents` enforces.
    static func looksBinaryOnDisk(at url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let sample = openReadPrefix(at: url, maxBytes: binarySniffPrefixBytes) else { return false }
            return GitService.looksBinary(sample)
        }.value
    }
}
