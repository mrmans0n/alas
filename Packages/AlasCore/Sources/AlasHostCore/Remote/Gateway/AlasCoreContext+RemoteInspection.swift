import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// What a Remote client reads of a session's worktree: its changes, diffs,
/// files and commits, local or on the project's SSH host. Reading needs no
/// writer lease: seeing a session is enough to read its code.
extension AlasCoreContext {
    /// Distinguishes between a session that was never found vs. one whose
    /// worktree is no longer available (e.g. deleted while its manager still
    /// lives), so callers can report different error messages.
    @_spi(AppHost) public enum RemoteWorktreeContextResult {
        case found(Worktree)
        case sessionUnknown
        case worktreeUnavailable
    }

    /// Resolves the worktree backing a session id by scanning the live
    /// per-worktree managers, mirroring how `session(for:)` looks sessions up.
    ///
    /// Checks both the live session and the persisted rows — matching every
    /// other lookup in this file (`session(for:)`, `hydrateIfNeeded`,
    /// `renameSession`) — because a just-created session is installed into
    /// `liveSession(for:)` immediately, while `sessionRows` can briefly lag
    /// behind an in-flight `refreshRecent()` snapshot.
    @_spi(AppHost) public func remoteWorktreeContext(sessionId: String) -> RemoteWorktreeContextResult {
        for mgr in sessionManagers.values
        where mgr.liveSession(for: sessionId) != nil || mgr.sessionRows.contains(where: { $0.id == sessionId }) {
            guard let resolved = projectAndWorktree(withWorktreeId: mgr.worktreeId) else {
                return .worktreeUnavailable
            }
            return .found(resolved.worktree)
        }
        return .sessionUnknown
    }

    /// Outcome of reading a worktree-relative file's raw bytes from a
    /// registered SSH host, mirroring the containment + read pipeline
    /// `ACPRemoteFileServer.read` uses for editor reads — but surfacing raw
    /// `Data` instead of requiring UTF-8, since the remote Files/Changes
    /// surface applies its own binary-sniff / size-cap logic on top.
    ///
    /// Internal (not `private`) so `AlasTests` can exercise
    /// `readRemoteWorktreeFileRaw` directly: this environment has no
    /// reachable SSH host to stand up a full remote-worktree integration
    /// test against, so this is the seam that lets a test prove the remote
    /// branch never silently falls back to local-disk I/O.
    @_spi(Testing) public enum RemoteWorktreeRawReadOutcome {
        case data(Data)
        /// The remote path is missing, a directory, or a symlink — not a
        /// readable plain file.
        case notFound
        /// Transport or remote-side error unrelated to the containment check.
        case unreadable(String)
        /// The resolved path escaped the worktree root.
        case containmentRejected
        /// The remote file's stat'd size exceeds
        /// `RemoteWorktreeFileAccess.maxFileBytes` — its bytes were never
        /// transferred.
        case tooLarge(byteSize: Int)
    }

    /// Reads `relativePath` (already validated by
    /// `RemoteWorktreeFileAccess.normalizedRelativePath`) from `host` via
    /// `RemotePathContainment.containedRead`: a SINGLE remote script that
    /// performs the physical containment/`.git`-exclusion check and the
    /// bounded content read together, off the SAME resolved path, in one
    /// `RemoteExec.runData` round trip.
    ///
    /// This replaces what used to be three separate round trips —
    /// `verifyRemoteContainment`, then `RemoteFileAccess.size`, then
    /// `RemoteFileAccess.read` — each of which re-resolved `target` by
    /// STRING independently. Between those round trips, a concurrently
    /// running remote process could swap a path component for a symlink:
    /// the containment check saw a safe path, but a later, separately
    /// re-resolved read could still escape the worktree. See
    /// `RemotePathContainment.containedReadScript`'s doc comment for exactly
    /// what this closes and what residual (much narrower) race remains.
    ///
    /// Only ever transfers up to `RemoteWorktreeFileAccess.maxFileBytes`
    /// bytes of the file's body regardless of its actual size — the
    /// oversized case is reported from the script's own `stat`-derived size
    /// header, never from having transferred the whole file.
    @_spi(Testing) public func readRemoteWorktreeFileRaw(
        host: String, worktreeRoot: String, relativePath: String, maxBytes: Int = RemoteWorktreeFileAccess.maxFileBytes
    ) async -> RemoteWorktreeRawReadOutcome {
        do {
            switch try await RemotePathContainment.containedRead(
                host: host, path: relativePath, worktreeRoot: worktreeRoot, maxBytes: maxBytes
            ) {
            case .outsideWorktree:
                return .containmentRejected
            case .symlink, .directory, .missing:
                return .notFound
            case .unreadable:
                return .unreadable("remote read failed")
            case let .ok(byteSize, prefix):
                guard byteSize <= maxBytes else {
                    return .tooLarge(byteSize: byteSize)
                }
                return .data(prefix)
            }
        } catch RemotePathContainment.ContainmentError.outsideWorktree(_) {
            return .containmentRejected
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// Number of bytes `isDiffTargetBinary` sniffs to decide whether a file
    /// looks binary — matches `GitService.looksBinary` and
    /// `RemoteWorktreeFileAccess.looksBinaryOnDisk`'s 8 KB prefix, so a
    /// binary pre-check never needs more than that, on-disk or remote.
    private static let binarySniffPrefixBytes = 8192

    /// Bounded-prefix variant of `readRemoteWorktreeFileRaw`, used only for
    /// the binary pre-check ahead of a diff (`isDiffTargetBinary`): reads
    /// just the first `maxBytes` bytes of the remote file
    /// (`RemoteFileAccess.readPrefix`, exec-only — there is no helper-RPC
    /// byte cap), so a binary sniff never needs to consult the file's total
    /// size or hit `RemoteWorktreeFileAccess.maxFileBytes` at all. Mirrors
    /// the local path's `RemoteWorktreeFileAccess.looksBinaryOnDisk`, which
    /// reads only an 8 KB prefix via `FileHandle.read(upToCount:)`
    /// regardless of the file's size. Never returns `.tooLarge`.
    @_spi(Testing) public func readRemoteWorktreeFilePrefix(
        host: String, worktreeRoot: String, relativePath: String, maxBytes: Int
    ) async -> RemoteWorktreeRawReadOutcome {
        let target: String
        do {
            target = try RemotePathContainment.lexicallyResolveInsideWorktree(
                path: relativePath, worktreeRoot: worktreeRoot)
        } catch {
            return .containmentRejected
        }
        do {
            try await RemotePathContainment.verifyRemoteContainment(
                host: host, path: target, worktreeRoot: worktreeRoot)
        } catch RemotePathContainment.ContainmentError.outsideWorktree(_) {
            return .containmentRejected
        } catch {
            return .unreadable(String(describing: error))
        }
        do {
            guard let data = try await RemoteFileAccess.readPrefix(host: host, path: target, maxBytes: maxBytes) else {
                return .notFound
            }
            return .data(data)
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// Whether `normalizedPath` looks like a binary file for diff purposes.
    /// Prefers an on-disk sniff against the current working tree (mirroring
    /// git's own heuristic). When the file is missing from the working tree
    /// — the case a binary file deleted since `comparisonRef` hits — falls
    /// back to sniffing the blob at `comparisonRef` instead, so a deleted
    /// binary file still reports `.binary` rather than slipping through as
    /// an empty "successful" diff.
    ///
    /// The SSH branch sniffs only a bounded PREFIX
    /// (`readRemoteWorktreeFilePrefix`) rather than the full file: a binary
    /// verdict never needs more than the first 8 KB, so it must never be
    /// gated on `RemoteWorktreeFileAccess.maxFileBytes` — a new, oversized,
    /// untracked binary file used to hit that cap's `.tooLarge` outcome
    /// here, which (having nothing to sniff at any historical ref either,
    /// since the file is new) collapsed to "not binary" and produced a
    /// misleading empty "successful" diff.
    private func isDiffTargetBinary(
        worktree: Worktree, normalizedPath: String, url: URL, comparisonRef: String?, git: GitService,
        missingFileUsesIndex: Bool = false
    ) async -> Bool {
        let existsOnDisk: Bool
        let onDiskLooksBinary: Bool
        if worktree.path.isRemoteAlasPath, let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path) {
            switch await readRemoteWorktreeFilePrefix(
                host: host, worktreeRoot: worktree.path.path, relativePath: normalizedPath,
                maxBytes: Self.binarySniffPrefixBytes
            ) {
            case .data(let data):
                existsOnDisk = true
                onDiskLooksBinary = GitService.looksBinary(data)
            case .notFound, .unreadable, .containmentRejected, .tooLarge:
                existsOnDisk = false
                onDiskLooksBinary = false
            }
        } else if RemoteWorktreeFileAccess.isSymlink(at: url) {
            // A symlink's git-tracked "content" is its destination path
            // string, never the target's bytes — never binary in any
            // meaningful sense. `looksBinaryOnDisk` opens through the link
            // to sniff the TARGET's bytes, which could otherwise leak
            // whether an ignored/secret target looks binary; short-circuit
            // before ever following it.
            existsOnDisk = true
            onDiskLooksBinary = false
        } else {
            existsOnDisk = FileManager.default.fileExists(atPath: url.path)
            onDiskLooksBinary = await RemoteWorktreeFileAccess.looksBinaryOnDisk(at: url)
        }
        if onDiskLooksBinary { return true }
        if existsOnDisk { return false }
        if missingFileUsesIndex {
            return (try? await git.looksBinaryAtIndex(worktreePath: worktree.path, file: normalizedPath)) ?? false
        }
        guard let comparisonRef, !comparisonRef.isEmpty else { return false }
        return (try? await git.looksBinaryAtRef(worktreePath: worktree.path, ref: comparisonRef, file: normalizedPath)) ?? false
    }

    private static func remoteChangedFile(_ file: ChangedFile) -> RemoteChangedFile {
        RemoteChangedFile(
            path: file.path,
            status: file.status,
            add: file.add,
            del: file.del,
            conflict: file.conflict?.rawValue,
            renameFrom: file.renameFrom)
    }

    private static func remoteCommit(_ commit: CommitInfo) -> RemoteCommit {
        RemoteCommit(
            sha: commit.sha, shortSha: commit.shortSha, subject: commit.rawSubject, author: commit.author,
            add: commit.insertions, del: commit.deletions)
    }

    /// Drops ignored and excluded nodes at the wire boundary: the remote file
    /// browser is git-aware, so build output never reaches the phone.
    ///
    /// Runs the same recursive keep-if-has-visible-children pass
    /// `FileTreeListView.filteredNodes` uses for the native desktop Files tab
    /// (`FileTreeNode.filteredKeepingVisibleDescendants`) BEFORE the flat
    /// wire projection below: a directory can be individually marked
    /// `.ignored`/`.excluded` while still holding a tracked (force-added)
    /// descendant, and `RemoteFileNode` carries no `children` field, so once
    /// such a directory is dropped from its parent's listing the client can
    /// never issue the `listFiles` request that would reveal the descendant.
    /// This only helps when `nodes` actually has real, eagerly-populated
    /// `children` for the directory in question — true for
    /// `GitService.fileTree`'s LOCAL-worktree root scan (which builds full
    /// nested children for exactly this case), but NOT for
    /// `GitService.fileTreeChildren`'s single-level, on-demand directory
    /// expansion, which by design never populates nested `children` beyond
    /// the one level requested. A nested ignored directory with a tracked
    /// descendant one or more levels below an on-demand `fileTreeChildren`
    /// expansion can therefore remain unreachable — a known, narrower gap
    /// than the one this fixes.
    private static func remoteFileNodes(_ nodes: [FileTreeNode]) -> [RemoteFileNode] {
        FileTreeNode.filteredKeepingVisibleDescendants(nodes).map { node in
            RemoteFileNode(
                name: node.name,
                path: node.path,
                kind: node.kind.rawValue,
                badge: node.badge,
                childrenState: node.childrenState.rawValue,
                isSubmodule: node.isSubmodule)
        }
    }

    @_spi(Testing) public func remoteChangeList(
        sessionId: String,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode? = nil
    ) async -> RemoteChangeListResult {
        await remoteChangeList(in: remoteWorktreeContext(sessionId: sessionId), comparisonMode: comparisonMode)
    }

    private func remoteChangeList(
        in context: RemoteWorktreeContextResult,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) async -> RemoteChangeListResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown:
            return .failure(reason: .sessionUnknown, message: nil)
        case .worktreeUnavailable:
            return .failure(reason: .worktreeUnavailable, message: nil)
        case .found(let w):
            worktree = w
        }
        // A folder has no git and so no changes; answer empty rather than fail.
        if isFolderWorktree(worktree) {
            return .success(
                comparisonRef: nil, metricsAvailable: false,
                files: [], staged: [], unstaged: [], commits: [], truncated: false)
        }
        let git = GitService()
        do {
            let commits = try await git.commitsAhead(
                at: worktree.path,
                baseBranch: environment.configuration().worktrees.baseBranch,
                resolution: GitService.BaseResolution.forCommits(
                    mode: comparisonMode ?? environment.configuration().changes.comparisonMode,
                    userOverrodeBaseBranch: false
                ))
            let statusEntries = try await git.status(worktreePath: worktree.path)
            let changed = try await git.changedFilesAgainstRef(
                worktreePath: worktree.path, ref: commits.comparisonRef,
                knownStatusEntries: statusEntries)
            let capped = RemoteWorktreeFileAccess.truncateFiles(changed)
            let workingTree = try await git.statusForRemoteChangeList(
                worktreePath: worktree.path, knownStatusEntries: statusEntries)
            let cappedWorkingTree = RemoteWorktreeFileAccess.truncateFiles(workingTree)
            return .success(
                comparisonRef: commits.comparisonRef,
                metricsAvailable: true,
                files: capped.files.map(Self.remoteChangedFile),
                staged: cappedWorkingTree.files.filter { $0.stage == .staged }.map(Self.remoteChangedFile),
                unstaged: cappedWorkingTree.files.filter { $0.stage == .unstaged }.map(Self.remoteChangedFile),
                commits: commits.commits.prefix(100).map(Self.remoteCommit),
                truncated: capped.truncated || cappedWorkingTree.truncated,
                commitsTruncated: commits.commits.count > 100,
                workingTreeTruncated: cappedWorkingTree.truncated,
                // A failed read leaves the list without an operation rather than failing it.
                operation: try? await git.mergeState(worktreePath: worktree.path))
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    @_spi(Testing) public func remoteFileDiff(
        sessionId: String,
        path: String,
        stage: String? = nil,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode? = nil
    ) async -> RemoteFileDiffResult {
        await remoteFileDiff(
            in: remoteWorktreeContext(sessionId: sessionId), path: path, stage: stage, comparisonMode: comparisonMode)
    }

    private func remoteFileDiff(
        in context: RemoteWorktreeContextResult,
        path: String,
        stage: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) async -> RemoteFileDiffResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown:
            return .failure(reason: .sessionUnknown, message: nil)
        case .worktreeUnavailable:
            return .failure(reason: .worktreeUnavailable, message: nil)
        case .found(let w):
            worktree = w
        }
        guard let normalizedPath = RemoteWorktreeFileAccess.normalizedRelativePath(path),
              let url = RemoteWorktreeFileAccess.resolve(path: path, in: worktree.path)
        else {
            return .failure(reason: .pathRejected, message: nil)
        }
        // Unlike a direct content read, a symlink is safe to DIFF: git
        // tracks a symlink's blob as its destination path STRING, never
        // the target's content, and `git diff` reads that side via
        // `lstat`/`readlink` — it never opens through the link at the OS
        // level (verified empirically: a changed symlink's diff shows only
        // the old/new destination strings). So a tracked symlink whose own
        // name isn't ignored but whose target is (e.g. `public-env ->
        // .env`) can't leak the target's content through `git diff` itself
        // — the one place that WOULD leak it is the on-disk binary sniff
        // below, which `isDiffTargetBinary` guards against by special-
        // casing a symlink path before ever following it.
        let git = GitService()
        do {
            let commits = try await git.commitsAhead(
                at: worktree.path,
                baseBranch: environment.configuration().worktrees.baseBranch,
                resolution: GitService.BaseResolution.forCommits(
                    mode: comparisonMode ?? environment.configuration().changes.comparisonMode,
                    userOverrodeBaseBranch: false
                ))
            // Threading `comparisonRef` through lets `isPathIgnored` exempt a
            // path that existed there even though it's since been deleted —
            // otherwise a deleted, gitignore-pattern-matching file's
            // legitimate deletion diff (shown correctly with status `D` in
            // the Changes list) gets wrongly rejected as `.pathRejected`,
            // because a deleted path is no longer in the current index for
            // `check-ignore` to exempt the way a force-added tracked file is.
            let ignored = try await git.isPathIgnored(
                worktreePath: worktree.path, path: normalizedPath, comparisonRef: commits.comparisonRef)
            if ignored {
                return .failure(reason: .pathRejected, message: nil)
            }
            let changeStage: ChangeStage?
            if let stage {
                guard let parsedStage = ChangeStage(rawValue: stage) else {
                    return .failure(reason: .pathRejected, message: nil)
                }
                changeStage = parsedStage
            } else {
                changeStage = nil
            }
            if changeStage != .staged, await isDiffTargetBinary(
                worktree: worktree, normalizedPath: normalizedPath, url: url,
                comparisonRef: commits.comparisonRef, git: git,
                missingFileUsesIndex: changeStage == .unstaged
            ) {
                return .failure(reason: .binary, message: nil)
            }
            let parsed: ParsedDiff
            if let changeStage {
                let statusEntry = try await git.statusIdentity(worktreePath: worktree.path).first { $0.path == normalizedPath }
                parsed = try await git.remoteDiff(
                    worktreePath: worktree.path, file: normalizedPath,
                    staged: changeStage == .staged, originalPath: statusEntry?.renameFrom,
                    maxOutputBytes: RemoteWorktreeFileAccess.maxDiffSubprocessBytes,
                    conflicted: statusEntry?.conflict != nil)
            } else {
                parsed = try await git.diff(
                    worktreePath: worktree.path,
                    againstRef: commits.comparisonRef,
                    file: normalizedPath)
            }
            // `isDiffTargetBinary` above only sniffs byte content, which
            // misses a file declared binary purely via `.gitattributes`
            // (e.g. `*.dat binary`) whose bytes happen to still look like
            // valid UTF-8. Catch that case here instead: git's OWN binary
            // classification survives into `parsed.isBinary`, detected from
            // the raw `Binary files ... differ` line before hunk parsing
            // discarded it — so a hunk-less result from this specific
            // reason reports `.binary` rather than a misleading empty
            // "successful" diff.
            guard !parsed.isBinary else {
                return .failure(reason: .binary, message: nil)
            }
            let capped = RemoteWorktreeFileAccess.truncateHunks(parsed.hunks)
            return .success(
                hunks: capped.hunks.map(RemoteDiffHunk.init),
                truncated: capped.truncated,
                metadataNote: parsed.metadataSummary)
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    @_spi(Testing) public func remoteCommitFiles(sessionId: String, sha: String) async -> RemoteCommitFilesResult {
        await remoteCommitFiles(in: remoteWorktreeContext(sessionId: sessionId), sha: sha)
    }

    private func remoteCommitFiles(in context: RemoteWorktreeContextResult, sha: String) async -> RemoteCommitFilesResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown: return .failure(reason: .sessionUnknown, message: nil)
        case .worktreeUnavailable: return .failure(reason: .worktreeUnavailable, message: nil)
        case .found(let found): worktree = found
        }
        guard RemoteWorktreeFileAccess.isCommitSHA(sha) else {
            return .failure(reason: .pathRejected, message: nil)
        }
        do {
            let details = try await GitService().commitDetails(at: worktree.path, sha: sha)
            let files = details.files.filter {
                RemoteWorktreeFileAccess.normalizedRelativePath($0.path) != nil
            }
            return .success(files: files.prefix(RemoteWorktreeFileAccess.maxChangedFiles).map {
                RemoteChangedFile(path: $0.path, status: $0.status, add: $0.add, del: $0.del,
                                  conflict: nil, renameFrom: $0.originalPath)
            }, truncated: files.count > RemoteWorktreeFileAccess.maxChangedFiles)
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    @_spi(Testing) public func remoteCommitDiff(sessionId: String, sha: String, path: String) async -> RemoteFileDiffResult {
        await remoteCommitDiff(in: remoteWorktreeContext(sessionId: sessionId), sha: sha, path: path)
    }

    private func remoteCommitDiff(in context: RemoteWorktreeContextResult, sha: String, path: String) async -> RemoteFileDiffResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown: return .failure(reason: .sessionUnknown, message: nil)
        case .worktreeUnavailable: return .failure(reason: .worktreeUnavailable, message: nil)
        case .found(let found): worktree = found
        }
        guard RemoteWorktreeFileAccess.isCommitSHA(sha),
              let normalizedPath = RemoteWorktreeFileAccess.normalizedRelativePath(path) else {
            return .failure(reason: .pathRejected, message: nil)
        }
        do {
            let git = GitService()
            let details = try await git.commitDetails(at: worktree.path, sha: sha)
            guard let file = details.files.first(where: { $0.path == normalizedPath }) else {
                return .failure(reason: .pathRejected, message: nil)
            }
            // Both sides are git blobs. Deleted paths and historical symlinks
            // need no filesystem resolution or working-tree binary sniff.
            let parsed = try await git.diff(worktreePath: worktree.path, sha: details.info.sha,
                file: normalizedPath, originalPath: file.originalPath,
                maxOutputBytes: RemoteWorktreeFileAccess.maxDiffSubprocessBytes)
            guard !parsed.isBinary else { return .failure(reason: .binary, message: nil) }
            let capped = RemoteWorktreeFileAccess.truncateHunks(parsed.hunks)
            return .success(hunks: capped.hunks.map(RemoteDiffHunk.init),
                            truncated: capped.truncated, metadataNote: parsed.metadataSummary)
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    @_spi(Testing) public func remoteRangeFiles(sessionId: String, base: String, head: String, threeDot: Bool) async -> RemoteCommitFilesResult {
        await remoteRangeFiles(in: remoteWorktreeContext(sessionId: sessionId), base: base, head: head, threeDot: threeDot)
    }

    private func remoteRangeFiles(
        in context: RemoteWorktreeContextResult, base: String, head: String, threeDot: Bool
    ) async -> RemoteCommitFilesResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown: return .failure(reason: .sessionUnknown, message: nil)
        case .worktreeUnavailable: return .failure(reason: .worktreeUnavailable, message: nil)
        case .found(let found): worktree = found
        }
        guard Self.isRangeEnd(base, allowingRootParent: true), Self.isRangeEnd(head, allowingRootParent: false) else {
            return .failure(reason: .pathRejected, message: nil)
        }
        do {
            let git = GitService()
            let range = try await Self.verifiedRange(base: base, head: head, threeDot: threeDot, at: worktree.path, git: git)
            let files = try await git.rangeChangedFiles(at: worktree.path, base: range.base, head: range.head, threeDot: threeDot)
                .filter { RemoteWorktreeFileAccess.normalizedRelativePath($0.path) != nil }
            return .success(files: files.prefix(RemoteWorktreeFileAccess.maxChangedFiles).map {
                RemoteChangedFile(path: $0.path, status: $0.status, add: $0.add, del: $0.del,
                                  conflict: nil, renameFrom: $0.originalPath)
            }, truncated: files.count > RemoteWorktreeFileAccess.maxChangedFiles)
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    @_spi(Testing) public func remoteRangeDiff(
        sessionId: String, base: String, head: String, threeDot: Bool, path: String, originalPath: String?
    ) async -> RemoteFileDiffResult {
        await remoteRangeDiff(
            in: remoteWorktreeContext(sessionId: sessionId), base: base, head: head, threeDot: threeDot,
            path: path, originalPath: originalPath)
    }

    private func remoteRangeDiff(
        in context: RemoteWorktreeContextResult, base: String, head: String, threeDot: Bool,
        path: String, originalPath: String?
    ) async -> RemoteFileDiffResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown: return .failure(reason: .sessionUnknown, message: nil)
        case .worktreeUnavailable: return .failure(reason: .worktreeUnavailable, message: nil)
        case .found(let found): worktree = found
        }
        let normalizedOriginal = originalPath.map(RemoteWorktreeFileAccess.normalizedRelativePath)
        guard Self.isRangeEnd(base, allowingRootParent: true), Self.isRangeEnd(head, allowingRootParent: false),
              let normalizedPath = RemoteWorktreeFileAccess.normalizedRelativePath(path),
              normalizedOriginal != .some(nil) else {
            return .failure(reason: .pathRejected, message: nil)
        }
        do {
            let git = GitService()
            let range = try await Self.verifiedRange(base: base, head: head, threeDot: threeDot, at: worktree.path, git: git)
            let revisions = try await git.resolvedRangeTrees(
                worktreePath: worktree.path, base: range.base, head: range.head, threeDot: threeDot)
            // Both sides are git blobs, as for a commit diff.
            let parsed = try await git.rangeDiff(
                worktreePath: worktree.path, revisions: revisions, file: normalizedPath,
                originalPath: normalizedOriginal ?? nil,
                maxOutputBytes: RemoteWorktreeFileAccess.maxDiffSubprocessBytes)
            guard !parsed.isBinary else { return .failure(reason: .binary, message: nil) }
            let capped = RemoteWorktreeFileAccess.truncateHunks(parsed.hunks)
            return .success(hunks: capped.hunks.map(RemoteDiffHunk.init),
                            truncated: capped.truncated, metadataNote: parsed.metadataSummary)
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    /// A client's range end: a commit SHA, or for a base `<sha>^`, which
    /// `resolveTwoDotLeftTree` reads as the empty tree for a root commit.
    private static func isRangeEnd(_ ref: String, allowingRootParent: Bool) -> Bool {
        RemoteWorktreeFileAccess.isCommitSHA(allowingRootParent && ref.hasSuffix("^") ? String(ref.dropLast()) : ref)
    }

    /// The range with each end resolved to a commit of this repository, so
    /// git is never handed an object the client named but the repo lacks.
    /// A two-dot base may also be the empty tree, which a review from a root
    /// commit stores as its base.
    private static func verifiedRange(
        base: String, head: String, threeDot: Bool, at worktree: URL, git: GitService
    ) async throws -> (base: String, head: String) {
        if !threeDot, base == "4b825dc642cb6eb9a060e54bf8d69288fbee4904" {
            return (base, try await git.resolveRevision(at: worktree, ref: head))
        }
        let parentOfBase = base.hasSuffix("^")
        let baseCommit = try await git.resolveRevision(at: worktree, ref: parentOfBase ? String(base.dropLast()) : base)
        return (parentOfBase ? baseCommit + "^" : baseCommit, try await git.resolveRevision(at: worktree, ref: head))
    }

    @_spi(Testing) public func remoteFileTree(
        sessionId: String,
        path: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode? = nil
    ) async -> RemoteFileTreeResult {
        await remoteFileTree(in: remoteWorktreeContext(sessionId: sessionId), path: path, comparisonMode: comparisonMode)
    }

    private func remoteFileTree(
        in context: RemoteWorktreeContextResult,
        path: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) async -> RemoteFileTreeResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown:
            return .failure(reason: .sessionUnknown, message: nil)
        case .worktreeUnavailable:
            return .failure(reason: .worktreeUnavailable, message: nil)
        case .found(let w):
            worktree = w
        }
        let git = GitService()
        do {
            // Base-relative (against `comparisonRef`), matching the Changes
            // tab — not working-tree/index `status()` — so a file with
            // committed-but-not-working-tree-dirty changes (a clean
            // checkout of a branch with real commits on it, the common
            // case for reviewing an agent's finished work) still shows the
            // same badge here that Changes already reports for it, instead
            // of appearing unbadged just because `status()` alone has
            // nothing to say about it. `changedFileBadges` (not
            // `changedFilesAgainstRef`) — this endpoint only needs a badge
            // letter per path, and computing full add/del metrics (a local
            // untracked file read whole, or a remote line-count round trip)
            // on every `listFiles` request, for the root AND every
            // directory a client expands, did substantial repeated I/O for
            // numbers nothing here displays.
            // A folder has no git: list the filesystem, with no change badges.
            let isFolder = isFolderWorktree(worktree)
            let changedEntries: [ChangedFile]
            if isFolder {
                changedEntries = []
            } else {
                let commits = try await git.commitsAhead(
                    at: worktree.path,
                    baseBranch: environment.configuration().worktrees.baseBranch,
                    resolution: GitService.BaseResolution.forCommits(
                        mode: comparisonMode ?? environment.configuration().changes.comparisonMode,
                        userOverrodeBaseBranch: false
                    ))
                changedEntries = try await git.changedFileBadges(
                    worktreePath: worktree.path, ref: commits.comparisonRef)
            }

            guard let path, !path.isEmpty else {
                let nodes = isFolder
                    ? try await git.plainDirectoryChildren(worktreePath: worktree.path, path: "")
                    : try await git.fileTree(worktreePath: worktree.path, statusEntries: changedEntries)
                let capped = RemoteWorktreeFileAccess.truncateFileNodes(Self.remoteFileNodes(nodes))
                return .success(nodes: capped.nodes, truncated: capped.truncated)
            }
            guard let normalizedPath = RemoteWorktreeFileAccess.normalizedRelativePath(path),
                  RemoteWorktreeFileAccess.resolve(path: path, in: worktree.path) != nil
            else {
                return .failure(reason: .pathRejected, message: nil)
            }
            // `resolve` above only performs LOCAL symlink resolution and
            // containment checking — a no-op for a remote worktree, since
            // nothing exists at `worktree.path` on this Mac to escape from.
            // A symlink inside the SSH worktree that points outside it (or
            // at `.git`) would otherwise let a remote listing leak directory
            // names from anywhere on the remote host. Mirrors
            // `readRemoteWorktreeFileRaw`'s containment check for reads.
            if worktree.path.isRemoteAlasPath {
                guard let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path) else {
                    return .failure(reason: .gitFailed, message: "Remote host is not registered for this worktree.")
                }
                do {
                    try await RemotePathContainment.verifyRemoteContainment(
                        host: host, path: normalizedPath, worktreeRoot: worktree.path.path)
                } catch RemotePathContainment.ContainmentError.outsideWorktree(_) {
                    return .failure(reason: .pathRejected, message: nil)
                } catch {
                    return .failure(reason: .gitFailed, message: error.localizedDescription)
                }
            }
            // Same badge source the ROOT branch above uses (`changedEntries`,
            // base-relative against `comparisonRef`), so a nested directory
            // expansion shows the same badges the root listing would if it
            // eagerly built this far — without this, `fileTreeChildren`
            // always built its nodes with `badges: [:]`, so any change in a
            // subdirectory lost its badge the moment a client expanded into
            // that directory.
            let badges = Dictionary(
                changedEntries.map { ($0.path, $0.status) }, uniquingKeysWith: { first, _ in first })
            let nodes = isFolder
                ? try await git.plainDirectoryChildren(worktreePath: worktree.path, path: path)
                : try await git.fileTreeChildren(worktreePath: worktree.path, path: path, badges: badges)
            let capped = RemoteWorktreeFileAccess.truncateFileNodes(Self.remoteFileNodes(nodes))
            return .success(nodes: capped.nodes, truncated: capped.truncated)
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    @_spi(Testing) public func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult {
        await remoteFileContents(in: remoteWorktreeContext(sessionId: sessionId), path: path)
    }

    private func remoteFileContents(in context: RemoteWorktreeContextResult, path: String) async -> RemoteFileContentsResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown:
            return .failure(reason: .sessionUnknown, byteSize: nil, message: nil)
        case .worktreeUnavailable:
            return .failure(reason: .worktreeUnavailable, byteSize: nil, message: nil)
        case .found(let w):
            worktree = w
        }
        guard let normalizedPath = RemoteWorktreeFileAccess.normalizedRelativePath(path),
              let url = RemoteWorktreeFileAccess.resolve(path: path, in: worktree.path)
        else {
            return .failure(reason: .pathRejected, byteSize: nil, message: nil)
        }
        // See the matching comment in `remoteFileDiff`: a tracked symlink
        // whose alias name isn't itself ignored can still point at an
        // ignored (or otherwise off-limits) target. `readFileContents`
        // below rejects a symlink itself (`O_NOFOLLOW` in its single
        // open/fstat/read sequence), but this earlier, cheaper check lets
        // the request fail fast with the right reason before doing the
        // ignore-check git call at all.
        if !worktree.path.isRemoteAlasPath, RemoteWorktreeFileAccess.isSymlink(at: url) {
            return .failure(reason: .notFound, byteSize: nil, message: nil)
        }
        do {
            // A folder has no ignore rules, and its tree lists every file.
            let ignored = isFolderWorktree(worktree)
                ? false
                : try await GitService().isPathIgnored(worktreePath: worktree.path, path: normalizedPath)
            if ignored {
                return .failure(reason: .pathRejected, byteSize: nil, message: nil)
            }
        } catch {
            return .failure(reason: .gitFailed, byteSize: nil, message: error.localizedDescription)
        }

        if worktree.path.isRemoteAlasPath {
            guard let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path) else {
                return .failure(
                    reason: .gitFailed, byteSize: nil,
                    message: "Remote host is not registered for this worktree.")
            }
            switch await readRemoteWorktreeFileRaw(host: host, worktreeRoot: worktree.path.path, relativePath: normalizedPath) {
            case .containmentRejected:
                return .failure(reason: .pathRejected, byteSize: nil, message: nil)
            case .notFound:
                return .failure(reason: .notFound, byteSize: nil, message: nil)
            case .unreadable(let detail):
                return .failure(reason: .gitFailed, byteSize: nil, message: detail)
            case .tooLarge(let byteSize):
                return .failure(reason: .tooLarge, byteSize: byteSize, message: nil)
            case .data(let data):
                guard data.count <= RemoteWorktreeFileAccess.maxFileBytes else {
                    return .failure(reason: .tooLarge, byteSize: data.count, message: nil)
                }
                guard !GitService.looksBinary(data) else {
                    return .failure(reason: .binary, byteSize: data.count, message: nil)
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    return .failure(reason: .binary, byteSize: data.count, message: nil)
                }
                return .success(text: text, truncated: false)
            }
        }

        let (outcome, version) = await RemoteWorktreeFileAccess.readVersionedFileContents(at: url)
        switch outcome {
        case .notFound:
            return .failure(reason: .notFound, byteSize: nil, message: nil)
        case .tooLarge(let byteSize):
            return .failure(reason: .tooLarge, byteSize: byteSize, message: nil)
        case .binary(let byteSize):
            return .failure(reason: .binary, byteSize: byteSize, message: nil)
        case .text(let text):
            // A Mac opens a file editable only with a version: none for one a save would refuse.
            let writable = (try? Self.writableLocation(normalizedPath, in: worktree.path).get()) != nil
            return .success(text: text, truncated: false, version: writable ? version : nil)
        }
    }

    @_spi(Testing) public func remoteFileBytes(sessionId: String, path: String, revision: HostFileRevision?) async -> RemoteFileBytesResult {
        await remoteFileBytes(in: remoteWorktreeContext(sessionId: sessionId), path: path, revision: revision)
    }

    /// A file's raw bytes for a preview, under the text read's path rules
    /// but with no binary or UTF-8 gate: the working tree's when `revision`
    /// is nil, else the blob at that revision, refused over `maxBytes`
    /// before it is read.
    func remoteFileBytes(
        in context: RemoteWorktreeContextResult, path: String, revision: HostFileRevision?,
        maxBytes: Int = RemoteWorktreeFileAccess.maxPreviewBytes
    ) async -> RemoteFileBytesResult {
        let worktree: Worktree
        switch context {
        case .sessionUnknown: return .failure(reason: .sessionUnknown, byteSize: nil, message: nil)
        case .worktreeUnavailable: return .failure(reason: .worktreeUnavailable, byteSize: nil, message: nil)
        case .found(let found): worktree = found
        }
        guard let normalizedPath = RemoteWorktreeFileAccess.normalizedRelativePath(path),
              let url = RemoteWorktreeFileAccess.resolve(path: path, in: worktree.path)
        else {
            return .failure(reason: .pathRejected, byteSize: nil, message: nil)
        }
        guard let revision else {
            return await remoteWorkingTreeBytes(worktree, normalizedPath: normalizedPath, url: url, maxBytes: maxBytes)
        }
        // A folder has no history; and a control character could end the batch request below.
        guard !isFolderWorktree(worktree),
              !normalizedPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            return .failure(reason: .pathRejected, byteSize: nil, message: nil)
        }
        let git = GitService()
        do {
            // Only the forms the diff reads use, and SHAs verified as commits here.
            let rev: String
            switch revision {
            case .index:
                rev = ""
            case .base(let comparisonMode):
                let commits = try await git.commitsAhead(
                    at: worktree.path,
                    baseBranch: environment.configuration().worktrees.baseBranch,
                    resolution: GitService.BaseResolution.forCommits(
                        mode: comparisonMode ?? environment.configuration().changes.comparisonMode,
                        userOverrodeBaseBranch: false
                    ))
                rev = commits.comparisonRef ?? "HEAD"
            case .commit(let sha), .parent(let sha):
                guard RemoteWorktreeFileAccess.isCommitSHA(sha) else {
                    return .failure(reason: .pathRejected, byteSize: nil, message: nil)
                }
                let commit: String
                do {
                    commit = try await git.resolveRevision(at: worktree.path, ref: sha)
                } catch let error as NSError where error.domain == "GitService.resolveRevision" {
                    // git ran and names no such commit; anything else failed to run.
                    return .failure(reason: .pathRejected, byteSize: nil, message: nil)
                }
                rev = revision == .commit(sha: sha) ? commit : commit + "^"
            }
            // As diffs do, a path ignored now is still read where it is tracked.
            if try await git.isPathIgnored(worktreePath: worktree.path, path: normalizedPath, comparisonRef: rev) {
                return .failure(reason: .pathRejected, byteSize: nil, message: nil)
            }
            // `./` keeps the path a path, relative to the worktree root.
            let check = try await Process.git(
                ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
                cwd: worktree.path, stdin: "\(rev):./\(normalizedPath)\n")
            guard check.exitCode == 0 else {
                return .failure(reason: .gitFailed, byteSize: nil, message: check.stderr)
            }
            // A missing object answers `<name> missing` on a clean exit.
            let fields = check.stdout.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count == 3, fields[1] == "blob", let byteSize = Int(fields[2]) else {
                return .failure(reason: .notFound, byteSize: nil, message: nil)
            }
            guard byteSize <= maxBytes else { return .failure(reason: .tooLarge, byteSize: byteSize, message: nil) }
            // `cat-file blob` by id: the stored bytes, with no textconv.
            let blob = try await Process.gitData(["cat-file", "blob", fields[0]], cwd: worktree.path)
            guard blob.exitCode == 0 else {
                return .failure(reason: .gitFailed, byteSize: nil, message: blob.stderr)
            }
            return .success(data: blob.stdout)
        } catch {
            return .failure(reason: .gitFailed, byteSize: nil, message: error.localizedDescription)
        }
    }

    /// The working-tree file's bytes, through `remoteFileContents`'s path chain.
    private func remoteWorkingTreeBytes(
        _ worktree: Worktree, normalizedPath: String, url: URL, maxBytes: Int
    ) async -> RemoteFileBytesResult {
        if !worktree.path.isRemoteAlasPath, RemoteWorktreeFileAccess.isSymlink(at: url) {
            return .failure(reason: .notFound, byteSize: nil, message: nil)
        }
        do {
            let ignored = isFolderWorktree(worktree)
                ? false
                : try await GitService().isPathIgnored(worktreePath: worktree.path, path: normalizedPath)
            if ignored { return .failure(reason: .pathRejected, byteSize: nil, message: nil) }
        } catch {
            return .failure(reason: .gitFailed, byteSize: nil, message: error.localizedDescription)
        }
        if worktree.path.isRemoteAlasPath {
            guard let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path) else {
                return .failure(reason: .gitFailed, byteSize: nil, message: "Remote host is not registered for this worktree.")
            }
            switch await readRemoteWorktreeFileRaw(
                host: host, worktreeRoot: worktree.path.path, relativePath: normalizedPath, maxBytes: maxBytes
            ) {
            case .containmentRejected: return .failure(reason: .pathRejected, byteSize: nil, message: nil)
            case .notFound: return .failure(reason: .notFound, byteSize: nil, message: nil)
            case .unreadable(let detail): return .failure(reason: .gitFailed, byteSize: nil, message: detail)
            case .tooLarge(let byteSize): return .failure(reason: .tooLarge, byteSize: byteSize, message: nil)
            case .data(let data):
                guard data.count <= maxBytes else { return .failure(reason: .tooLarge, byteSize: data.count, message: nil) }
                return .success(data: data)
            }
        }
        switch await RemoteWorktreeFileAccess.probeVersion(at: url, maxBytes: maxBytes) {
        case .missing: return .failure(reason: .notFound, byteSize: nil, message: nil)
        case .tooLarge(let byteSize): return .failure(reason: .tooLarge, byteSize: byteSize, message: nil)
        case .version(_, let data): return .success(data: data)
        }
    }

    /// The message a session in `worktree` would get for `read`, answered as
    /// `id`: the session path's own mapping, over the worktree's reads.
    @_spi(Testing) public func remoteRead(_ read: HostWorktreeRead, in worktree: Worktree, replyingAs id: String) async -> RemoteServerMessage {
        await WorktreeInspection(core: self, worktree: worktree).remoteRead(read, sessionId: id)
    }

    /// Reads one worktree whatever session it is asked about.
    private final class WorktreeInspection: RemoteWorktreeInspecting {
        let core: AlasCoreContext
        let worktree: Worktree

        init(core: AlasCoreContext, worktree: Worktree) {
            self.core = core
            self.worktree = worktree
        }

        func remoteChangeList(sessionId _: String, comparisonMode: AppConfig.Changes.ChangesComparisonMode?) async -> RemoteChangeListResult {
            await core.remoteChangeList(in: .found(worktree), comparisonMode: comparisonMode)
        }
        func remoteFileDiff(
            sessionId _: String, path: String, stage: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?
        ) async -> RemoteFileDiffResult {
            await core.remoteFileDiff(in: .found(worktree), path: path, stage: stage, comparisonMode: comparisonMode)
        }
        func remoteFileTree(sessionId _: String, path: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?) async -> RemoteFileTreeResult {
            await core.remoteFileTree(in: .found(worktree), path: path, comparisonMode: comparisonMode)
        }
        func remoteCommitFiles(sessionId _: String, sha: String) async -> RemoteCommitFilesResult {
            await core.remoteCommitFiles(in: .found(worktree), sha: sha)
        }
        func remoteCommitDiff(sessionId _: String, sha: String, path: String) async -> RemoteFileDiffResult {
            await core.remoteCommitDiff(in: .found(worktree), sha: sha, path: path)
        }
        func remoteFileContents(sessionId _: String, path: String) async -> RemoteFileContentsResult {
            await core.remoteFileContents(in: .found(worktree), path: path)
        }
        func remoteFileBytes(sessionId _: String, path: String, revision: HostFileRevision?) async -> RemoteFileBytesResult {
            await core.remoteFileBytes(in: .found(worktree), path: path, revision: revision)
        }
        func remoteRangeFiles(sessionId _: String, base: String, head: String, threeDot: Bool) async -> RemoteCommitFilesResult {
            await core.remoteRangeFiles(in: .found(worktree), base: base, head: head, threeDot: threeDot)
        }
        func remoteRangeDiff(
            sessionId _: String, base: String, head: String, threeDot: Bool, path: String, originalPath: String?
        ) async -> RemoteFileDiffResult {
            await core.remoteRangeDiff(
                in: .found(worktree), base: base, head: head, threeDot: threeDot, path: path, originalPath: originalPath)
        }
    }

    /// The project and listed worktree with id `id`.
    func projectAndWorktree(withWorktreeId id: String) -> (project: ProjectConfig, worktree: Worktree)? {
        for project in projects.projects {
            if let worktree = projects.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return (project, worktree)
            }
        }
        return nil
    }

    func isFolderWorktree(_ worktree: Worktree) -> Bool {
        projects.projects.first { $0.id == worktree.projectId }?.isFolder == true
    }
}

extension RemoteDiffHunk {
    init(_ hunk: ParsedDiff.Hunk) {
        self.init(
            header: hunk.header,
            oldStart: hunk.oldStart,
            newStart: hunk.newStart,
            lines: hunk.lines.map { line in
                let kind: String
                switch line.kind {
                case .context: kind = "context"
                case .add: kind = "add"
                case .delete: kind = "delete"
                }
                return RemoteDiffLine(
                    kind: kind, text: line.text,
                    oldNumber: line.oldNumber, newNumber: line.newNumber,
                    noTrailingNewline: line.noTrailingNewline)
            })
    }
}
