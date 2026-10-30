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
            if await environment.checkpointRecoveryBlocksRemoval(listed, in: self) {
                throw HostError.failed(message: "A checkpoint restore is pending on the host; finish it there first.")
            }
            return try await Process.$gitLiteralPathspecs.withValue(true) { try await apply(change, to: listed) }
        }
    }

    private func apply(_ change: HostWorktreeChange, to worktree: Worktree) async throws -> HostResponse {
        let root = worktree.path
        let git = GitService()
        switch change {
        case .commit, .push, .pull, .cherryPick, .revert, .merge, .rebase:
            if try await git.mergeState(worktreePath: root) != nil {
                throw HostError.failed(message: "A rebase, merge, cherry-pick or revert is in progress; finish or abort it first.")
            }
        case .stage, .unstage, .discard, .fetch, .stash, .applyStash, .popStash, .dropStash, .continueOperation, .skipOperation,
             .abortOperation, .useOurs, .useTheirs, .keepDeleted, .markResolved, .editCommit, .createCheckpoint, .deleteCheckpoint,
             .restoreCheckpoint, .hunk:
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
            case .conflict: throw HostError.failed(message: "Pull stopped on conflicts; resolve them, then continue.")
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
            try await relistBranch(of: worktree)
        // Conflicted paths are resolved as locally, with or without an
        // operation: a conflicting stash pop leaves none.
        case .useOurs(let path):
            try await Self.refuseOutside([path], of: root)
            try await Self.refuseUnlessConflicted(path, at: root)
            try await git.useOurs(worktreePath: root, relativePath: path)
            try await git.markResolved(worktreePath: root, relativePath: path)
        case .useTheirs(let path):
            try await Self.refuseOutside([path], of: root)
            try await Self.refuseUnlessConflicted(path, at: root)
            try await git.useTheirs(worktreePath: root, relativePath: path)
            try await git.markResolved(worktreePath: root, relativePath: path)
        case .keepDeleted(let path):
            try await Self.refuseOutside([path], of: root)
            try await Self.refuseUnlessConflicted(path, at: root)
            try await git.keepDeleted(worktreePath: root, relativePath: path)
        case .markResolved(let path):
            try await Self.refuseOutside([path], of: root)
            try await git.markResolved(worktreePath: root, relativePath: path)
        case .cherryPick(let sha):
            try Self.throwIfFailed(await git.cherryPick(worktreePath: root, sha: Self.verifiedCommit(sha, at: root)))
        case .revert(let sha):
            try Self.throwIfFailed(await git.revert(worktreePath: root, sha: Self.verifiedCommit(sha, at: root)))
        case .merge(let branch):
            try Self.throwIfFailed(await git.merge(worktreePath: root, branch: Self.listedBranch(branch, of: worktree)))
        case .rebase(let onto):
            try Self.throwIfFailed(await git.rebase(worktreePath: root, onto: Self.listedBranch(onto, of: worktree)))
            try await relistBranch(of: worktree)
        case .editCommit(let sha, let edit, let comparisonMode):
            return .commitEdited(result: try await editCommit(sha, edit: edit, comparisonMode: comparisonMode, at: root))
        case .createCheckpoint, .deleteCheckpoint, .restoreCheckpoint:
            return try await applyCheckpointChange(change, to: worktree)
        case .hunk(let path, let stage, let index, let header, let linesHash, let action):
            try await Self.applyHunk(
                path: path, stage: stage, index: index, header: header, linesHash: linesHash, action: action, at: root)
        }
        return .done
    }

    /// As `editCommit`'s `dropHunk`: the host re-reads the diff the Mac was
    /// shown, as `remoteFileDiff` reads it, and builds the patch from its own
    /// hunk, which must still have `header` and `linesHash`.
    private static func applyHunk(
        path: String, stage: ChangeStage, index: Int, header: String, linesHash: String, action: HostHunkAction, at root: URL
    ) async throws {
        try await refuseOutside([path], of: root)
        guard (action == .unstage) == (stage == .staged) else {
            throw HostError.invalidRequest(reason: "A hunk is staged or discarded from the unstaged diff, and unstaged from the staged one.")
        }
        let changed = HostError.failed(message: "The file changed since it was shown. Refresh and try again.")
        let git = GitService()
        // Only a path the Changes list shows on that side: never an ignored file.
        let entries = try await git.statusIdentity(worktreePath: root).filter { $0.path == path }
        guard let identity = entries.first, let entry = entries.first(where: { $0.stage == stage }) else { throw changed }
        guard identity.conflict == nil else { throw HostError.failed(message: "Resolve the conflict on \(path) first.") }
        let diff = try await git.remoteDiff(
            worktreePath: root, file: path, staged: stage == .staged, originalPath: identity.renameFrom,
            maxOutputBytes: RemoteWorktreeFileAccess.maxDiffSubprocessBytes)
        guard !diff.isBinary else { throw HostError.failed(message: "A binary file has no hunks.") }
        // Only a hunk the Mac was sent whole, as `remoteFileDiff` caps it.
        let shown = RemoteWorktreeFileAccess.truncateHunks(diff.hunks).hunks
        guard shown.indices.contains(index) else { throw changed }
        // A line past the cap was clamped: the Mac never saw the whole hunk.
        guard shown[index] == diff.hunks[index] else {
            throw HostError.failed(message: "This hunk is too large to change from here.")
        }
        let hunk = diff.hunks[index]
        guard hunk.header == header, !hunk.lines.isEmpty, RemoteDiffHunk(hunk).linesHash == linesHash else { throw changed }
        // A deletion's hunk patch would leave an empty file in the index:
        // whole-file staging removes the entry.
        guard entry.status != "D", !hunk.deletesWholeFile else {
            throw HostError.failed(message: "Stage or unstage the whole file instead.")
        }

        let tracked = try await Process.git(["--literal-pathspecs", "ls-files", "--error-unmatch", "--", path], cwd: root).exitCode == 0
        let arguments: [String]
        switch action {
        case .stage: arguments = ["apply", "--cached", "-"]
        case .unstage: arguments = ["apply", "--cached", "--reverse", "-"]
        case .discard:
            // As locally: an untracked file is discarded whole.
            guard tracked else {
                throw HostError.failed(message: "Discard \(path) as a whole file instead.")
            }
            arguments = ["apply", "--reverse", "-"]
        }
        // A new file's staged diff is its one hunk from /dev/null: unstaged
        // as a new-file patch, it leaves the index rather than staying empty.
        let unstagesAddition = action == .unstage && entry.status == "A" && hunk.oldStart == 0
        let mode: String
        if unstagesAddition {
            // `<mode> <sha> <stage>\t<path>`
            let listed = try await Process.git(["--literal-pathspecs", "ls-files", "-s", "--", path], cwd: root).stdout
            mode = listed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? HunkPatchBuilder.defaultUntrackedMode
        } else {
            mode = HunkPatchBuilder.fileMode(at: root.appendingPathComponent(path))
        }
        let patch = HunkPatchBuilder.patch(
            file: path, hunk: hunk, tracked: action == .stage ? tracked : !unstagesAddition, untrackedMode: mode)
        // Git's own context check is the last word on a stale hunk.
        guard try await Process.git(arguments, cwd: root, stdin: patch).exitCode == 0 else { throw changed }
    }

    /// A rebase that ended restores its branch, which a listing read
    /// mid-rebase shows as `(detached)`: list it again, as a rename does.
    private func relistBranch(of worktree: Worktree) async throws {
        let head = try await GitService().currentBranch(worktreePath: worktree.path)
        if !head.isEmpty, head != worktree.branch {
            projects.applyHeadUpdates(projectId: worktree.projectId, branchByWorktreePath: [worktree.path: head])
            // Git already moved: a failed save does not fail the change.
            try? saveProjects()
        }
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
             .useTheirs, .keepDeleted, .markResolved, .cherryPick, .revert, .merge, .rebase, .editCommit, .createCheckpoint,
             .deleteCheckpoint, .restoreCheckpoint, .hunk:
            preconditionFailure("not a stash change")
        }
    }

    /// As the commit editor edits it, above the fold the Changes list shows
    /// for `comparisonMode`. The editor refuses a dirty tree, an operation
    /// in progress and a merge commit in the replay.
    private func editCommit(
        _ sha: String, edit: HostCommitEdit, comparisonMode: AppConfig.Changes.ChangesComparisonMode?, at root: URL
    ) async throws -> CommitEditResult {
        let git = GitService()
        let target = try await Self.verifiedCommit(sha, at: root)
        let configuration = environment.configuration()
        guard let baseRef = try await git.commitsAhead(
            at: root, baseBranch: configuration.worktrees.baseBranch,
            resolution: .forCommits(mode: comparisonMode ?? configuration.changes.comparisonMode, userOverrodeBaseBranch: false)
        ).comparisonRef else {
            throw HostError.failed(message: CommitEditError.targetNotAboveFold.errorDescription ?? "")
        }
        let changed = HostError.failed(message: "This commit changed since it was shown. Refresh and try again.")
        let action: CommitEditAction
        switch edit {
        case .message(let subject, let body):
            action = .message(subject: subject, body: body)
        case .dropFile(let path):
            try await Self.refuseOutside([path], of: root)
            guard try await git.commitDetails(at: root, sha: target).files.contains(where: { $0.path == path }) else { throw changed }
            action = .dropFile(path: path)
        case .dropHunk(let path, let index, let header):
            try await Self.refuseOutside([path], of: root)
            guard let file = try await git.commitDetails(at: root, sha: target).files.first(where: { $0.path == path }) else {
                throw changed
            }
            let hunks = try await git.diff(
                worktreePath: root, sha: target, file: path, originalPath: file.originalPath,
                maxOutputBytes: RemoteWorktreeFileAccess.maxDiffSubprocessBytes
            ).hunks
            // Only a hunk the Mac was sent whole, as `HostDiff` caps it.
            let shown = RemoteWorktreeFileAccess.truncateHunks(hunks).hunks
            guard shown.indices.contains(index), shown[index] == hunks[index], hunks[index].header == header,
                  !hunks[index].lines.isEmpty
            else { throw changed }
            action = .dropHunk(path: path, hunk: hunks[index])
        }
        return try await git.editCommit(worktreePath: root, baseRef: baseRef, targetSha: target, action: action)
    }

    /// A commit as its editor shows it, its files capped as a commit's files read is.
    func commitDetails(_ sha: String, in worktree: Worktree) async throws -> CommitDetails {
        let details = try await GitService().commitDetails(at: worktree.path, sha: Self.verifiedCommit(sha, at: worktree.path))
        let files = details.files.filter { RemoteWorktreeFileAccess.normalizedRelativePath($0.path) != nil }
        return CommitDetails(
            info: details.info, body: details.body, authorEmail: details.authorEmail, parents: details.parents,
            files: Array(files.prefix(RemoteWorktreeFileAccess.maxChangedFiles))
        )
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
        let read = try await git.stashDiff(worktreePath: worktree.path, stash: listed, file: file,
                                           maxOutputBytes: RemoteWorktreeFileAccess.maxDiffSubprocessBytes)
        var diff = HostDiff(read.diff)
        diff.truncated = diff.truncated || read.truncated
        return diff
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

    /// Taking a side or deleting a path that is no longer unmerged would
    /// overwrite or remove the host's work: a stale client is refused. The
    /// path itself must be unmerged; a folder holding a conflict is not, and
    /// taking a side on it would restore every merged file in it.
    private static func refuseUnlessConflicted(_ path: String, at root: URL) async throws {
        // `<mode> <sha> <stage>\t<path>`, NUL-terminated.
        let unmerged = try await Process.git(["--literal-pathspecs", "ls-files", "-u", "-z", "--", path], cwd: root)
        let paths = unmerged.stdout.split(separator: "\0").compactMap { $0.split(separator: "\t", maxSplits: 1).last }
        guard unmerged.exitCode == 0, paths.contains(where: { $0 == path }) else {
            throw HostError.failed(message: "The conflict on \(path) changed; refresh and try again.")
        }
    }

    /// `sha` as a full commit SHA of this repository: a client never hands
    /// git a rev expression or an option.
    static func verifiedCommit(_ sha: String, at root: URL) async throws -> String {
        guard RemoteWorktreeFileAccess.isCommitSHA(sha) else {
            throw HostError.invalidRequest(reason: "A commit is named by its SHA.")
        }
        let resolved = try await Process.git(["rev-parse", "--verify", "--quiet", "\(sha)^{commit}"], cwd: root)
        let full = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.exitCode == 0, !full.isEmpty else { throw HostError.notFound(what: "commit \(sha)") }
        return full
    }

    /// `name` as one of the repository's branches other than the worktree's
    /// own: a client never hands git a rev expression or an option.
    private static func listedBranch(_ name: String, of worktree: Worktree) async throws -> String {
        guard try await GitService().branches(at: worktree.path).contains(name) else {
            throw HostError.failed(message: "\(name) isn't a branch of this repository.")
        }
        guard name != worktree.branch else {
            throw HostError.failed(message: "A worktree can't merge or rebase onto its own branch.")
        }
        return name
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
    nonisolated static func refuseOutside(_ paths: [String], of root: URL) async throws {
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
