import Foundation

/// Base-relative views used by the remote changes surface. Unlike the desktop
/// Changes panel (working tree vs index/HEAD), these compare the whole
/// worktree — commits plus uncommitted work — against the comparison ref, so
/// the remote client shows everything an agent did on this branch.
extension GitService {
    /// Changed files between `ref` and the working tree, plus untracked files.
    /// A nil `ref` (unborn branch, no resolvable base) falls back to `status`.
    func changedFilesAgainstRef(worktreePath: URL, ref: String?) async throws -> [ChangedFile] {
        guard let ref, !ref.isEmpty else {
            return Self.collapsingStagedAndUnstagedEntries(try await status(worktreePath: worktreePath))
        }

        // `-c core.quotePath=false` plus `-z` keep non-ASCII (and
        // tab/newline-containing) filenames intact instead of git's default
        // octal-escaped, quoted rendering — mirrors `stagedChangedFiles`,
        // whose NUL-token parsers this reuses.
        let numstat = try await Process.git(
            ["-c", "core.quotePath=false", "diff", "--numstat", "-z", "-M", "-C", ref, "--"], cwd: worktreePath)
        // Unlike the guard at the top of this function, `ref` here is
        // already resolved and non-empty — this is NOT the "no base to
        // compare against" case, so a failure (a dropped SSH connection, a
        // corrupt repository) must propagate rather than fall back to
        // `status()`: that fallback silently reports only current
        // index/worktree changes, omitting every committed change relative
        // to `ref`, as if the request had genuinely been base-less.
        guard numstat.exitCode == 0 else {
            throw ProcessError.nonZeroExit(numstat.exitCode, numstat.stderr)
        }
        let counts = GitService.parseNumstatZOutput(numstat.stdout)

        let nameStatus = try await Process.git(
            ["-c", "core.quotePath=false", "diff", "--name-status", "-z", "-M", "-C", ref, "--"], cwd: worktreePath)
        // A dropped SSH connection (or any other fatal exit) between the
        // numstat call above and this one must propagate, not be parsed as
        // an empty (and so misleadingly valid) name-status list: that would
        // report only untracked files, or nothing at all, as the whole set
        // of base-relative changes.
        guard nameStatus.exitCode == 0 else {
            throw ProcessError.nonZeroExit(nameStatus.exitCode, nameStatus.stderr)
        }
        let statusEntries = try await status(worktreePath: worktreePath)
        let conflicts = Dictionary(
            statusEntries.compactMap { entry in entry.conflict.map { (entry.path, $0) } },
            uniquingKeysWith: { first, _ in first })

        var files: [ChangedFile] = []
        var seen = Set<String>()
        let parsedNameStatus = GitService.parseNameStatusZOutput(nameStatus.stdout)
        for path in parsedNameStatus.ordered {
            guard seen.insert(path).inserted else { continue }
            let letter = parsedNameStatus.status[path] ?? "M"
            let renameFrom = parsedNameStatus.original[path]
            let add = counts.add[path] ?? 0
            let del = counts.del[path] ?? 0
            files.append(ChangedFile(
                path: path,
                status: letter,
                stage: .unstaged,   // not meaningful for a base-relative view
                add: add,
                del: del,
                renameFrom: renameFrom,
                conflict: conflicts[path]))
        }

        let untracked = try await Process.git(
            ["ls-files", "--others", "--exclude-standard", "-z"], cwd: worktreePath)
        guard untracked.exitCode == 0 else {
            throw ProcessError.nonZeroExit(untracked.exitCode, untracked.stderr)
        }
        let untrackedPaths = untracked.stdout.components(separatedBy: "\0")
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        // `addedLineCount` shells out to `Data(contentsOf:)` against a LOCAL
        // URL, which silently reads nothing (0 lines) for a remote worktree
        // path — batch a single remote round-trip instead, mirroring
        // `status(worktreePath:)`'s identical remote/local split for
        // untracked line counts.
        let remoteCounts: [String: Int]
        if worktreePath.isRemoteAlasPath, let host = RemoteHostRegistry.shared.host(forPath: worktreePath.path) {
            remoteCounts = try await RemoteFileStats.lineCounts(host: host, cwd: worktreePath.path, paths: untrackedPaths)
        } else {
            remoteCounts = [:]
        }

        for path in untrackedPaths {
            let add = worktreePath.isRemoteAlasPath
                ? (remoteCounts[path] ?? 0)
                : Self.addedLineCount(worktreePath: worktreePath, path: path)
            files.append(ChangedFile(
                path: path,
                status: "A",
                stage: .unstaged,
                add: add,
                del: 0,
                renameFrom: nil,
                conflict: nil))
        }

        return files.sorted { $0.path < $1.path }
    }

    /// Badge-only variant of `changedFilesAgainstRef`: just `path` + status
    /// letter (+ rename source), skipping the `numstat` call AND
    /// per-untracked-file line counting entirely.
    ///
    /// `remoteFileTree` only needs a badge letter per path (the Files tab's
    /// `RemoteFileNode` has no add/del or conflict fields at all) — unlike
    /// `remoteChangeList`, which needs real metrics to display. Computing
    /// full `changedFilesAgainstRef` metrics for every `listFiles` request
    /// (the root listing AND every directory a client expands) redid that
    /// work from scratch each time: a local untracked file gets read whole
    /// via `addedLineCount`, and a remote one costs an SSH round trip
    /// through `RemoteFileStats.lineCounts` — for a worktree with many or
    /// large untracked files, that's substantial, repeated I/O just to
    /// answer "does this path have a badge, and which one".
    func changedFileBadges(worktreePath: URL, ref: String?) async throws -> [ChangedFile] {
        guard let ref, !ref.isEmpty else {
            // NOT `status(worktreePath:)` — that runs the exact same
            // numstat-plus-untracked-line-counting work this function
            // exists to avoid, just working-tree/index-relative instead of
            // ref-relative. An unborn branch (no resolvable comparison ref)
            // would otherwise still pay that full cost on every
            // `listFiles` request. `StatusParser.parse` alone gives
            // path/status/stage/renameFrom/conflict with add/del left at
            // their 0 default — exactly what a badge needs.
            let s = try await Process.git(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"], cwd: worktreePath)
            guard s.exitCode == 0 else {
                throw ProcessError.nonZeroExit(s.exitCode, s.stderr)
            }
            let entries = try StatusParser.parse(s.stdout)
            return Self.collapsingStagedAndUnstagedEntries(entries)
        }

        let nameStatus = try await Process.git(
            ["-c", "core.quotePath=false", "diff", "--name-status", "-z", "-M", "-C", ref, "--"], cwd: worktreePath)
        guard nameStatus.exitCode == 0 else {
            throw ProcessError.nonZeroExit(nameStatus.exitCode, nameStatus.stderr)
        }

        var files: [ChangedFile] = []
        var seen = Set<String>()
        let parsedNameStatus = GitService.parseNameStatusZOutput(nameStatus.stdout)
        for path in parsedNameStatus.ordered {
            guard seen.insert(path).inserted else { continue }
            let letter = parsedNameStatus.status[path] ?? "M"
            files.append(ChangedFile(
                path: path,
                status: letter,
                stage: .unstaged,
                add: 0,
                del: 0,
                renameFrom: parsedNameStatus.original[path],
                conflict: nil))
        }

        let untracked = try await Process.git(
            ["ls-files", "--others", "--exclude-standard", "-z"], cwd: worktreePath)
        guard untracked.exitCode == 0 else {
            throw ProcessError.nonZeroExit(untracked.exitCode, untracked.stderr)
        }
        let untrackedPaths = untracked.stdout.components(separatedBy: "\0")
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        for path in untrackedPaths {
            files.append(ChangedFile(
                path: path, status: "A", stage: .unstaged, add: 0, del: 0,
                renameFrom: nil, conflict: nil))
        }

        return files.sorted { $0.path < $1.path }
    }

    /// Diff of one file between `ref` and the working tree. Untracked files
    /// diff against /dev/null so they render as a single all-add hunk. A nil
    /// `ref` falls back to the working-tree diff.
    ///
    /// A file renamed since `ref` did not exist at `ref` under its CURRENT
    /// path (it existed under its OLD path), so the plain `cat-file -e`
    /// existence check below would otherwise treat it as untracked/new and
    /// diff the whole current content against `/dev/null` instead of
    /// showing the rename's actual edits. `renameSource` catches that case
    /// first by consulting the unrestricted (no-pathspec) rename-aware
    /// name-status diff — pathspec-restricting `git diff -M -C ref --
    /// <file>` does NOT detect the rename, because git's pathspec filtering
    /// happens before rename pairing, so it never sees the old path to pair
    /// against.
    func diff(
        worktreePath: URL, againstRef ref: String?, file: String,
        maxOutputBytes: Int = RemoteWorktreeFileAccess.maxDiffSubprocessBytes
    ) async throws -> ParsedDiff {
        guard let ref, !ref.isEmpty else {
            // `diff(worktreePath:file:)`'s default (`staged: false`) is a
            // working-tree-vs-INDEX diff, which omits changes that are
            // staged but not yet committed — so a staged-only file would
            // show up in `changedFilesAgainstRef`'s own nil-ref fallback
            // (`status(worktreePath:)`, which includes staged entries) but
            // open to an empty diff here. `diffAgainstHEAD` compares the
            // working tree against HEAD (or /dev/null on an unborn branch),
            // which captures staged AND unstaged changes together, matching
            // what `status` already reflects in the change list.
            return try await diffAgainstHEAD(
                worktreePath: worktreePath, file: file,
                maxOutputBytes: maxOutputBytes)
        }

        if let originalPath = try await renameSource(worktreePath: worktreePath, ref: ref, file: file) {
            // `--literal-pathspecs` (a global flag, so it must precede the
            // subcommand) stops `file`/`originalPath` from being interpreted
            // as glob pathspecs — a tracked name containing `*`/`?`/`[...]`
            // would otherwise also match unrelated files. `-c
            // core.quotePath=false` keeps a non-ASCII destination name
            // unquoted in the `diff --git a/<old> b/<new>` header, which
            // `sliceDiffForFile` below matches on as a raw string.
            let result = try await Process.gitCapped(
                ["--literal-pathspecs", "-c", "core.quotePath=false",
                 "diff", "--no-color", "-M", "-C", ref, "--", file, originalPath], cwd: worktreePath,
                maxOutputBytes: maxOutputBytes)
            // A fatal exit (>= 2, e.g. a dropped SSH connection) must propagate
            // rather than fall through as a successful, blank diff — see the
            // matching comment on the tracked-file diff below. A size-capped
            // exit is NOT fatal — `exitCode` is meaningless there — so it
            // takes the same path as an ordinary successful diff.
            guard result.stdoutTruncated || result.exitCode <= 1 else {
                throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
            }
            let sliced = Self.sliceDiffForFile(result.stdout, file: file)
            // This is a two-path diff (`file` plus `originalPath`), and git
            // emits sections in the order the two paths sort — when
            // `originalPath` sorts first and its OWN section alone exceeds
            // `maxOutputBytes`, `gitCapped` can terminate before `file`'s
            // section ever appears. `sliceDiffForFile` then finds no
            // matching section and returns "", indistinguishable from a
            // genuinely empty diff. There's no way to tell those apart from
            // the captured bytes alone, so — only when the process was
            // ACTUALLY size-capped — treat an empty slice as a failure
            // rather than silently showing "no changes" for a file that
            // definitely has some.
            guard !(result.stdoutTruncated && sliced.isEmpty) else {
                throw ProcessError.nonZeroExit(
                    result.exitCode,
                    "diff for \(file) exceeded the size cap before its section was captured")
            }
            return DiffParser.parse(sliced)
        }

        // Check if file exists at ref (not just in current index) to handle deleted files correctly.
        let existsAtRef = try await Process.git(
            ["cat-file", "-e", "\(ref):\(file)"], cwd: worktreePath)
        if existsAtRef.exitCode != 0 {
            // `cat-file -e` exits with the SAME code (128, empirically, on
            // git 2.50) both when the object genuinely doesn't exist at
            // `ref` AND for unrelated fatal errors — an invalid ref name, a
            // corrupt/inaccessible repository, a dropped SSH connection on a
            // remote worktree. The exit code alone can't tell these apart;
            // blindly treating every nonzero exit as "new/untracked file"
            // means a real failure silently shows the wrong diff (or, if the
            // fallback below also fails to find a difference, a misleadingly
            // "successful" empty one). Git's own fatal message text is the
            // only distinguishing signal available: a missing object says
            // "does not exist in"; every other failure mode says something
            // else entirely.
            guard Self.isMissingObjectAtRef(existsAtRef) else {
                throw ProcessError.nonZeroExit(existsAtRef.exitCode, existsAtRef.stderr)
            }
            // File doesn't exist at ref (untracked/new file), so diff against /dev/null.
            // `--no-index` compares the two given paths directly rather than
            // through pathspec matching, so `--literal-pathspecs` is a no-op
            // here — kept for consistency with the other client-path calls
            // in this function.
            let result = try await Process.gitCapped(
                ["--literal-pathspecs", "diff", "--no-color", "--no-index", "--", "/dev/null", file], cwd: worktreePath,
                maxOutputBytes: maxOutputBytes)
            // `--no-index` exits 1 when there ARE differences, which is the
            // normal case here; only >= 2 is a real failure that must
            // propagate — see the matching comment on the tracked-file diff
            // below. A size-capped exit is NOT fatal.
            guard result.stdoutTruncated || result.exitCode <= 1 else {
                throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
            }
            return DiffParser.parse(result.stdout)
        }

        // File exists at ref (tracked or previously committed), so diff ref to current state.
        // `--literal-pathspecs` stops `file` from being interpreted as a
        // glob pathspec (see comment above).
        let result = try await Process.gitCapped(
            ["--literal-pathspecs", "diff", "--no-color", "-M", "-C", ref, "--", file], cwd: worktreePath,
            maxOutputBytes: maxOutputBytes)
        // A fatal exit here (e.g. an SSH connection dropping after the
        // preceding probes succeeded) must propagate rather than turn into a
        // successful, blank diff: `remoteFileDiff` maps a thrown error to
        // `.gitFailed`, but silently returning empty hunks would instead
        // report success with nothing to show. A size-capped exit is NOT
        // fatal — `exitCode` is meaningless there — so it takes the same
        // path as an ordinary successful diff, letting `DiffParser` and
        // `truncateHunks` handle the (possibly incomplete at the very end)
        // captured prefix exactly like any other oversized diff.
        guard result.stdoutTruncated || result.exitCode <= 1 else {
            throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
        }
        return DiffParser.parse(result.stdout)
    }

    /// Looks up the source path of a rename OR copy that landed `file` at
    /// its current path since `ref`, or nil when `file` is neither (it's
    /// untracked, unchanged, or was modified/deleted/added without a
    /// rename/copy). Scans the UNRESTRICTED rename-aware name-status diff
    /// (no pathspec) rather than one scoped to `file`, since pathspec
    /// restriction happens before rename/copy pairing in git and would hide
    /// the old path entirely.
    ///
    /// With `-C` enabled, git emits `"C<score>"` (not `"R<score>"`) when
    /// `file` was copied from a source path that STILL EXISTS — distinct
    /// from a pure rename, where the source is gone.
    /// `parseNameStatusZOutput` already records the source path for `C`
    /// entries too; without accepting `"C"` here, a copied file's diff fell
    /// through to being treated as brand new (all-add against
    /// `/dev/null`) instead of a proper diff against its copy source.
    private func renameSource(worktreePath: URL, ref: String, file: String) async throws -> String? {
        let result = try await Process.git(
            ["-c", "core.quotePath=false", "diff", "--name-status", "-z", "-M", "-C", ref], cwd: worktreePath)
        guard result.exitCode == 0 else { return nil }
        let parsed = GitService.parseNameStatusZOutput(result.stdout)
        guard let status = parsed.status[file], status.hasPrefix("R") || status.hasPrefix("C") else { return nil }
        return parsed.original[file]
    }

    /// Sniffs whether the blob at `ref:file` looks binary, for files that no
    /// longer exist in the working tree (so an on-disk sniff can't tell).
    /// Returns nil when `file` doesn't exist at `ref` either — nothing to
    /// sniff, so the caller should fall back to its prior on-disk verdict.
    ///
    /// Reads only the first 8 KB of the blob via `Process.gitDataPrefix`
    /// (the same prefix `looksBinary` inspects) rather than buffering the
    /// entire historical blob — a large deleted file no longer forces a
    /// full `git show` read (unnecessary network transfer too, over SSH).
    func looksBinaryAtRef(worktreePath: URL, ref: String, file: String) async throws -> Bool? {
        let existsAtRef = try await Process.git(
            ["cat-file", "-e", "\(ref):\(file)"], cwd: worktreePath)
        guard existsAtRef.exitCode == 0 else { return nil }
        let prefix = try await Process.gitDataPrefix(
            ["show", "\(ref):\(file)"], cwd: worktreePath, maxBytes: 8192)
        return Self.looksBinary(prefix)
    }

    func looksBinaryAtIndex(worktreePath: URL, file: String) async throws -> Bool? {
        let existsAtIndex = try await Process.git(
            ["cat-file", "-e", ":\(file)"], cwd: worktreePath)
        guard existsAtIndex.exitCode == 0 else { return nil }
        let prefix = try await Process.gitDataPrefix(
            ["show", ":\(file)"], cwd: worktreePath, maxBytes: 8192)
        return Self.looksBinary(prefix)
    }

    /// `git cat-file -e <ref>:<file>` exits with the SAME code (128,
    /// empirically, on git 2.50) both when the object genuinely doesn't
    /// exist at `ref` AND for unrelated fatal errors (an invalid ref name,
    /// a corrupt/inaccessible repository, a dropped SSH connection). The
    /// exit code alone can't distinguish these; git's own fatal message
    /// text is the only signal available. Empirically, a missing object
    /// says one of two things depending on whether the path also exists on
    /// disk right now:
    ///   - "path 'X' does not exist in 'REF'" (path absent everywhere), or
    ///   - "path 'X' exists on disk, but not in 'REF'" (the common
    ///     untracked-file shape: never committed, so absent from every ref).
    /// Every OTHER failure says something else entirely (invalid ref name:
    /// "invalid object name"; run outside a repository: "not a git
    /// repository").
    private static func isMissingObjectAtRef(_ result: ProcessResult) -> Bool {
        result.stderr.contains("does not exist in") || result.stderr.contains("exists on disk, but not in")
    }

    /// Line count for an untracked file, or 0 when it is binary or unreadable.
    /// `internal` (not `private`) so `GitService.status(worktreePath:)`
    /// (a different file/extension of the same type) can share this exact
    /// counting logic instead of duplicating a slightly different one — see
    /// the comment at its call site there for why that duplication used to
    /// matter (a trailing-newline off-by-one).
    static func addedLineCount(worktreePath: URL, path: String) -> Int {
        let url = worktreePath.appendingPathComponent(path)
        // Git's object model never follows a symlink to compute its blob:
        // the blob IS the link's target path string. Handled BEFORE the
        // regular-file check below (which DOES follow the link via
        // `.isRegularFileKey`) — otherwise an untracked symlink either
        // reports 0 (a broken link, or one whose target isn't itself a
        // regular file) or the TARGET file's own line count (a symlink to a
        // huge file wrongly inflating this to thousands), neither of which
        // matches what `git diff`/`numstat` would show for the same path.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                return 0
            }
            return Self.lineCount(of: target)
        }
        // `Data(contentsOf:)` below performs a plain blocking open+read: on
        // a FIFO with no writer, that blocks indefinitely. Since this runs
        // synchronously on whatever actor called it (ultimately
        // `changedFilesAgainstRef`, reachable from the `@MainActor`
        // `remoteChangeList`), a worktree containing an untracked FIFO
        // would freeze the whole app, not just this one request. Reject
        // anything that isn't a regular file before ever opening it.
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return 0
        }
        guard let data = try? Data(contentsOf: url), !looksBinary(data),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        return Self.lineCount(of: text)
    }

    private static func lineCount(of text: String) -> Int {
        if text.isEmpty { return 0 }
        return text.hasSuffix("\n")
            ? text.split(separator: "\n", omittingEmptySubsequences: false).count - 1
            : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// `status()` (used verbatim by the desktop Changes panel, which shows
    /// separate Staged/Unstaged sections) returns TWO entries for a path
    /// that's both staged and further modified in the working tree — one
    /// per stage (e.g. an "AM" file), each with its OWN correct metric
    /// (`status()` computes a separate index-only numstat for the staged
    /// side and a whole-working-tree one for the unstaged side). This
    /// function's ref-resolved path above already hardcodes `stage:
    /// .unstaged` for every entry, since stage isn't meaningful when
    /// comparing against a base commit instead of the index; the nil-ref
    /// fallback (the only caller of this function) needs the same
    /// collapsing, or the remote Changes list renders a duplicate row for
    /// the path.
    ///
    /// The merged row takes its IDENTITY (status/renameFrom/conflict) from
    /// the staged side — on the unborn branch this fallback is reached
    /// for, the index side of such a pair is always "added" (there is no
    /// HEAD for it to be anything else relative to), so the unstaged
    /// sibling would misleadingly read "M" as if a base version existed —
    /// but its METRICS from the unstaged side, which reflect the WHOLE
    /// working tree, matching what `remoteFileDiff` actually renders for
    /// this single-row-per-path list. Using the staged side's own
    /// (correctly index-only) metrics here instead would undercount
    /// relative to that diff view for a file staged and then further
    /// edited.
    static func collapsingStagedAndUnstagedEntries(_ files: [ChangedFile]) -> [ChangedFile] {
        var staged: [String: ChangedFile] = [:]
        var unstaged: [String: ChangedFile] = [:]
        var order: [String] = []
        for file in files {
            if staged[file.path] == nil, unstaged[file.path] == nil {
                order.append(file.path)
            }
            if file.stage == .staged {
                staged[file.path] = file
            } else {
                unstaged[file.path] = file
            }
        }
        return order.map { path in
            switch (staged[path], unstaged[path]) {
            case (let s?, let u?):
                return ChangedFile(
                    path: path, status: s.status, stage: s.stage,
                    add: u.add, del: u.del, renameFrom: s.renameFrom, conflict: s.conflict)
            case (let s?, nil):
                return s
            case (nil, let u?):
                return u
            case (nil, nil):
                preconditionFailure("path \(path) tracked in `order` without a staged or unstaged entry")
            }
        }
    }
}
