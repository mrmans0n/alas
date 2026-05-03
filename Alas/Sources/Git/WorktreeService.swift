import Foundation

struct WorktreeService {
    enum WorktreeError: Error { case gitFailed(String) }

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
        let result = try await Process.git(
            ["worktree", "add", destination.path, "-b", branch, base],
            cwd: repoPath
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return Worktree(
            id: Worktree.makeId(path: destination),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: destination,
            status: .clean,
            lastActivity: Date()
        )
    }

    func remove(repoPath: URL, worktreePath: URL, deleteBranchIfMerged: Bool) async throws {
        let result = try await Process.git(
            ["worktree", "remove", worktreePath.path],
            cwd: repoPath
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        if deleteBranchIfMerged {
            // Best-effort delete. -d only succeeds if merged; ignore failures.
            let branchName = worktreePath.lastPathComponent
            _ = try? await Process.git(["branch", "-d", branchName], cwd: repoPath)
        }
    }

    func prune(repoPath: URL) async throws {
        let result = try await Process.git(["worktree", "prune"], cwd: repoPath)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
    }
}
