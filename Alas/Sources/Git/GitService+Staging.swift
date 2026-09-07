import Foundation

extension GitService {
    /// Stage a list of paths. Empty paths is a no-op.
    /// `git add --` works for modifications, additions, and deletions in
    /// modern git, so a single call covers all the cases the Changes pane
    /// surfaces.
    func stage(worktreePath: URL, files: [String]) async throws {
        guard !files.isEmpty else { return }
        let result = try await Process.git(["add", "--"] + files, cwd: worktreePath)
        try Self.assertSuccess(result, op: "stage")
    }

    /// Stage every path the caller asks for. Same as `stage` but named to
    /// match the UI affordance ("Stage all") so callers don't have to know
    /// `git add -A` semantics.
    func stageAll(worktreePath: URL, files: [String]) async throws {
        try await stage(worktreePath: worktreePath, files: files)
    }

    /// Unstage a list of paths. Uses `git restore --staged` against HEAD when
    /// one exists; on unborn branches HEAD doesn't resolve and we fall back
    /// to `git reset --` (index vs empty tree).
    func unstage(worktreePath: URL, files: [String]) async throws {
        guard !files.isEmpty else { return }
        let head = try await hasHead(worktreePath: worktreePath)
        let args: [String] = head
            ? ["restore", "--staged", "--"] + files
            : ["reset", "-q", "--"] + files
        let result = try await Process.git(args, cwd: worktreePath)
        try Self.assertSuccess(result, op: "unstage")
    }

    func unstageAll(worktreePath: URL, files: [String]) async throws {
        try await unstage(worktreePath: worktreePath, files: files)
    }

    /// Unstage a single hunk while keeping the working-tree change intact.
    /// Builds a unified-diff patch and pipes it to `git apply --cached --reverse -`.
    /// `--cached` limits the apply to the index only (no worktree touch).
    /// Contrast with `dropHunkFromStagedCommit` in `GitService+CommitEditing.swift`,
    /// which uses `--index` instead: that flag reverts both the index *and* the
    /// worktree, so changes disappear from disk as well as from the staged diff.
    func unstageHunk(worktreePath: URL, path: String, hunk: ParsedDiff.Hunk) async throws {
        let patch = HunkPatchBuilder.patch(file: path, hunk: hunk, tracked: true)
        // --cached touches the index only; --index (used by CommitEditing.dropHunk) also reverts the worktree.
        let result = try await Process.git(["apply", "--cached", "--reverse", "-"], cwd: worktreePath, stdin: patch)
        guard result.exitCode == 0 else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "GitService.unstageHunk",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey:
                    msg.isEmpty ? "git apply failed (exit \(result.exitCode))" : msg]
            )
        }
    }

    /// Create a new commit (or amend HEAD) with the given subject and optional
    /// body. The body is trimmed; an empty body skips the second `-m` so we
    /// don't leave a trailing blank paragraph in the commit message.
    func commit(
        worktreePath: URL,
        subject: String,
        body: String,
        amend: Bool
    ) async throws -> String {
        var args: [String] = ["commit"]
        if amend { args.append("--amend") }
        args.append("-m")
        args.append(subject)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            args.append("-m")
            args.append(trimmedBody)
        }
        let result = try await Process.git(args, cwd: worktreePath)
        try Self.assertSuccess(result, op: amend ? "amend" : "commit")
        let shaResult = try await Process.git(["rev-parse", "HEAD"], cwd: worktreePath)
        guard shaResult.exitCode == 0 else {
            throw NSError(
                domain: "GitService.commit",
                code: Int(shaResult.exitCode),
                userInfo: [NSLocalizedDescriptionKey:
                    shaResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        return shaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct HeadMessage: Equatable {
        let subject: String
        let body: String
    }

    func headMessage(worktreePath: URL) async throws -> HeadMessage? {
        guard try await hasHead(worktreePath: worktreePath) else { return nil }
        // %s + \u{1e} + %b ensures subject can't bleed into the body even
        // when the subject contains odd characters.
        let result = try await Process.git(
            ["log", "-1", "--pretty=format:%s%x1e%b", "HEAD"],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else { return nil }
        let parts = result.stdout.components(separatedBy: "\u{1e}")
        let subject = (parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (parts.count > 1 ? parts[1] : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HeadMessage(subject: subject, body: body)
    }

    /// Returns true when HEAD is at the upstream's tip, or strictly behind it.
    /// Used by the draft commit tab to show a soft "rewrites history" warning
    /// on the Amend checkbox. False when no upstream is configured (nothing
    /// to compare against) or on detached HEAD.
    func isHeadAtOrBehindUpstream(worktreePath: URL) async throws -> Bool {
        try await headPublicationState(worktreePath: worktreePath) == .published
    }

    static func assertSuccess(_ result: ProcessResult, op: String) throws {
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "GitService.\(op)",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey:
                    result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }
}
