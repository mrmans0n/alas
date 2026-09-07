import Foundation
import OSLog

enum RemoteFileStatsError: Error, LocalizedError {
    case directoryListingFailed(path: String)
    case lineCountBatchFailed

    var errorDescription: String? {
        switch self {
        case let .directoryListingFailed(path): "Could not list remote directory: \(path)"
        case .lineCountBatchFailed: "Could not count lines for one or more remote files"
        }
    }
}

enum RemoteFileStats {
    private static let logger = Logger(subsystem: "app.alas", category: "RemoteFileStats")
    static let maxBatchedPaths = 200

    /// Splits `paths` into `maxBatchedPaths`-sized chunks, in order —
    /// extracted so the chunk boundaries themselves (e.g. that 450 paths
    /// become 200/200/50, not silently truncated to the first 200) are
    /// directly unit-testable without a real remote exec call.
    static func batches(_ paths: [String]) -> [[String]] {
        guard !paths.isEmpty else { return [] }
        return stride(from: 0, to: paths.count, by: maxBatchedPaths).map {
            Array(paths[$0 ..< min($0 + maxBatchedPaths, paths.count)])
        }
    }

    static func wcCommand(paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        // Plain `wc -l` counts newline BYTES, which undercounts a nonempty
        // file whose final line has no trailing newline by one — git's
        // numstat and the local `addedLineCount` diff-parsing logic both
        // count that trailing partial line, so a one-line file with no
        // trailing newline has a line count of 1, not 0. Loop per file
        // (still a single remote exec round trip) so each raw `wc -l`
        // count is corrected: a nonempty file whose last byte isn't `\n`
        // gets +1.
        //
        // The trailing-newline check pipes `tail -c1` into `wc -l` rather
        // than comparing a captured shell string, so an embedded NUL as
        // the file's final byte — which a shell variable can't hold intact
        // — is still classified correctly: `wc -l` just counts newline
        // bytes piped to it, unaffected by NUL truncation.
        //
        // `--` (on both `wc` and `tail`) stops a filename starting with
        // `-` (e.g. `-c`, `-L`) from being parsed as an OPTION instead of
        // a filename argument, which would silently drop that file from
        // the output (and so silently report 0 for its line count).
        //
        // Records are NUL-terminated, not newline-terminated: an untracked
        // filename containing an embedded newline byte is emitted VERBATIM
        // here (this is the raw path, not a git-escaped rendering of it),
        // and a newline-delimited record would fragment that one file's
        // "<count> <path>" line into two, losing the path→count
        // association entirely (silently reporting `0` for that file
        // instead). NUL can't appear in a POSIX path, so it's a safe
        // separator regardless of what bytes the path itself contains.
        //
        // A file over `RemoteWorktreeFileAccess.maxFileBytes` is counted via
        // a capped `head -c` prefix instead of `wc -l < file` reading it in
        // full: this exec fallback shares the same serialized remote
        // connection every other message on it uses, so a multi-gigabyte
        // untracked file would otherwise occupy that connection (and delay
        // every later message) until the process timeout, mirroring the
        // same cap the persistent-helper path (`AlasHelper`'s
        // `fs_line_counts`) already applies. The capped count is an
        // approximation (a lower bound) — the no-trailing-newline +1
        // adjustment is skipped in that case, since the file's true last
        // byte is outside what was actually read.
        let cap = RemoteWorktreeFileAccess.maxFileBytes
        return paths.map { path in
            let quoted = SSHCommand.shellQuote(path)
            return "size=$(wc -c < \(quoted)); " +
                "if [ \"$size\" -gt \(cap) ]; then " +
                "n=$(head -c \(cap) -- \(quoted) | wc -l); " +
                "else " +
                "n=$(wc -l < \(quoted)); " +
                "if [ -s \(quoted) ] && [ \"$(tail -c1 -- \(quoted) | wc -l)\" -eq 0 ]; then n=$((n + 1)); fi; " +
                "fi; " +
                "printf '%s %s\\0' \"$n\" \(quoted)"
        }.joined(separator: "; ")
    }

    static func parseWcOutput(_ output: String, requested: [String]) -> [String: Int] {
        let requested = Set(requested)
        return output.split(separator: "\u{0}", omittingEmptySubsequences: true).reduce(into: [:]) { counts, rawRecord in
            // Drop LEADING whitespace only — `wc -l`'s own count is
            // right-justified with padding spaces (`n=$(wc -l < file)`
            // captures those verbatim; command substitution only strips
            // TRAILING newlines). The path segment must stay untouched:
            // trimming it too would corrupt a legitimate filename that
            // itself starts or ends with whitespace.
            let record = rawRecord.drop { $0 == " " }
            guard let separator = record.firstIndex(of: " "),
                  let count = Int(record[record.startIndex..<separator])
            else { return }
            let path = String(record[record.index(after: separator)...])
            if requested.contains(path) { counts[path] = count }
        }
    }

    static func lineCountDictionary(_ entries: [RemoteHelperFSLineCountEntry]) -> [String: Int] {
        entries.reduce(into: [:]) { counts, entry in
            counts[entry.path] = entry.lineCount
        }
    }

    /// Throws rather than silently returning a partial (or empty)
    /// dictionary on failure: a caller (`GitService.status`,
    /// `changedFilesAgainstRef`) that can't tell "no lines" from "the count
    /// is simply unknown" defaults every missing path to `0` and reports a
    /// successful change list with wrong addition totals for whichever
    /// files happened to fall in a failed batch, instead of propagating the
    /// failure as `changeListFailed`.
    static func lineCounts(host: String, cwd: String, paths: [String]) async throws -> [String: Int] {
        guard !paths.isEmpty else { return [:] }
        if await RemoteHostCapabilityStore.shared.capabilities(for: host)?.helperHandshake != nil {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let result = try await client.lineCounts(root: cwd, paths: paths)
                RemoteOperationTiming.log("fs/line-counts", host: host, transport: "helper", startedAt: startedAt)
                return lineCountDictionary(result.entries)
            } catch let error as RemoteHelperClientError where !error.shouldFallbackToRemoteExec {
                RemoteOperationTiming.log("fs/line-counts", host: host, transport: "helper", startedAt: startedAt)
                logger.debug("helper line counts failed: \(String(describing: error), privacy: .public)")
                throw error
            } catch {
                RemoteOperationTiming.log("fs/line-counts", host: host, transport: "helper-fallback", startedAt: startedAt)
            }
        }

        // `maxBatchedPaths` bounds a single remote command line's length,
        // not how many paths this function can ever count — silently
        // dropping everything past the first batch (as a single
        // `paths.prefix(maxBatchedPaths)` call used to) would report `0`
        // for every untracked file beyond it, even though the caller's own
        // response cap (`RemoteWorktreeFileAccess.maxChangedFiles`, well
        // above `maxBatchedPaths`) still includes and displays them. Chunk
        // into batches instead, one remote round trip per batch, and merge
        // — throwing (rather than skipping) the first batch that fails, so
        // a transient failure on, say, the third of five batches doesn't
        // silently zero out just those paths.
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { RemoteOperationTiming.log("fs/line-counts", host: host, transport: "exec", startedAt: startedAt) }
        var counts: [String: Int] = [:]
        for chunk in Self.batches(paths) {
            guard let command = wcCommand(paths: chunk) else { continue }
            let result = try await RemoteExec.run(host: host, cwd: cwd, command: command)
            guard !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
                throw RemoteFileStatsError.lineCountBatchFailed
            }
            counts.merge(parseWcOutput(result.stdout, requested: chunk)) { _, new in new }
        }
        return counts
    }

    /// `worktreeRoot` is only used by the helperless exec fallback, to make
    /// containment verification and the listing itself a single remote
    /// script (`RemotePathContainment.containedList`) rather than two
    /// separate round trips racing an intermediate symlink swap between
    /// them. The helper path doesn't need it: the persistent helper already
    /// enforces containment server-side against its own subscribed root.
    /// Throws rather than returning `[]` on failure: a directory that
    /// genuinely has no entries and a directory whose listing FAILED (a
    /// dropped connection, a helper error, containment rejection) look
    /// identical to a caller that only sees an empty array — which
    /// `fileTreeChildren` (and, through it, `remoteFileTree`) previously
    /// turned into a misleadingly "successful" empty directory instead of
    /// `fileTreeFailed`.
    static func directoryEntries(host: String, worktreeRoot: String, path: String) async throws -> [(name: String, isDirectory: Bool)] {
        if await RemoteHostCapabilityStore.shared.capabilities(for: host)?.helperHandshake != nil {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let result = try await client.list(path: path)
                RemoteOperationTiming.log("fs/list", host: host, transport: "helper", startedAt: startedAt)
                return result.entries.map { ($0.name, $0.isDirectory) }
            } catch let error as RemoteHelperClientError where !error.shouldFallbackToRemoteExec {
                RemoteOperationTiming.log("fs/list", host: host, transport: "helper", startedAt: startedAt)
                logger.debug("helper directory listing failed: \(String(describing: error), privacy: .public)")
                throw error
            } catch {
                RemoteOperationTiming.log("fs/list", host: host, transport: "helper-fallback", startedAt: startedAt)
            }
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { RemoteOperationTiming.log("fs/list", host: host, transport: "exec", startedAt: startedAt) }
        switch try await RemotePathContainment.containedList(host: host, path: path, worktreeRoot: worktreeRoot) {
        case .ok(let entries):
            return entries
        case .outsideWorktree:
            throw RemotePathContainment.ContainmentError.outsideWorktree(path)
        case .notADirectory, .unreadable:
            throw RemoteFileStatsError.directoryListingFailed(path: path)
        }
    }

    /// Sentinel marking the boundary between the directory- and file-type
    /// records `lsCommand` prints, as a NUL-delimited "entry" of its own.
    /// Only misclassifies a real filesystem entry if it happens to be named
    /// EXACTLY this string — an astronomically unlikely collision, and a
    /// far narrower failure mode than the one this replaces (see
    /// `lsCommand`'s doc comment).
    static let lsSplitMarker = "__alas_ls_split__"

    /// Two `find` invocations, immediate children only, NUL-delimited,
    /// split into a directories batch and a files batch by a sentinel
    /// record in between — used instead of `ls -1Ap`/GNU `ls --zero` (which
    /// this used to be) because `find -print0` is NUL-safe on BOTH GNU
    /// findutils AND BSD `find` (unlike `ls`, whose `--zero` NUL-delimited
    /// mode has no BSD equivalent at all). A filename containing an
    /// embedded newline byte previously fragmented into bogus extra entries
    /// whenever a helperless SSH host's `ls` fell back to its
    /// newline-delimited form (any remote macOS host, since BSD `ls` never
    /// supports `--zero`) — including possible ignore-rule misclassification
    /// from those bogus fragments. `find`'s NUL-safety applies uniformly
    /// everywhere, so there's no GNU/BSD branch left to fall back from.
    ///
    /// `-mindepth 1` excludes the directory itself (matching `ls -A`'s
    /// omission of `.`/`..`); dotfiles are included by default (`find` has
    /// no separate "hidden" concept requiring an extra flag, unlike `ls`'s
    /// `-A`).
    static func lsCommand(path: String) -> String {
        let quoted = SSHCommand.shellQuote(path)
        return "find \(quoted) -mindepth 1 -maxdepth 1 -type d -print0; " +
            "printf '\\0\(lsSplitMarker)\\0'; " +
            "find \(quoted) -mindepth 1 -maxdepth 1 ! -type d -print0"
    }

    /// Parses `lsCommand`'s output: NUL-delimited full paths, split into
    /// directories (before the sentinel) and files (after it). The
    /// basename is taken as everything after the LAST `/` — safe
    /// regardless of what other bytes (including an embedded newline) the
    /// name itself contains, since `/` can never be part of a POSIX
    /// filename component.
    static func parseLsEntries(_ output: String) -> [(name: String, isDirectory: Bool)] {
        let records = output.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        guard let splitIndex = records.firstIndex(of: lsSplitMarker) else {
            return records.map { (basename(of: $0), false) }
        }
        let directories = records[..<splitIndex].map { (basename(of: $0), true) }
        let files = records[(splitIndex + 1)...].map { (basename(of: $0), false) }
        return directories + files
    }

    private static func basename(of fullPath: String) -> String {
        guard let lastSlash = fullPath.lastIndex(of: "/") else { return fullPath }
        return String(fullPath[fullPath.index(after: lastSlash)...])
    }
}
