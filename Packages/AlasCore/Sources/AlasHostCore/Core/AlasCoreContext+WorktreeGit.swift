import Foundation
import AlasFeatures
import AlasModel
import AlasPlatform

extension AlasCoreContext {
    /// A paired Mac's git action on a listed worktree on `branch`, the one it
    /// saw, under the project's mutation gate as a rename is. Paths outside
    /// the worktree are refused.
    func mutateListedWorktree(_ worktree: Worktree, branch: String, change: HostWorktreeChange) async throws {
        try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) { @MainActor [self] in
            try refuseIfStopping()
            guard let listed = projects.worktrees(projectId: worktree.projectId).first(where: { $0.id == worktree.id }),
                  listed.branch == branch
            else { throw HostError.failed(message: "The worktree changed since it was listed.") }
            guard isWorktreeIdle(listed) else { throw WorktreeBusyError() }
            if await environment.checkpointRecoveryBlocksRemoval(listed) {
                throw HostError.failed(message: "A checkpoint restore is pending on the host; finish it there first.")
            }
            try await Process.$gitLiteralPathspecs.withValue(true) { try await Self.apply(change, at: listed.path) }
        }
    }

    private static func apply(_ change: HostWorktreeChange, at root: URL) async throws {
        let git = GitService()
        switch change {
        case .stage(let paths):
            try refuseOutside(paths, of: root)
            try await git.stageAll(worktreePath: root, files: paths)
        case .unstage(let paths):
            try refuseOutside(paths, of: root)
            let changes = try await git.status(worktreePath: root)
            let files = paths.flatMap { path in changes.first { $0.path == path }?.gitPaths ?? [path] }
            try await git.unstageAll(worktreePath: root, files: files)
        case .discard(let paths):
            try refuseOutside(paths, of: root)
            let changes = try await git.status(worktreePath: root)
            var seen = Set<String>()
            let files = paths.flatMap { ChangedFile.discardPaths(forFileAt: $0, in: changes) }.filter { seen.insert($0).inserted }
            guard !files.isEmpty else { throw HostError.failed(message: "These changes are no longer in the worktree.") }
            try await git.discardPaths(worktreePath: root, files: files)
        case .commit(let subject, let body, let amend):
            guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HostError.invalidRequest(reason: "A commit needs a subject.")
            }
            if !amend, try await Process.git(["diff", "--cached", "--quiet"], cwd: root).exitCode == 0 {
                throw HostError.failed(message: "Nothing is staged to commit.")
            }
            _ = try await git.commit(worktreePath: root, subject: subject, body: body, amend: amend)
        case .push, .pull, .fetch:
            throw HostError.invalidRequest(reason: "This host does not sync worktrees yet.")
        }
    }

    /// Client paths name files inside the worktree: never an empty path or
    /// one with a NUL, an absolute path, a `..` component, or a directory
    /// that resolves out of it. The last component is acted on as itself,
    /// so a tracked symlink stays usable; a folder that is gone is judged by
    /// its nearest ancestor on disk.
    private static func refuseOutside(_ paths: [String], of root: URL) throws {
        for path in paths {
            guard !path.isEmpty, !path.contains("\0") else {
                throw HostError.invalidRequest(reason: "A path is empty or holds a NUL character.")
            }
            // A remote worktree's disk is not here to resolve; its git
            // refuses a path beyond a symlink itself.
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  root.isRemoteAlasPath || resolvesInside(path, of: root)
            else { throw HostError.invalidRequest(reason: "The path \(path) is outside the worktree.") }
        }
    }

    private static func resolvesInside(_ path: String, of root: URL) -> Bool {
        var parent = root.appendingPathComponent(path).deletingLastPathComponent()
        // lstat, so a dangling symlink counts as present and fails to resolve.
        while (try? FileManager.default.attributesOfItem(atPath: parent.path)) == nil, parent.path != "/" {
            parent = parent.deletingLastPathComponent()
        }
        guard let base = realPath(root), let resolved = realPath(parent) else { return false }
        return (resolved + "/").hasPrefix(base + "/")
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
