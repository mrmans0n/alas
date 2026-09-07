import Foundation
import OSLog

enum RemoteFileStatsError: Error, LocalizedError {
    case directoryListingFailed(path: String)

    var errorDescription: String? {
        switch self {
        case let .directoryListingFailed(path): "Could not list remote directory: \(path)"
        }
    }
}

enum RemoteFileStats {
    private static let logger = Logger(subsystem: "app.alas", category: "RemoteFileStats")
    static let maxBatchedPaths = 200

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
        return paths.map { path in
            let quoted = SSHCommand.shellQuote(path)
            return "n=$(wc -l < \(quoted)); " +
                "if [ -s \(quoted) ] && [ \"$(tail -c1 -- \(quoted) | wc -l)\" -eq 0 ]; then n=$((n + 1)); fi; " +
                "printf '%s %s\\n' \"$n\" \(quoted)"
        }.joined(separator: "; ")
    }

    static func parseWcOutput(_ output: String, requested: [String]) -> [String: Int] {
        let requested = Set(requested)
        return output.split(separator: "\n").reduce(into: [:]) { counts, line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: " "), let count = Int(line[..<separator]) else { return }
            let path = String(line[line.index(after: separator)...])
            if requested.contains(path) { counts[path] = count }
        }
    }

    static func lineCountDictionary(_ entries: [RemoteHelperFSLineCountEntry]) -> [String: Int] {
        entries.reduce(into: [:]) { counts, entry in
            counts[entry.path] = entry.lineCount
        }
    }

    static func lineCounts(host: String, cwd: String, paths: [String]) async -> [String: Int] {
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
                return [:]
            } catch {
                RemoteOperationTiming.log("fs/line-counts", host: host, transport: "helper-fallback", startedAt: startedAt)
            }
        }

        let fallbackPaths = Array(paths.prefix(maxBatchedPaths))
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { RemoteOperationTiming.log("fs/line-counts", host: host, transport: "exec", startedAt: startedAt) }
        guard let command = wcCommand(paths: fallbackPaths),
              let result = try? await RemoteExec.run(host: host, cwd: cwd, command: command),
              !RemoteExec.isConnectionFailure(exitCode: result.exitCode)
        else { return [:] }
        return parseWcOutput(result.stdout, requested: fallbackPaths)
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

    /// GNU-then-BSD `ls` invocation, chained the same way `statMtime` chains
    /// GNU-then-BSD `stat` above: GNU coreutils' `ls --zero` emits
    /// NUL-separated entries so a filename containing an embedded newline
    /// byte doesn't fragment into bogus extra entries when parsed — this
    /// mirrors the NUL-delimited fix already applied to the root Files-tree
    /// listing source (`GitService.gitVisibleFilePaths`'s `git ls-files -z`),
    /// which this exec-fallback directory listing (used for expanding a
    /// directory on a helperless SSH host) hadn't been touched by.
    ///
    /// BSD `ls` (a remote macOS host) has no NUL-delimited output mode at
    /// all, so this falls back to ordinary newline-delimited output there —
    /// a residual, narrower gap: a directory name containing an embedded
    /// newline byte can still fragment when listed via exec on a BSD/macOS
    /// remote host specifically. A host with the persistent helper
    /// installed never hits this at all (it lists via a JSON-safe RPC
    /// instead, where an embedded newline in a name is just another JSON
    /// string byte); this only matters for a helperless remote macOS host,
    /// which is expected to be rare.
    static func lsCommand(path: String) -> String {
        let quoted = SSHCommand.shellQuote(path)
        return "ls -1Ap --zero -- \(quoted) 2>/dev/null || ls -1Ap -- \(quoted)"
    }

    /// Parses `lsCommand`'s output. Detects which branch of the GNU/BSD
    /// fallback actually ran by checking for an embedded NUL byte — a
    /// legitimate filename can never itself contain one on a POSIX
    /// filesystem, so its presence unambiguously means the NUL-delimited
    /// (GNU) branch produced this output rather than the newline-delimited
    /// (BSD) fallback.
    static func parseLsEntries(_ output: String) -> [(name: String, isDirectory: Bool)] {
        let separator: Character = output.contains("\0") ? "\0" : "\n"
        return output.split(separator: separator).map {
            let name = String($0)
            return name.hasSuffix("/") ? (String(name.dropLast()), true) : (name, false)
        }
    }
}
