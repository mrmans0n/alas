import Foundation
import os

/// Streams content-search hits from `rg --json`. One `search(...)` call
/// runs rg once per worktree, sequentially, and yields hits as they
/// arrive. Cancellation terminates the running rg child.
///
/// Discovery: `which rg` is consulted on every `search(...)` call (cheap;
/// not memoized).
final class ContentSearcher: Sendable {
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "search.content")

    /// Find an `rg` binary. Tries `which rg` first, then checks common
    /// installation paths (Homebrew, /usr/local/bin) as a fallback for
    /// environments where PATH is restricted (e.g. xcodebuild test runners).
    static func discoverRg() async -> String? {
        if let found = try? await asyncWhich("rg") { return found }
        let candidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum SearchError: Error, Equatable {
        case rgNotFound
        /// rg's regex engine rejected the pattern. NSRegularExpression's
        /// up-front preflight catches most syntax errors, but rg's Rust
        /// regex (without --pcre2) rejects features NSRegular accepts —
        /// notably look-around `(?=…)` and backreferences. Detected via
        /// known stderr markers.
        case regexInvalid
        /// rg exited with a non-success, non-no-match status that wasn't
        /// detected as a regex error — most commonly a soft I/O failure
        /// (unreadable file, permission denied).
        case rgFailed(exitCode: Int32)
    }

    /// Stream all matches across the given worktrees. Each emitted hit
    /// already has its `worktreeId`/`projectId`/`relativePath` set.
    func search(
        query: String,
        options: SearchContentOptions,
        worktrees: [SearchWorktree]
    ) -> AsyncThrowingStream<ContentSearchHit, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let rg = await Self.discoverRg() else {
                    continuation.finish(throwing: SearchError.rgNotFound)
                    return
                }
                var deferredFailure: Error? = nil
                for wt in worktrees {
                    if Task.isCancelled { break }
                    do {
                        try await self.streamRg(
                            rg: rg,
                            query: query,
                            options: options,
                            worktree: wt,
                            into: continuation
                        )
                    } catch is CancellationError {
                        // Cancellation must propagate — it's not a per-
                        // worktree failure, the whole search is being
                        // superseded.
                        continuation.finish()
                        return
                    } catch {
                        // Catch ANY error per-worktree, not just SearchError.
                        // `process.run()` can throw NSCocoaErrorDomain (cwd
                        // missing for a stale linked worktree) before rg ever
                        // produces a SearchError. Continuing past these keeps
                        // `.allRepos` searching the remaining worktrees.
                        self.logger.notice(
                            "rg failure in \(wt.absolutePath.path, privacy: .public): \(String(describing: error))"
                        )
                        deferredFailure = error
                    }
                }
                if let deferredFailure {
                    continuation.finish(throwing: deferredFailure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamRg(
        rg: String,
        query: String,
        options: SearchContentOptions,
        worktree: SearchWorktree,
        into continuation: AsyncThrowingStream<ContentSearchHit, Error>.Continuation
    ) async throws {
        // `--hidden` so dotfiles (e.g. .github/, .swiftlint.yml, .env.example)
        // are searched. `git ls-files` already returns them, so file mode
        // can find them by name; without this flag content mode silently
        // misses any matches inside them. `.gitignore` is still respected.
        // Exclude `.git/` itself so ripgrep doesn't descend into repo
        // metadata (refs, logs, packed objects) — that bloats the 50-file
        // / 200-hit caps with non-source results.
        var args: [String] = [
            "--json",
            "--hidden",
            "--glob", "!.git",
            "--max-count=200",
            "--max-columns=400",
        ]
        if options.caseSensitive { args.append("--case-sensitive") } else { args.append("--smart-case") }
        if options.wholeWord     { args.append("--word-regexp") }
        if !options.regex        { args.append("--fixed-strings") }
        args.append("--")
        args.append(query)
        args.append(".")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        process.arguments = args
        process.currentDirectoryURL = worktree.absolutePath

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        // Capture stderr to a small bounded buffer. We drain concurrently
        // so a chatty rg (warnings, debug noise) can't fill the pipe and
        // block the child, but cap accumulated bytes so a pathological
        // case (thousands of warnings) doesn't balloon memory either.
        process.standardError = errPipe

        let handle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let stderrBuf = StderrBuffer(capBytes: 8192)
        let drainTask = Task.detached {
            while true {
                let data = errHandle.availableData
                if data.isEmpty { break }
                await stderrBuf.append(data)
            }
        }

        try process.run()

        // `availableData` blocks until bytes arrive or EOF; it doesn't
        // observe `Task.isCancelled`. Wire cancellation to terminate the
        // child, which closes the pipe → reads return EOF immediately.
        await withTaskCancellationHandler {
            await self.readAllLines(handle: handle) { lineData in
                if let hit = self.parseRgLine(lineData, worktree: worktree) {
                    continuation.yield(hit)
                }
            }
        } onCancel: {
            // Called from any thread, possibly during a blocking read.
            process.terminate()
        }

        if process.isRunning { process.terminate() }
        // Wait for the child via `terminationHandler` instead of the
        // blocking `waitUntilExit()` so the cooperative pool thread is
        // yielded while we wait.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if !process.isRunning {
                cont.resume()
            } else {
                process.terminationHandler = { _ in cont.resume() }
            }
        }
        // Wait for stderr drain so any error text is visible below.
        _ = await drainTask.value

        // ripgrep exits 0 on matches, 1 on no matches, 2+ on its own errors.
        // Skip the check if we cancelled the child ourselves.
        if !Task.isCancelled,
           process.terminationReason == .exit,
           process.terminationStatus > 1 {
            let stderr = await stderrBuf.text
            // rg's regex parse errors begin with "regex parse error" or
            // mention unsupported look-around / backreference features.
            // Distinguish those from soft I/O errors so the model can
            // surface "Invalid regex pattern." instead of a generic banner.
            let lower = stderr.lowercased()
            if lower.contains("regex parse error")
                || lower.contains("look-around")
                || lower.contains("backreference") {
                throw SearchError.regexInvalid
            }
            throw SearchError.rgFailed(exitCode: process.terminationStatus)
        }
    }

    /// Read newline-delimited output from `handle`, calling `onLine` for
    /// each complete line. Returns when the pipe reports EOF. Uses
    /// `readabilityHandler` so the cooperative pool thread is yielded
    /// between chunks instead of blocking on `availableData`.
    private func readAllLines(
        handle: FileHandle,
        onLine: @escaping (Data) -> Void
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var leftover = Data()
            var didResume = false
            let resume: () -> Void = {
                if !didResume {
                    didResume = true
                    cont.resume()
                }
            }
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    fh.readabilityHandler = nil
                    if !leftover.isEmpty { onLine(leftover) }
                    resume()
                    return
                }
                leftover.append(chunk)
                while let nl = leftover.firstIndex(of: 0x0A) {
                    let line = leftover[..<nl]
                    leftover.removeSubrange(...nl)
                    onLine(Data(line))
                }
            }
        }
    }

    /// Parse one rg JSON line. Only `match` events produce hits.
    /// Format reference: https://docs.rs/grep-printer/latest/grep_printer/struct.JSON.html
    private func parseRgLine(_ data: Data, worktree: SearchWorktree) -> ContentSearchHit? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "match",
              let payload = obj["data"] as? [String: Any],
              let lineNumber = payload["line_number"] as? Int,
              let rawPath = (payload["path"] as? [String: Any])?["text"] as? String,
              let lineBlob = (payload["lines"] as? [String: Any])?["text"] as? String
        else { return nil }
        // rg launched with `.` as the search path emits leading "./" on
        // every relative path. Strip it so paths align with the cleaner
        // form produced by `git ls-files` (and used as group keys).
        let pathBlob = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
        let submatches = (payload["submatches"] as? [[String: Any]]) ?? []
        let first = submatches.first
        let colByte = (first?["start"] as? Int) ?? 0
        let endColByte = (first?["end"] as? Int) ?? colByte
        let rawSnippet = lineBlob.trimmingCharacters(in: .newlines)
        let column = charOffset(forByteOffset: colByte, in: rawSnippet).map { $0 + 1 } ?? (colByte + 1)
        let revealColumn = utf16Offset(forByteOffset: colByte, in: rawSnippet).map { $0 + 1 } ?? column

        // `--max-columns=400` doesn't apply in `--json` mode (per rg --help).
        // For a single very long line — minified JS, generated JSON, lockfiles —
        // `lineBlob` can be megabytes; window the stored snippet around the
        // match so the user actually sees what matched, not just the line's
        // first 400 chars (which often don't include the match).
        let (trimmedSnippet, charRange) = windowSnippet(
            raw: rawSnippet,
            matchStartByte: colByte,
            matchEndByte: endColByte
        )

        return ContentSearchHit(
            worktreeId: worktree.id,
            projectId: worktree.projectId,
            relativePath: pathBlob,
            line: lineNumber,
            column: column,
            revealColumn: revealColumn,
            snippet: trimmedSnippet,
            matchCharRange: charRange
        )
    }

    /// Convert a UTF-8 byte offset into a Character (grapheme) offset within
    /// the given string. Returns nil if `bytes` is out of bounds or does not
    /// fall on a character boundary.
    private func charOffset(forByteOffset bytes: Int, in s: String) -> Int? {
        guard bytes >= 0, bytes <= s.utf8.count else { return nil }
        let utf8Index = s.utf8.index(s.utf8.startIndex, offsetBy: bytes)
        guard let charIndex = utf8Index.samePosition(in: s) else { return nil }
        return s.distance(from: s.startIndex, to: charIndex)
    }

    /// Convert a UTF-8 byte offset into the UTF-16 offset expected by
    /// NSTextStorage/NSString-based editor APIs.
    private func utf16Offset(forByteOffset bytes: Int, in s: String) -> Int? {
        guard bytes >= 0, bytes <= s.utf8.count else { return nil }
        let utf8Index = s.utf8.index(s.utf8.startIndex, offsetBy: bytes)
        guard let utf16Index = utf8Index.samePosition(in: s.utf16) else { return nil }
        return s.utf16.distance(from: s.utf16.startIndex, to: utf16Index)
    }

    /// Bound a snippet to ~400 characters, centered on the matched range.
    /// Returns the trimmed snippet plus a Character range pointing into it
    /// for highlighting (or nil if the offsets don't align with grapheme
    /// boundaries). For lines at or below the cap, returns the line as-is.
    private func windowSnippet(
        raw: String,
        matchStartByte: Int,
        matchEndByte: Int
    ) -> (snippet: String, charRange: Range<Int>?) {
        let cap = 400
        // Convert byte offsets in the original line first — they're stable
        // there even if we end up windowing.
        guard let matchStartChar = charOffset(forByteOffset: matchStartByte, in: raw),
              let matchEndChar   = charOffset(forByteOffset: matchEndByte,   in: raw) else {
            // Couldn't align; truncate plainly and skip highlighting.
            let truncated = raw.count > cap ? String(raw.prefix(cap)) + "…" : raw
            return (truncated, nil)
        }
        let total = raw.count
        if total <= cap {
            let charRange = matchStartChar < matchEndChar
                ? matchStartChar..<matchEndChar
                : nil
            return (raw, charRange)
        }
        // Window: try to keep ~`pad` chars on each side of the match. The
        // window itself is hard-capped to `cap` chars regardless of how
        // wide the match is — a regex like `.*` can match a full minified
        // line, and we don't want to ship that much text.
        let matchLen = matchEndChar - matchStartChar
        let pad = max(0, (cap - min(matchLen, cap)) / 2)
        let desiredStart = matchStartChar - pad
        let windowStart = max(0, min(desiredStart, total - cap))
        let windowEnd = min(total, windowStart + cap)
        let leadEllipsis  = windowStart > 0
        let trailEllipsis = windowEnd < total
        let startIdx = raw.index(raw.startIndex, offsetBy: windowStart)
        let endIdx   = raw.index(raw.startIndex, offsetBy: windowEnd)
        let middle = String(raw[startIdx..<endIdx])
        let snippet = (leadEllipsis ? "…" : "") + middle + (trailEllipsis ? "…" : "")
        let prefixLen = leadEllipsis ? 1 : 0
        let adjStart = matchStartChar - windowStart + prefixLen
        // Clamp the highlight end to the snippet — when the match itself
        // is wider than `cap`, the trailing portion gets truncated and we
        // highlight all the way to the snippet boundary.
        let snippetCount = snippet.count
        let adjEnd = min(matchEndChar - windowStart + prefixLen, snippetCount)
        let charRange: Range<Int>?
        if adjStart >= 0, adjStart < adjEnd, adjEnd <= snippetCount {
            charRange = adjStart..<adjEnd
        } else {
            charRange = nil
        }
        return (snippet, charRange)
    }
}

/// Bounded accumulator for an rg child's stderr. The pipe drain task
/// appends chunks until the cap is reached, then silently drops the rest
/// — enough to detect known regex-error markers without ballooning
/// memory if rg emits thousands of warnings.
private actor StderrBuffer {
    private var data = Data()
    private let cap: Int
    init(capBytes: Int) { self.cap = capBytes }
    func append(_ chunk: Data) {
        guard data.count < cap else { return }
        let room = cap - data.count
        data.append(chunk.prefix(room))
    }
    var text: String { String(data: data, encoding: .utf8) ?? "" }
}

/// Locate `name` on PATH via `which`. Uses the async `Process.run` helper
/// so the cooperative pool isn't blocked by `waitUntilExit`.
private func asyncWhich(_ name: String) async throws -> String? {
    let result = try await Process.run(
        "/usr/bin/env",
        args: ["which", name]
    )
    guard result.exitCode == 0 else { return nil }
    let s = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}
