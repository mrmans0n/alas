import Foundation

enum RemotePathContainment {
    enum ContainmentError: Error, LocalizedError {
        case outsideWorktree(String)

        var errorDescription: String? {
            switch self {
            case let .outsideWorktree(path): "Path is outside the worktree: \(path)"
            }
        }
    }

    static func lexicallyResolveInsideWorktree(path: String, worktreeRoot: String) throws -> String {
        let absolute = path.hasPrefix("/") ? path : worktreeRoot + "/" + path
        let normalized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard normalized == worktreeRoot || normalized.hasPrefix(worktreeRoot + "/") else {
            throw ContainmentError.outsideWorktree(path)
        }
        return normalized
    }

    static func containmentProbeCommand(path: String, worktreeRoot: String) -> String {
        let root = SSHCommand.shellQuote(worktreeRoot)
        let target = SSHCommand.shellQuote(path)
        return """
        root=\(root); target=\(target); parent=$(dirname "$target"); existing="$parent"; \
        while [ ! -e "$existing" ]; do next=$(dirname "$existing"); [ "$next" = "$existing" ] && exit 3; existing="$next"; done; \
        root_phys=$(cd "$root" && pwd -P) || exit 4; existing_phys=$(cd "$existing" && pwd -P) || exit 5; \
        case "$existing_phys" in "$root_phys"|"$root_phys"/*) exit 0 ;; *) exit 6 ;; esac
        """
    }

    /// Like `containmentProbeCommand`, but fully resolves the ENTIRE target
    /// path (not just its parent) to its physical/canonical form and rejects
    /// when any resulting path component, relative to the worktree's own
    /// canonical root, case-insensitively equals `.git`.
    ///
    /// This closes a gap `containmentProbeCommand` alone does not: a
    /// directory symlink alias to `.git` (e.g. `alias -> .git` inside the
    /// worktree) physically resolves to a location that IS still under the
    /// worktree root, so a request for `alias/config` passes plain
    /// containment while actually serving `.git/config` — which can contain
    /// remote URLs with embedded credentials.
    ///
    /// Exit codes: 0 = contained and outside `.git`; 3 = no existing
    /// ancestor found; 4/5 = `cd`/`pwd -P` failed; 6 = resolves outside the
    /// worktree root; 7 = resolves inside `.git`.
    static func containmentExcludingGitProbeCommand(path: String, worktreeRoot: String) -> String {
        let root = SSHCommand.shellQuote(worktreeRoot)
        let target = SSHCommand.shellQuote(path)
        return """
        root=\(root); target=\(target); root_phys=$(cd "$root" && pwd -P) || exit 4; \
        existing="$target"; tail=""; \
        while [ ! -e "$existing" ]; do \
        comp=$(basename "$existing"); \
        if [ -z "$tail" ]; then tail="$comp"; else tail="$comp/$tail"; fi; \
        next=$(dirname "$existing"); [ "$next" = "$existing" ] && exit 3; existing="$next"; \
        done; \
        if [ -d "$existing" ]; then existing_phys=$(cd "$existing" && pwd -P) || exit 5; else \
        comp=$(basename "$existing"); existing=$(dirname "$existing"); \
        if [ -z "$tail" ]; then tail="$comp"; else tail="$comp/$tail"; fi; \
        existing_phys=$(cd "$existing" && pwd -P) || exit 5; \
        fi; \
        full_phys="$existing_phys"; [ -n "$tail" ] && full_phys="$existing_phys/$tail"; \
        case "$full_phys" in \
        "$root_phys") rel="" ;; \
        "$root_phys"/*) rel=${full_phys#"$root_phys"/} ;; \
        *) exit 6 ;; \
        esac; \
        rest="$rel"; \
        while [ -n "$rest" ]; do \
        case "$rest" in \
        */*) comp=${rest%%/*}; rest=${rest#*/} ;; \
        *) comp="$rest"; rest="" ;; \
        esac; \
        case "$comp" in .[Gg][Ii][Tt]) exit 7 ;; esac; \
        done; \
        exit 0
        """
    }

    static func verifyRemoteContainment(host: String, path: String, worktreeRoot: String) async throws {
        let target = try lexicallyResolveInsideWorktree(path: path, worktreeRoot: worktreeRoot)
        let result = try await RemoteExec.run(
            host: host, cwd: nil,
            command: containmentExcludingGitProbeCommand(path: target, worktreeRoot: worktreeRoot))
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        guard result.exitCode == 0 else {
            throw ContainmentError.outsideWorktree(path)
        }
    }

    /// Exit codes for `containedReadScript`, layered on top of
    /// `containmentExcludingGitProbeCommand`'s own 3/4/5/6/7 (see that
    /// function's doc comment): 8 = resolves to a symlink; 9 = resolves to a
    /// directory; 10 = resolves to something that no longer exists by the
    /// time the read runs; 11 = `stat` on the resolved path failed.
    enum ContainedReadOutcome: Equatable {
        case ok(byteSize: Int, prefix: Data)
        case outsideWorktree
        case symlink
        case directory
        case missing
        case unreadable
    }

    /// Combines containment verification and a bounded content read into a
    /// SINGLE remote script, so there is only one round trip — and, more
    /// importantly, only one PATH RESOLUTION — between "is this path
    /// contained" and "read its bytes".
    ///
    /// `containmentExcludingGitProbeCommand` alone resolves `path` to its
    /// canonical, physical form (`full_phys`) purely to answer a yes/no
    /// containment question; a caller that then wants the file's contents
    /// has historically made a SEPARATE round trip (`RemoteFileAccess.size`
    /// then `.read`), each of which re-resolves the same path STRING from
    /// scratch via its own `[ -L "$f" ]` / `cat`/`head` invocation. Between
    /// those round trips, a concurrently-running remote process can swap a
    /// path component for a symlink: the containment check saw a safe path,
    /// but the later read re-resolves the (now poisoned) string independently
    /// and can escape the worktree.
    ///
    /// This script closes that gap by reusing the SAME `full_phys` value —
    /// computed once, physically resolved via `cd ... && pwd -P` — for both
    /// the containment/`.git`-exclusion check AND the subsequent symlink/
    /// directory/existence checks and the bounded `head -c` read. Nothing
    /// after the initial resolution re-resolves `path` by string.
    ///
    /// Residual risk: this is one shell script, but still several distinct
    /// system calls (`stat`, `head`) against `$full_phys` in sequence, not a
    /// single atomic kernel operation — a component of `$full_phys` could in
    /// principle still be swapped between, say, the `[ -L ]` check and the
    /// `head -c` call. That window is now a handful of shell builtins deep
    /// inside one non-interactive ssh invocation (sub-millisecond on a
    /// healthy connection) rather than the full duration of a separate
    /// round trip (network latency plus whatever else runs between the two
    /// calls on the Swift side) — a substantial, but not perfect,
    /// narrowing. A fully atomic remote primitive would require a small
    /// remote-side helper program doing `openat`-per-component plus
    /// `O_NOFOLLOW`, which is out of scope here.
    static func containedReadScript(path: String, worktreeRoot: String, maxBytes: Int) -> String {
        let probe = containmentExcludingGitProbeCommand(path: path, worktreeRoot: worktreeRoot)
        // `containmentExcludingGitProbeCommand` ends in `exit 0` on success
        // with `$full_phys` holding the resolved, contained, non-`.git`
        // path. Splice the read logic in place of that final `exit 0` so it
        // runs in the SAME shell, against the SAME `full_phys` variable,
        // rather than a separate script/round trip.
        let probeWithoutFinalExit = probe.hasSuffix("exit 0")
            ? String(probe.dropLast("exit 0".count))
            : probe
        return probeWithoutFinalExit + """
        [ -L "$full_phys" ] && exit 8; \
        [ -d "$full_phys" ] && exit 9; \
        [ -e "$full_phys" ] || exit 10; \
        size=$(stat -c %s -- "$full_phys" 2>/dev/null || stat -f %z "$full_phys") || exit 11; \
        echo "$size"; \
        head -c \(maxBytes) "$full_phys"
        """
    }

    /// Runs `containedReadScript` over one `RemoteExec.runData` round trip.
    /// Only ever transfers up to `maxBytes` of the file's body regardless of
    /// its actual size — `head -c` stops the remote `head` process itself,
    /// so an oversized file never gets fully read remotely just to be told
    /// "too large".
    static func containedRead(host: String, path: String, worktreeRoot: String, maxBytes: Int) async throws -> ContainedReadOutcome {
        let target = try lexicallyResolveInsideWorktree(path: path, worktreeRoot: worktreeRoot)
        let result = try await RemoteExec.runData(
            host: host, cwd: nil,
            command: containedReadScript(path: target, worktreeRoot: worktreeRoot, maxBytes: maxBytes))
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        switch result.exitCode {
        case 0:
            guard let newline = result.stdout.firstIndex(of: UInt8(ascii: "\n")),
                  let header = String(data: result.stdout[result.stdout.startIndex..<newline], encoding: .utf8),
                  let byteSize = Int(header.trimmingCharacters(in: .whitespaces))
            else {
                return .unreadable
            }
            let body = Data(result.stdout[result.stdout.index(after: newline)...])
            return .ok(byteSize: byteSize, prefix: body)
        case 6, 7:
            return .outsideWorktree
        case 8:
            return .symlink
        case 9:
            return .directory
        case 10:
            return .missing
        default:
            return .unreadable
        }
    }

    /// Exit codes for `containedListScript`, layered on top of
    /// `containmentExcludingGitProbeCommand`'s own 3/4/5/6/7: 9 = resolves
    /// to something other than a directory.
    enum ContainedListOutcome {
        case ok(entries: [(name: String, isDirectory: Bool)])
        case outsideWorktree
        case notADirectory
        case unreadable
    }

    /// Same one-script pattern as `containedReadScript`, for listing a
    /// directory instead of reading a file: containment verification and the
    /// listing itself reuse the SAME `full_phys` value, so there is no later,
    /// separate `ls` invocation that re-resolves the path string from
    /// scratch — which is exactly the gap a helperless SSH worktree's
    /// directory expansion had (containment checked once, then a plain `ls`
    /// against the raw path a moment later, wide open to an intermediate
    /// directory being swapped for a symlink in between).
    ///
    /// GNU-then-BSD fallback mirrors `RemoteFileStats.lsCommand`: GNU
    /// coreutils' `--zero` emits NUL-separated entries so an embedded
    /// newline in a filename can't fragment it; BSD `ls` (a remote macOS
    /// host) has no such mode and falls back to plain newline-delimited
    /// output.
    static func containedListScript(path: String, worktreeRoot: String) -> String {
        let probe = containmentExcludingGitProbeCommand(path: path, worktreeRoot: worktreeRoot)
        let probeWithoutFinalExit = probe.hasSuffix("exit 0")
            ? String(probe.dropLast("exit 0".count))
            : probe
        return probeWithoutFinalExit + """
        [ -d "$full_phys" ] || exit 9; \
        ls -1Ap --zero -- "$full_phys" 2>/dev/null || ls -1Ap -- "$full_phys"
        """
    }

    /// Runs `containedListScript` over one `RemoteExec.run` round trip.
    static func containedList(host: String, path: String, worktreeRoot: String) async throws -> ContainedListOutcome {
        let target = try lexicallyResolveInsideWorktree(path: path, worktreeRoot: worktreeRoot)
        let result = try await RemoteExec.run(
            host: host, cwd: nil,
            command: containedListScript(path: target, worktreeRoot: worktreeRoot))
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        switch result.exitCode {
        case 0:
            return .ok(entries: RemoteFileStats.parseLsEntries(result.stdout))
        case 6, 7:
            return .outsideWorktree
        case 9:
            return .notADirectory
        default:
            return .unreadable
        }
    }
}

/// Remote ACP file serving uses lexical containment first, then a remote
/// physical-parent containment probe before touching the file.
struct ACPRemoteFileServer {
    enum ServerError: Error, LocalizedError {
        case outsideWorktree(String)
        case unreadable(String)
        case leaseLost

        var errorDescription: String? {
            switch self {
            case let .outsideWorktree(path): "Path is outside the worktree: \(path)"
            case let .unreadable(detail): "Could not read remote file: \(detail)"
            case .leaseLost: "Session lease was lost before the remote write."
            }
        }
    }

    let host: String
    let worktreeRoot: String

    func lexicallyResolveInsideWorktree(path: String) throws -> String {
        do {
            return try RemotePathContainment.lexicallyResolveInsideWorktree(path: path, worktreeRoot: worktreeRoot)
        } catch {
            throw ServerError.outsideWorktree(path)
        }
    }

    func read(path: String, liveBuffer: String?) async throws -> String {
        if let liveBuffer { return liveBuffer }
        let target = try lexicallyResolveInsideWorktree(path: path)
        try await verifyRemoteContainment(path: target)
        switch try await RemoteFileAccess.read(host: host, path: target) {
        case let .file(data, _):
            guard let text = String(data: data, encoding: .utf8) else { throw ServerError.unreadable("not valid UTF-8") }
            return text
        case .missing: throw ServerError.unreadable("no such file")
        case .directory: throw ServerError.unreadable("path is a directory")
        case .symlink: throw ServerError.unreadable("path is a symbolic link")
        case let .unreadable(detail): throw ServerError.unreadable(detail)
        }
    }

    func write(
        path: String,
        content: String,
        beforeRemoteWrite: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws -> ACPFileWriter.Result {
        let target = try lexicallyResolveInsideWorktree(path: path)
        try await verifyRemoteContainment(path: target)
        let previous = try? await read(path: target, liveBuffer: nil)
        let mkdir = try await RemoteExec.run(host: host, cwd: nil, command: RemoteFileOps.mkdirCommand(parentOf: target))
        if RemoteExec.isConnectionFailure(exitCode: mkdir.exitCode) {
            throw RemoteFileAccessError.connectionFailed(mkdir.stderr)
        }
        guard mkdir.exitCode == 0 else {
            throw ServerError.unreadable(mkdir.stderr)
        }
        try await beforeRemoteWrite?()
        _ = try await RemoteFileAccess.write(host: host, path: target, content: content)
        return ACPFileWriter.makeResult(oldText: previous, newText: content, path: target)
    }

    func containmentProbeCommand(path: String) -> String {
        RemotePathContainment.containmentProbeCommand(path: path, worktreeRoot: worktreeRoot)
    }

    func verifyRemoteContainment(path: String) async throws {
        do {
            try await RemotePathContainment.verifyRemoteContainment(host: host, path: path, worktreeRoot: worktreeRoot)
        } catch RemotePathContainment.ContainmentError.outsideWorktree(_) {
            throw ServerError.outsideWorktree(path)
        } catch {
            throw error
        }
    }
}
