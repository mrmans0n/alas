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

        let lfsOverride = [
            "-c", "filter.lfs.process=",
            "-c", "filter.lfs.smudge=",
            "-c", "filter.lfs.clean=",
            "-c", "filter.lfs.required=false",
            "-c", "core.hooksPath=/dev/null"
        ]
        let fallbackResult = try await Process.git(lfsOverride + fallbackArgs, cwd: repoPath)
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
        let result = try await Process.git(args, cwd: repoPath)
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

    private static func looksLikeMissingLFS(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return (lower.contains("command not found") || lower.contains("not found"))
            && (lower.contains("git-lfs") || lower.contains("filter-process"))
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
        // One rev-list per submodule using set arithmetic — every commit
        // reachable from local branches/reflog/tags that ISN'T reachable
        // from any remote ref. Replaces an earlier O(reflog × remotes)
        // shell loop that timed out on submodules with non-trivial
        // reflogs. Notes/stash are checked separately because they need
        // full `refs/notes` / `refs/stash` paths.
        //
        // Tags get an explicit name+oid comparison via one `ls-remote`
        // call: rev-list reachability misses the cases where a tag with
        // a local-only NAME (or a retargeted/retagged tag) points at a
        // commit that's already in a remote branch — losing that local
        // tag state on a force-remove would surprise the user.
        let localStateScript = """
        if test -n "$(git rev-list --max-count=1 --branches --reflog --not --remotes 2>/dev/null)"; then
          echo local-branch-or-reflog
          exit 0
        fi
        extra=$(git for-each-ref --format='%(refname)' refs/notes refs/stash)
        if test -n "$extra" && test -n "$(git rev-list --max-count=1 $extra --not --remotes 2>/dev/null)"; then
          echo notes-stash
          exit 0
        fi
        remote_tags=$(git ls-remote --tags --refs origin 2>/dev/null | awk '{print $2"="$1}')
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
