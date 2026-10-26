import Foundation
import AlasFeatures
import AlasIntegrations
import AlasModel
import AlasPlatform

extension AlasCoreContext {
    /// A paired Mac's git action on a listed worktree on `branch`, the one it
    /// saw, under the project's mutation gate as a rename is. Paths outside
    /// the worktree are refused.
    func mutateListedWorktree(_ worktree: Worktree, branch: String, change: HostWorktreeChange) async throws -> HostResponse {
        // Not awaited: the reply does not wait on the code host. A change
        // that threw, such as a pull stopped on conflicts, may have moved
        // the worktree too.
        defer { Task { _ = await refreshFollowedReviewStatus(worktree.id) } }
        return try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) { @MainActor [self] in
            try refuseIfStopping()
            let changed = HostError.failed(message: "The worktree changed since it was listed.")
            guard let listed = projects.worktrees(projectId: worktree.projectId).first(where: { $0.id == worktree.id }),
                  listed.branch == branch
            else { throw changed }
            // Archived while the request waited on the gate: refused as the
            // endpoint refuses one archived before it.
            guard !projects.isWorktreeHidden(projectId: listed.projectId, path: listed.path) else {
                throw HostError.notFound(what: "worktree \(listed.path.path) in project \(listed.projectId)")
            }
            // A headless host watches no HEAD, so the listing can lag a
            // checkout made on the host: git has the last word.
            let head = try await GitService().currentBranch(worktreePath: listed.path)
            if (head.isEmpty ? "(detached)" : head) != branch {
                // Mid-rebase git is detached while the listing still names the
                // branch being rebased: only a way out of that rebase passes.
                guard change.leavesAnOperation, head.isEmpty,
                      case .rebase(let plan)? = try await GitService().mergeState(worktreePath: listed.path),
                      plan.sourceBranch == branch
                else { throw changed }
            }
            guard isWorktreeIdle(listed) else { throw WorktreeBusyError() }
            if await environment.checkpointRecoveryBlocksRemoval(listed) {
                throw HostError.failed(message: "A checkpoint restore is pending on the host; finish it there first.")
            }
            return try await Process.$gitLiteralPathspecs.withValue(true) { try await apply(change, to: listed) }
        }
    }

    private func apply(_ change: HostWorktreeChange, to worktree: Worktree) async throws -> HostResponse {
        let root = worktree.path
        let git = GitService()
        switch change {
        case .commit, .push, .pull:
            if try await git.mergeState(worktreePath: root) != nil {
                throw HostError.failed(message: "A rebase, merge, cherry-pick or revert is in progress on the host; finish it there first.")
            }
        case .stage, .unstage, .discard, .fetch, .stash, .applyStash, .popStash, .dropStash, .continueOperation, .skipOperation,
             .abortOperation, .useOurs, .useTheirs, .keepDeleted, .markResolved:
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
        case .stash, .applyStash, .popStash, .dropStash:
            // They name no client paths, and git's own `:/` pathspec, which
            // cleans stashed untracked files, must not be taken literally.
            try await Process.$gitLiteralPathspecs.withValue(false) { try await Self.applyStashChange(change, at: root) }
        case .continueOperation(let kind), .skipOperation(let kind), .abortOperation(let kind):
            // Only the operation the client saw: a conflict it led to shows in the next changes read.
            guard let operation = try await git.mergeState(worktreePath: root), HostOperationKind(operation) == kind else {
                throw HostError.failed(message: "The operation on the host changed; refresh and try again.")
            }
            switch change {
            case .abortOperation: try await git.abortOperation(worktreePath: root, op: operation)
            case .skipOperation: try Self.throwIfFailed(await git.skipOperation(worktreePath: root, op: operation))
            default: try Self.throwIfFailed(await git.continueOperation(worktreePath: root, op: operation))
            }
        // Conflicted paths are resolved as locally, with or without an
        // operation: a conflicting stash pop leaves none.
        case .useOurs(let path):
            try await Self.refuseOutside([path], of: root)
            try await git.useOurs(worktreePath: root, relativePath: path)
            try await git.markResolved(worktreePath: root, relativePath: path)
        case .useTheirs(let path):
            try await Self.refuseOutside([path], of: root)
            try await git.useTheirs(worktreePath: root, relativePath: path)
            try await git.markResolved(worktreePath: root, relativePath: path)
        case .keepDeleted(let path):
            try await Self.refuseOutside([path], of: root)
            try await git.keepDeleted(worktreePath: root, relativePath: path)
        case .markResolved(let path):
            try await Self.refuseOutside([path], of: root)
            try await git.markResolved(worktreePath: root, relativePath: path)
        }
        return .done
    }

    private static func applyStashChange(_ change: HostWorktreeChange, at root: URL) async throws {
        let git = GitService()
        switch change {
        case .stash(let message, let includeUntracked):
            try throwIfFailed(await git.pushStash(worktreePath: root, message: message, includeUntracked: includeUntracked))
        case .applyStash(let stash):
            try throwIfFailed(await git.applyStash(worktreePath: root, stash: listedStash(stash, at: root)))
        case .popStash(let stash):
            try throwIfFailed(await git.popStash(worktreePath: root, stash: listedStash(stash, at: root)))
        case .dropStash(let stash):
            try await git.dropStash(worktreePath: root, stash: listedStash(stash, at: root))
        case .stage, .unstage, .discard, .commit, .push, .pull, .fetch, .continueOperation, .skipOperation, .abortOperation, .useOurs,
             .useTheirs, .keepDeleted, .markResolved:
            preconditionFailure("not a stash change")
        }
    }

    /// The repository's stashes, as the worktree lists them.
    func stashes(in worktree: Worktree) async throws -> [GitStash] {
        try await GitService().stashes(worktreePath: worktree.path)
    }

    func stashFiles(_ stash: HostStashRef, in worktree: Worktree) async throws -> [GitStashFile] {
        try await GitService().stashFiles(worktreePath: worktree.path, stash: Self.listedStash(stash, at: worktree.path))
    }

    func stashDiff(_ stash: HostStashRef, path: String, in worktree: Worktree) async throws -> HostDiff {
        let git = GitService()
        let listed = try await Self.listedStash(stash, at: worktree.path)
        guard let file = try await git.stashFiles(worktreePath: worktree.path, stash: listed).first(where: { $0.path == path }) else {
            throw HostError.invalidRequest(reason: "The stash has no file \(path).")
        }
        let diff = try await Process.$gitLiteralPathspecs.withValue(true) {
            try await git.stashDiff(worktreePath: worktree.path, stash: listed, file: file)
        }
        return HostDiff(diff)
    }

    /// The entry of `git stash list` equal to `stash`, else "This stash changed since it was listed. Refresh and try again."
    /// A client ref is never handed to git unless the list holds it.
    private static func listedStash(_ stash: HostStashRef, at root: URL) async throws -> GitStash {
        guard let listed = try await GitService().stashes(worktreePath: root).first(where: { $0.ref == stash.ref && $0.sha == stash.sha })
        else { throw HostError.failed(message: "This stash changed since it was listed. Refresh and try again.") }
        return listed
    }

    /// As locally, a conflict or error is shown; conflicted files stay in the worktree.
    private static func throwIfFailed(_ result: StashOperationResult) throws {
        switch result {
        case .clean: break
        case .conflict(let message), .error(let message): throw HostError.failed(message: message)
        }
    }

    /// A conflict is left to the next changes read; an error is shown.
    private static func throwIfFailed(_ result: MergeResult) throws {
        if case .error(let message) = result { throw HostError.failed(message: message) }
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
