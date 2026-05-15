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

    /// Create a new commit (or amend HEAD) with the given subject and optional
    /// body. The body is trimmed; an empty body skips the second `-m` so we
    /// don't leave a trailing blank paragraph in the commit message.
    func commit(
        worktreePath: URL,
        subject: String,
        body: String,
        amend: Bool
    ) async throws {
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
