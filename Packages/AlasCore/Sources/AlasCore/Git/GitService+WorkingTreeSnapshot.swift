import Foundation

extension GitService {
    /// Writes the working tree, tracked changes plus untracked non-ignored
    /// files, as a git tree object and returns its SHA. A scratch copy of the
    /// index does the staging, so the real index and the working tree stay
    /// untouched. Nothing references the tree: `git gc` may prune it once it
    /// is older than `gc.pruneExpire` (two weeks by default).
    ///
    /// Local worktrees only: the scratch index lives on this machine.
    public func workingTreeSnapshot(worktreePath: URL) async throws -> String {
        let git = LiveCheckpointGitRunner()
        func run(_ args: [String], environment: [String: String] = [:]) async throws -> String {
            let result = try await git.run(args, cwd: worktreePath, environment: environment)
            guard result.exitCode == 0 else {
                throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let indexPath = try await run(["rev-parse", "--git-path", "index"])
        let realIndex = URL(fileURLWithPath: indexPath, relativeTo: worktreePath).standardizedFileURL
        let scratchIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchIndex) }
        // Starting from the real index keeps its stat cache, so `add -A` only
        // hashes files that changed instead of the whole tree.
        if FileManager.default.fileExists(atPath: realIndex.path) {
            try FileManager.default.copyItem(at: realIndex, to: scratchIndex)
        }
        let environment = ["GIT_INDEX_FILE": scratchIndex.path]
        _ = try await run(["add", "-A"], environment: environment)
        return try await run(["write-tree"], environment: environment)
    }
}
