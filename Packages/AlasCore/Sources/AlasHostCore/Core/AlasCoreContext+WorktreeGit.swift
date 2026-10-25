import Foundation
import AlasFeatures
import AlasIntegrations
import AlasModel
import AlasPlatform

extension AlasCoreContext {
    /// A paired Mac's git action on a listed worktree on `branch`, the one it
    /// saw, under the project's mutation gate as a rename is. Paths outside
    /// the worktree are refused.
    func mutateListedWorktree(_ worktree: Worktree, branch: String, change: HostWorktreeChange) async throws {
        // Not awaited: the reply does not wait on the code host. A change
        // that threw, such as a pull stopped on conflicts, may have moved
        // the worktree too.
        defer { Task { _ = await refreshFollowedReviewStatus(worktree.id) } }
        try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) { @MainActor [self] in
            try refuseIfStopping()
            let changed = HostError.failed(message: "The worktree changed since it was listed.")
            guard let listed = projects.worktrees(projectId: worktree.projectId).first(where: { $0.id == worktree.id }),
                  listed.branch == branch
            else { throw changed }
            // A headless host watches no HEAD, so the listing can lag a
            // checkout made on the host: git has the last word.
            let head = try await GitService().currentBranch(worktreePath: listed.path)
            guard (head.isEmpty ? "(detached)" : head) == branch else { throw changed }
            guard isWorktreeIdle(listed) else { throw WorktreeBusyError() }
            if await environment.checkpointRecoveryBlocksRemoval(listed) {
                throw HostError.failed(message: "A checkpoint restore is pending on the host; finish it there first.")
            }
            try await Process.$gitLiteralPathspecs.withValue(true) { try await apply(change, to: listed) }
        }
    }

    private func apply(_ change: HostWorktreeChange, to worktree: Worktree) async throws {
        let root = worktree.path
        let git = GitService()
        switch change {
        case .commit, .push, .pull:
            if try await git.mergeState(worktreePath: root) != nil {
                throw HostError.failed(message: "A rebase, merge, cherry-pick or revert is in progress on the host; finish it there first.")
            }
        case .stage, .unstage, .discard, .fetch:
            break
        }
        switch change {
        case .stage(let paths):
            try await Self.refuseOutside(paths, of: root)
            try await git.stageAll(worktreePath: root, files: paths)
        case .unstage(let paths):
            try await Self.refuseOutside(paths, of: root)
            let changes = try await Self.changesByPath(at: root)
            let files = paths.flatMap { changes[$0]?.gitPaths ?? [$0] }
            try await git.unstageAll(worktreePath: root, files: files)
        case .discard(let paths):
            try await Self.refuseOutside(paths, of: root)
            // As `ChangedFile.discardPaths(forFileAt:in:)`, without a scan per path.
            let changes = try await Self.changesByPath(at: root)
            var seen = Set<String>()
            let files = paths.flatMap { changes[$0]?.gitPaths ?? [] }.filter { seen.insert($0).inserted }
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
        case .push(let forceWithLease):
            // Read from git alone: the code host is the refresh after the gate's.
            let loop = reviewLoop(for: worktree, baseBranch: environment.configuration().worktrees.baseBranch)
            let (local, remotes): (ReviewLoopLocalState, [GitRemote])
            do {
                (local, remotes) = try await Self.localReviewState(at: root, baseBranch: loop.currentBaseBranch)
            } catch {
                throw HostError.failed(message: "The branch's push target could not be read: \(error.localizedDescription)")
            }
            let snapshot = loop.snapshotWithoutCodeHost(local: local, remotes: remotes)
            let result = try await Process.git(snapshot.pushArguments(forceWithLease: forceWithLease), cwd: root)
            guard result.exitCode == 0 else { throw HostError.failed(message: result.pushFailureMessage) }
        case .pull:
            // As locally, a conflict leaves the rebase in place to resolve.
            switch try await git.pull(worktreePath: root) {
            case .clean: break
            case .conflict: throw HostError.failed(message: "Pull stopped on conflicts; resolve them on the host.")
            case .error(let message): throw HostError.failed(message: message)
            }
        case .fetch:
            // What the local "Fetch now" fetches: the upstream and the base.
            if let upstream = try await git.resolveUpstreamRef(worktreePath: root) {
                let branch = String(upstream.ref.dropFirst(upstream.remote.count + 1))
                try await git.fetchRef(worktreePath: root, remote: upstream.remote, branch: branch)
            }
            let baseBranch = environment.configuration().worktrees.baseBranch
            if let base = try await git.resolveBaseRef(worktreePath: root, baseBranch: baseBranch, preferLocal: false),
               let remote = base.remote {
                try await git.fetchRef(worktreePath: root, remote: remote, branch: base.fetchBranch ?? baseBranch)
            }
        }
    }

    /// Client paths name files inside the worktree: never an empty path or
    /// one with a NUL, an absolute path, a `..` component, or a directory
    /// that resolves out of it. The last component is acted on as itself,
    /// so a tracked symlink stays usable; a folder that is gone is judged by
    /// its nearest ancestor on disk.
    /// Off the main actor: it touches the disk once per path.
    nonisolated private static func refuseOutside(_ paths: [String], of root: URL) async throws {
        guard paths.count <= maxPaths else {
            throw HostError.invalidRequest(reason: "One request can name at most \(maxPaths) paths.")
        }
        let base = root.isRemoteAlasPath ? nil : realPath(root)
        for path in paths {
            guard !path.isEmpty, !path.contains("\0") else {
                throw HostError.invalidRequest(reason: "A path is empty or holds a NUL character.")
            }
            // A remote worktree's disk is not here to resolve; its git
            // refuses a path beyond a symlink itself.
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  root.isRemoteAlasPath || resolvesInside(path, of: root, base: base)
            else { throw HostError.invalidRequest(reason: "The path \(path) is outside the worktree.") }
        }
    }

    /// More than any Changes list a person picks from.
    nonisolated private static let maxPaths = 10_000

    /// The worktree's changes by path, the first of each as a scan finds it.
    private static func changesByPath(at root: URL) async throws -> [String: ChangedFile] {
        let changes = try await GitService().status(worktreePath: root)
        return Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated private static func resolvesInside(_ path: String, of root: URL, base: String?) -> Bool {
        var parent = root.appendingPathComponent(path).deletingLastPathComponent()
        // lstat, so a dangling symlink counts as present and fails to resolve.
        while (try? FileManager.default.attributesOfItem(atPath: parent.path)) == nil, parent.path != "/" {
            parent = parent.deletingLastPathComponent()
        }
        guard let base, let resolved = realPath(parent) else { return false }
        return (resolved + "/").hasPrefix(base + "/")
    }

    nonisolated private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
