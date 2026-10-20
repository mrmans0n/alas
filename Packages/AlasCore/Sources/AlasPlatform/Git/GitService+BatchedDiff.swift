import Foundation

/// One `git diff` per review instead of one per file. Each result is keyed by
/// the file's new-side path; a path missing from the result had no section in
/// the batched output, and callers diff it on its own as before.
extension GitService {
    /// The diff between two trees for every changed file. Uses the same
    /// `-M -C` detection as the file list (`rangeChangedFiles`), so renames
    /// and copies pair up the same way the per-file diffs do.
    public func treeDiffsByFile(
        worktreePath: URL,
        revisions: (before: String, after: String),
        paths: [String]
    ) async throws -> [String: ParsedDiff] {
        try await batchedDiffs(
            ["-c", "core.quotePath=false", "diff", "--no-color", "-M", "-C", revisions.before, revisions.after],
            worktreePath: worktreePath,
            paths: paths,
            domain: "GitService.treeDiffsByFile"
        )
    }

    /// The diff a commit introduces against its first parent, or against the
    /// empty tree for a root commit, matching `diff(worktreePath:sha:file:)`.
    public func commitDiffsByFile(worktreePath: URL, sha: String, paths: [String]) async throws -> [String: ParsedDiff] {
        let parent = try await firstParentOrEmptyTree(worktreePath: worktreePath, sha: sha)
        return try await treeDiffsByFile(worktreePath: worktreePath, revisions: (parent, sha), paths: paths)
    }

    /// Unstaged (worktree vs index) or staged (index vs HEAD) diffs, matching
    /// `diff(worktreePath:file:staged:originalPath:)` for files `git status`
    /// reports without a rename or copy source. Such a per-file diff never
    /// pairs paths outside its own pathspec, so neither does the batch,
    /// whatever the rename config says; renamed and copied files belong on
    /// the per-file path. Untracked files never appear in `git diff`.
    public func workingCopyDiffsByFile(worktreePath: URL, staged: Bool, paths: [String]) async throws -> [String: ParsedDiff] {
        var args = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-renames"]
        if staged {
            args.append("--cached")
            if try await hasHead(worktreePath: worktreePath) { args.append("HEAD") }
        }
        return try await batchedDiffs(args, worktreePath: worktreePath, paths: paths, domain: "GitService.workingCopyDiffsByFile")
    }

    private func batchedDiffs(
        _ args: [String],
        worktreePath: URL,
        paths: [String],
        domain: String
    ) async throws -> [String: ParsedDiff] {
        guard !paths.isEmpty else { return [:] }
        let result = try await Process.git(args, cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw NSError(domain: domain, code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
        let stdout = result.stdout
        return await Task.detached(priority: .userInitiated) {
            Self.sliceDiffByFile(stdout, files: paths).mapValues(DiffParser.parse)
        }.value
    }

    /// Splits multi-file `git diff` output into the section for each of
    /// `files`, matched on the new-side path the way `sliceDiffForFile` does.
    /// Files with no section are absent from the result.
    public static func sliceDiffByFile(_ raw: String, files: [String]) -> [String: String] {
        var fileByMarker: [String: String] = [:]
        for file in files {
            fileByMarker["b/\(file)"] = file
            if let escaped = gitEscapedPathIfNeeded(file) {
                fileByMarker["\"b/\(escaped)\""] = file
            }
        }

        var linesByFile: [String: [String]] = [:]
        var currentFile: String?
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                currentFile = matchingFile(header: line, fileByMarker: fileByMarker)
                    .flatMap { linesByFile[$0] == nil ? $0 : nil }
                if let currentFile { linesByFile[currentFile] = [line] }
            } else if let currentFile {
                linesByFile[currentFile]?.append(line)
            }
        }
        return linesByFile.mapValues { $0.joined(separator: "\n") }
    }

    /// The header's new-side token is a suffix starting at ` b/` or ` "b/`.
    /// Paths may contain either sequence, so the longest suffix that names a
    /// requested file wins.
    private static func matchingFile(header: String, fileByMarker: [String: String]) -> String? {
        var searchStart = header.startIndex
        while let space = header[searchStart...].firstIndex(of: " ") {
            let token = header.index(after: space)
            let suffix = header[token...]
            if suffix.hasPrefix("b/") || suffix.hasPrefix("\"b/"), let file = fileByMarker[String(suffix)] {
                return file
            }
            searchStart = token
        }
        return nil
    }
}
