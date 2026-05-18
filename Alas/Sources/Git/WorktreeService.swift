import CryptoKit
import Foundation

struct WorktreeService {
    enum WorktreeError: Error, LocalizedError {
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case let .gitFailed(stderr):
                let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return msg.isEmpty ? "Git worktree operation failed." : msg
            }
        }
    }

    /// Parse `git worktree list --porcelain` into Worktree records.
    func list(repoPath: URL, projectId: String) async throws -> [Worktree] {
        let result = try await Process.git(["worktree", "list", "--porcelain"], cwd: repoPath)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return Self.parsePorcelain(result.stdout, projectId: projectId)
    }

    static func parsePorcelain(_ out: String, projectId: String) -> [Worktree] {
        var result: [Worktree] = []
        var currentPath: URL?
        var currentBranch: String?

        func flush() {
            if let path = currentPath {
                let branch = currentBranch ?? "(detached)"
                result.append(Worktree(
                    id: Worktree.makeId(path: path),
                    projectId: projectId,
                    name: branch,
                    branch: branch,
                    path: path,
                    status: .clean,
                    lastActivity: (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date) ?? Date()
                ))
            }
            currentPath = nil
            currentBranch = nil
        }

        for line in out.split(separator: "\n") {
            if line.hasPrefix("worktree ") {
                flush()
                currentPath = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                let raw = String(line.dropFirst("branch ".count))
                // refs/heads/foo → foo
                currentBranch = raw.replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        flush()
        return result
    }

    func add(
        repoPath: URL,
        base: String,
        branch: String,
        destination: URL,
        projectId: String
    ) async throws -> Worktree {
        switch GitNameValidator.validateBranchName(branch) {
        case .valid:
            break
        case .invalid(let message):
            throw WorktreeError.gitFailed("Invalid branch name: \(message)")
        }
        let refCheck = try await Process.git(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            cwd: repoPath
        )
        let branchExists = refCheck.exitCode == 0

        let args: [String]
        if branchExists {
            args = ["worktree", "add", destination.path, branch]
        } else {
            args = ["worktree", "add", destination.path, "-b", branch, base]
        }

        let result = try await Process.git(args, cwd: repoPath)
        if result.exitCode == 0 {
            return makeWorktree(destination: destination, branch: branch, projectId: projectId)
        }

        guard Self.looksLikeMissingLFS(result.stderr) else {
            throw WorktreeError.gitFailed(result.stderr)
        }

        // The worktree may already exist if the failure came from a
        // post-checkout hook rather than the checkout itself (e.g. LFS hook
        // detecting missing git-lfs after files are already checked out).
        if let existing = try await existingWorktree(
            repoPath: repoPath, destination: destination, projectId: projectId
        ) {
            return existing
        }

        let recheck = try await Process.git(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            cwd: repoPath
        )
        let branchNowExists = recheck.exitCode == 0

        let fallbackArgs: [String]
        if branchNowExists {
            fallbackArgs = ["worktree", "add", destination.path, branch]
        } else {
            fallbackArgs = ["worktree", "add", destination.path, "-b", branch, base]
        }

        let fallbackResult = try await Process.git(
            Self.lfsFilterOverride + ["-c", "core.hooksPath=/dev/null"] + fallbackArgs,
            cwd: repoPath
        )
        guard fallbackResult.exitCode == 0 else { throw WorktreeError.gitFailed(fallbackResult.stderr) }
        return makeWorktree(destination: destination, branch: branch, projectId: projectId)
    }

    /// Remove a worktree. Pass the full `Worktree` (not just a path) so we can
    /// reliably resolve the branch name when `deleteBranchIfMerged` is true —
    /// path basenames diverge from branch names whenever the path template
    /// substitutes `/` (e.g. branch `feat/x` lives at dir basename `feat-x`).
    /// `force` adds `--force`, required when the worktree has uncommitted
    /// changes or untracked files.
    func remove(
        repoPath: URL,
        worktree: Worktree,
        deleteBranchIfMerged: Bool,
        force: Bool = false
    ) async throws {
        var args = ["worktree", "remove", worktree.path.path]
        if force { args.append("--force") }
        var result = try await Process.git(args, cwd: repoPath)
        if result.exitCode != 0 {
            if Self.looksLikeMissingLFS(result.stderr) {
                result = try await Process.git(Self.lfsFilterOverride + args, cwd: repoPath)
            }
            if !force,
               result.exitCode != 0,
               Self.looksLikeDirtyWorktreeRemoveError(result.stderr),
               try await canForceRemoveAfterMissingLFS(worktree.path) {
                result = try await Process.git(
                    Self.lfsFilterOverride + ["worktree", "remove", worktree.path.path, "--force"],
                    cwd: repoPath
                )
            }
        }
        if result.exitCode != 0 {
            // Treat any thrown helper error (timeout, malformed submodule,
            // etc.) as "couldn't verify clean" so we propagate the original
            // stderr from `git worktree remove` instead of surfacing the
            // helper's internal failure to the user. Sequential bindings
            // because `&&` autoclosures don't propagate `async`.
            let okToForce: Bool
            do {
                let workClean = try await isWorktreeClean(worktree.path)
                let subsClean = workClean
                    ? try await areInitializedSubmodulesClean(worktree.path)
                    : false
                let subsNoLocal = subsClean
                    ? try await initializedSubmodulesHaveNoLocalState(worktree.path)
                    : false
                okToForce = subsNoLocal
            } catch {
                okToForce = false
            }
            guard !force,
                  Self.looksLikeSubmoduleWorktreeRemoveError(result.stderr),
                  okToForce
            else {
                throw WorktreeError.gitFailed(result.stderr)
            }

            let forceResult = try await Process.git(
                ["worktree", "remove", worktree.path.path, "--force"],
                cwd: repoPath
            )
            guard forceResult.exitCode == 0 else { throw WorktreeError.gitFailed(forceResult.stderr) }
        }
        if deleteBranchIfMerged && worktree.branch != "(detached)" {
            // Best-effort delete. -d only succeeds if merged; ignore failures.
            _ = try? await Process.git(["branch", "-d", worktree.branch], cwd: repoPath)
        }
    }

    func prune(repoPath: URL) async throws {
        let result = try await Process.git(["worktree", "prune"], cwd: repoPath)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
    }

    // MARK: - Helpers

    private static let lfsFilterOverride = [
        "-c", "filter.lfs.process=",
        "-c", "filter.lfs.smudge=",
        "-c", "filter.lfs.clean=",
        "-c", "filter.lfs.required=false"
    ]

    private static func looksLikeMissingLFS(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return (lower.contains("command not found") || lower.contains("not found"))
            && (lower.contains("git-lfs") || lower.contains("filter-process"))
    }

    private static func looksLikeDirtyWorktreeRemoveError(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("contains modified or untracked files")
            || lower.contains("is dirty")
            || lower.contains("dirty worktree")
    }

    private static func looksLikeSubmoduleWorktreeRemoveError(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("working trees containing submodules")
            && lower.contains("cannot be moved or removed")
    }

    private func isWorktreeClean(_ path: URL) async throws -> Bool {
        let result = try await Process.git(
            ["status", "--porcelain", "--ignore-submodules=none", "--untracked-files=all"],
            cwd: path
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func areInitializedSubmodulesClean(_ path: URL) async throws -> Bool {
        let result = try await Process.git(
            [
                "submodule", "foreach", "--quiet", "--recursive",
                "git status --porcelain --ignore-submodules=none --untracked-files=all"
            ],
            cwd: path
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func initializedSubmodulesHaveNoLocalState(_ path: URL) async throws -> Bool {
        // Reachability set arithmetic for reflog and notes/stash (the
        // perf-critical fix — replaces an O(reflog × remotes) shell loop
        // that timed out on submodules with non-trivial reflogs).
        //
        // Branches and tags get explicit name+oid comparisons via single
        // `ls-remote` calls: rev-list reachability misses the case where
        // a local ref's NAME or annotation differs from the remote while
        // its target commit is already reachable from a remote branch
        // (`my-fix` at origin/main; a retargeted/retagged release tag).
        // Losing that local ref on a force-remove would surprise the user.
        let localStateScript = """
        if test -n "$(git rev-list --max-count=1 --reflog --not --remotes 2>/dev/null)"; then
          echo local-reflog
          exit 0
        fi
        extra=$(git for-each-ref --format='%(refname)' refs/notes refs/stash)
        if test -n "$extra" && test -n "$(git rev-list --max-count=1 $extra --not --remotes 2>/dev/null)"; then
          echo notes-stash
          exit 0
        fi
        # Branches: compare against local remote-tracking refs. No
        # network: refs/remotes/<remote>/<branch> already encodes what
        # the user has fetched. Translate to refs/heads/<branch>=<oid>
        # so a direct join against for-each-ref refs/heads is exact.
        remote_heads=$(git for-each-ref --format='%(refname)=%(objectname)' refs/remotes 2>/dev/null \\
          | awk '/^refs\\/remotes\\/[^\\/]+\\/HEAD=/ { next }
                 { sub(/^refs\\/remotes\\/[^\\/]+\\//, "refs/heads/", $0); print }')
        branch_diff=$(git for-each-ref --format='%(refname)=%(objectname)' refs/heads \\
          | awk -v rt="$remote_heads" '
              BEGIN { n = split(rt, arr, "\\n"); for (i = 1; i <= n; i++) seen[arr[i]] = 1 }
              !seen[$0] { print; exit }
          ')
        if test -n "$branch_diff"; then
          echo "branch-mismatch $branch_diff"
          exit 0
        fi
        # Tags: one network call per submodule. `protocol.file.allow=always`
        # lets the file-protocol test fixtures work; harmless on real
        # remotes. If `ls-remote` fails (offline, dead remote, etc.) any
        # local tag is treated as a mismatch — the safer default: don't
        # force-remove when we can't verify the tag state.
        remote_tags=$(git -c protocol.file.allow=always ls-remote --tags --refs origin 2>/dev/null \\
          | awk '{print $2"="$1}')
        tag_diff=$(git for-each-ref --format='%(refname)=%(objectname)' refs/tags \\
          | awk -v rt="$remote_tags" '
              BEGIN { n = split(rt, arr, "\\n"); for (i = 1; i <= n; i++) seen[arr[i]] = 1 }
              !seen[$0] { print; exit }
          ')
        if test -n "$tag_diff"; then
          echo "tag-mismatch $tag_diff"
        fi
        """
        let result = try await Process.git(
            ["submodule", "foreach", "--quiet", "--recursive", localStateScript],
            cwd: path,
            timeout: 120
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canForceRemoveAfterMissingLFS(_ path: URL) async throws -> Bool {
        guard try await isWorktreeCleanAllowingSmudgedLFS(path) else { return false }
        let subsClean = try await areInitializedSubmodulesClean(path)
        guard subsClean else { return false }
        return try await initializedSubmodulesHaveNoLocalState(path)
    }

    private func isWorktreeCleanAllowingSmudgedLFS(_ path: URL) async throws -> Bool {
        let result = try await Process.git(
            Self.lfsFilterOverride + [
                "status", "--porcelain=v2", "-z",
                "--ignore-submodules=none", "--untracked-files=all"
            ],
            cwd: path
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }

        let records = result.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true)
        for record in records {
            if record.hasPrefix("? ") { return false }
            guard record.hasPrefix("1 ") else { return false }

            let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { return false }
            let xy = fields[1]
            guard xy.count == 2,
                  xy.first == ".",
                  xy.last == "M",
                  fields[4] == fields[5]
            else { return false }

            let relativePath = String(fields[8])
            guard try await isCleanLFSFile(relativePath, in: path) else { return false }
        }
        return true
    }

    private func isCleanLFSFile(_ relativePath: String, in worktreePath: URL) async throws -> Bool {
        guard try await usesLFSFilter(relativePath, in: worktreePath),
              let pointer = try await indexLFSPointer(relativePath, in: worktreePath)
        else { return false }

        let fileURL = worktreePath.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        let pointerData = Data(pointer.raw.utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if fileSize == UInt64(pointerData.count),
           let data = try? Data(contentsOf: fileURL),
           data == pointerData {
            return true
        }

        let actual = try sha256AndSize(of: fileURL)
        return actual.oid == pointer.oid && actual.size == pointer.size
    }

    private func usesLFSFilter(_ relativePath: String, in worktreePath: URL) async throws -> Bool {
        let result = try await Process.git(["check-attr", "-z", "filter", "--", relativePath], cwd: worktreePath)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        let parts = result.stdout.split(separator: "\u{0}", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts[2] == "lfs"
    }

    private func indexLFSPointer(_ relativePath: String, in worktreePath: URL) async throws -> LFSPointer? {
        let listed = try await Process.git(["ls-files", "-s", "--", relativePath], cwd: worktreePath)
        guard listed.exitCode == 0 else { throw WorktreeError.gitFailed(listed.stderr) }
        guard let sha = listed.stdout.split(whereSeparator: \.isWhitespace).dropFirst().first else {
            return nil
        }

        let blob = try await Process.git(["cat-file", "-p", String(sha)], cwd: worktreePath)
        guard blob.exitCode == 0 else { throw WorktreeError.gitFailed(blob.stderr) }
        return Self.parseLFSPointer(blob.stdout)
    }

    private func sha256AndSize(of fileURL: URL) throws -> (oid: String, size: UInt64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            size += UInt64(chunk.count)
            hasher.update(data: chunk)
        }
        let oid = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (oid, size)
    }

    private struct LFSPointer {
        let raw: String
        let oid: String
        let size: UInt64
    }

    private static func parseLFSPointer(_ text: String) -> LFSPointer? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "version https://git-lfs.github.com/spec/v1" else { return nil }

        var oid: String?
        var size: UInt64?
        for line in lines {
            if line.hasPrefix("oid sha256:") {
                oid = String(line.dropFirst("oid sha256:".count))
            } else if line.hasPrefix("size ") {
                size = UInt64(line.dropFirst("size ".count))
            }
        }
        guard let oid, oid.count == 64, let size else { return nil }
        return LFSPointer(raw: text, oid: oid, size: size)
    }

    private func existingWorktree(
        repoPath: URL,
        destination: URL,
        projectId: String
    ) async throws -> Worktree? {
        let listed = try await list(repoPath: repoPath, projectId: projectId)
        let normalizedDest = destination.standardizedFileURL.path
        return listed.first { $0.path.standardizedFileURL.path == normalizedDest }
    }

    private func makeWorktree(destination: URL, branch: String, projectId: String) -> Worktree {
        Worktree(
            id: Worktree.makeId(path: destination),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: destination,
            status: .clean,
            lastActivity: Date()
        )
    }
}
