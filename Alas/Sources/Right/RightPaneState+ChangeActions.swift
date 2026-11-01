import AppKit
import Foundation
import Observation
import os

extension RightPaneState {
    func requestDiscardFile(path: String) {
        guard !checkpointMutationsDisabled else { return }
        let paths = ChangedFile.discardPaths(forFileAt: path, in: changes)
        guard !paths.isEmpty else { return }
        pendingDiscard = PendingDiscard(target: .file(path: path), paths: paths)
    }

    func requestDiscardFolder(path: String) {
        guard !checkpointMutationsDisabled else { return }
        let paths = ChangedFile.discardPaths(forFolderAt: path, in: changes)
        // Folder count = distinct ChangedFile entries under the prefix, not
        // path count (a staged rename contributes two paths but one file).
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let fileCount = changes.filter { $0.path.hasPrefix(prefix) }.count
        guard fileCount > 0 else { return }
        pendingDiscard = PendingDiscard(
            target: .folder(path: path, fileCount: fileCount),
            paths: paths
        )
    }

    func requestDiscardAll() {
        guard !checkpointMutationsDisabled else { return }
        let paths = ChangedFile.discardPaths(forAllIn: changes)
        guard !changes.isEmpty else { return }
        pendingDiscard = PendingDiscard(
            target: .all(fileCount: changes.count),
            paths: paths
        )
    }

    func cancelDiscard() {
        pendingDiscard = nil
    }

    func cancelMerge() {
        pendingMerge = nil
    }

    func clearMergeError() {
        mergeError = nil
    }

    func clearMergeQueuedMessage() {
        mergeQueuedMessage = nil
    }

    static func mergeConfirmationMessage(for request: ReviewRequest?) -> String {
        guard let request else {
            return "Squash-merge this review request and delete the branch."
        }
        if request.isMergeQueueEnabled {
            return "Add \(request.displayIdentity) to the merge queue for \(request.baseRefName)."
        }
        return "Squash-merge \(request.displayIdentity) into \(request.baseRefName) and delete the branch."
    }

    func performMerge() {
        guard !checkpointMutationsDisabled else { return }
        guard let pending = pendingMerge else { return }
        pendingMerge = nil
        // Fast reject against the currently-cached snapshot (also re-validates
        // if the dialog captured a now-stale snapshot).
        guard let cached = reviewLoop.snapshot,
              ReviewReadinessModel.canMergeReviewRequest(snapshot: cached) else {
            mergeError = Self.mergeUnavailableMessage
            return
        }
        // The PR + head the user actually confirmed. After the forced refresh we
        // require the fresh snapshot to still be this exact request/head, so a
        // branch switch mid-dialog can't redirect the merge to a different PR.
        let confirmedRequestID = pending.reviewRequest?.id
        let confirmedHeadSHA = pending.reviewRequest?.headSHA
        guard reviewLoop.beginAction(.merge) else { return }
        Task { @MainActor in
            defer { reviewLoop.endAction(.merge) }
            // The cached snapshot can still lag reality: WorktreeWatcher
            // debounces change events up to ~2s, so a commit created just
            // before confirming may not have flipped `needsPush` yet. Force a
            // live refresh (recomputes HEAD/upstream + provider checks and
            // mergeability), then re-validate and merge the fresh snapshot.
            await refresh()
            guard let snapshot = reviewLoop.snapshot,
                  ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot),
                  snapshot.reviewRequest?.id == confirmedRequestID,
                  snapshot.reviewRequest?.headSHA == confirmedHeadSHA
            else {
                mergeError = Self.mergeUnavailableMessage
                return
            }
            // The generation-guarded refresh above can be superseded by a
            // concurrent watcher refresh and return without publishing, leaving
            // the snapshot stale. Do a final authoritative read straight from
            // git so a just-created commit or dirty tree can't slip through.
            guard let reviewedHead = snapshot.reviewRequest?.headSHA,
                  await localHeadIsCleanlyAt(reviewedHead)
            else {
                mergeError = Self.mergeUnavailableMessage
                return
            }
            switch await reviewLoop.merge(snapshot: snapshot) {
            case .merged:
                await refresh(forceReviewLoopRemote: true)
            case .queued:
                mergeQueuedMessage = "Added to merge queue."
                await refresh(forceReviewLoopRemote: true)
            case nil:
                mergeError = reviewLoop.lastError ?? "Merge failed."
            }
        }
    }

    /// Authoritative, point-in-time check that the worktree HEAD is exactly the
    /// reviewed head and the tree is clean — read straight from git, not via the
    /// review-loop refresh (whose generation guard lets a concurrent watcher
    /// refresh supersede the merge-triggered one without publishing).
    private func localHeadIsCleanlyAt(_ reviewedHeadSHA: String) async -> Bool {
        guard let head = try? await Process.git(["rev-parse", "HEAD"], cwd: worktree.path),
              head.exitCode == 0,
              head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == reviewedHeadSHA
        else { return false }
        guard let status = try? await Process.git(["status", "--porcelain"], cwd: worktree.path),
              status.exitCode == 0
        else { return false }
        return status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Merge failures are surfaced via an app-level alert (hosted in RootView
    // next to the confirmation dialog) rather than `sidebarError`, because a
    // merge can be launched from the Review tab in the center pane while the
    // right pane — the only place `sidebarError` renders — is collapsed.
    private static let mergeUnavailableMessage =
        "Merge is no longer available — the branch or review state changed."

    func requestCherryPick(sha: String) {
        guard !checkpointMutationsDisabled else { return }
        pendingCherryPickSHA = sha
    }

    func cancelCherryPick() {
        pendingCherryPickSHA = nil
    }

    func confirmCherryPick() {
        guard !checkpointMutationsDisabled else { return }
        guard let sha = pendingCherryPickSHA else { return }
        pendingCherryPickSHA = nil
        runCherryPick(sha: sha)
    }

    @MainActor
    func confirmDiscard() async {
        guard let pending = pendingDiscard else { return }
        pendingDiscard = nil
        await runDiscard(pending)
    }

    /// Run a previously-snapshotted discard. Used by view-layer callers that
    /// need to capture and clear `pendingDiscard` synchronously in the alert
    /// button action — the alert's `isPresented` binding fires its `set`
    /// closure synchronously on dismissal, which would clear `pendingDiscard`
    /// before the async `confirmDiscard()` could read it.
    @MainActor
    func confirmDiscard(_ pending: PendingDiscard) async {
        // Defensive: if the caller didn't clear `pendingDiscard`, do it now.
        if pendingDiscard == pending { pendingDiscard = nil }
        await runDiscard(pending)
    }

    @MainActor
    private func runDiscard(_ pending: PendingDiscard) async {
        guard await checkpointMutationAllowedAfterJournalRevalidation() else { return }
        discardOperationInFlight = true
        defer { discardOperationInFlight = false }
        let paths = pending.paths
        sidebarError = nil
        do {
            try await git.discardPaths(worktreePath: worktree.path, files: paths)
        } catch {
            sidebarError = (error as NSError).localizedDescription
            return
        }
        await refresh()
        let remainingChangedPaths = Set(changes.flatMap(\.gitPaths))
        let cleanPaths = paths.filter { !remainingChangedPaths.contains($0) }
        if !cleanPaths.isEmpty {
            closeDiffTabs?(cleanPaths)
        }
    }

    func requestStashChanges() {
        guard !changes.isEmpty, mergeOp.current == nil, !stashOperationInFlight, !checkpointMutationsDisabled else { return }
        pendingStashChanges = true
    }

    func cancelStashChanges() {
        pendingStashChanges = false
    }

    func stashChanges(message: String, includeUntracked: Bool) {
        guard pendingStashChanges, !stashOperationInFlight, !checkpointMutationsDisabled else { return }
        pendingStashChanges = false
        stashOperationInFlight = true
        sidebarError = nil
        Task { @MainActor in
            defer { self.stashOperationInFlight = false }
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let result = try await self.git.pushStash(
                    worktreePath: self.worktree.path,
                    message: message,
                    includeUntracked: includeUntracked
                )
                await self.refresh()
                self.handleStashOperationResult(result)
            } catch {
                self.sidebarError = error.localizedDescription
            }
        }
    }

    func toggleStashExpanded(_ stash: GitStash) {
        if expandedStashRefs.contains(stash.ref) {
            expandedStashRefs.remove(stash.ref)
        } else {
            expandedStashRefs.insert(stash.ref)
            loadFiles(for: stash)
        }
    }

    func loadFiles(for stash: GitStash) {
        guard stashFilesByRef[stash.ref] == nil, !loadingStashRefs.contains(stash.ref) else { return }
        let snapshotGeneration = snapshotInvalidationGeneration
        loadingStashRefs.insert(stash.ref)
        Task { @MainActor in
            defer { self.loadingStashRefs.remove(stash.ref) }
            do {
                let files = try await self.git.stashFiles(worktreePath: self.worktree.path, stash: stash)
                guard snapshotGeneration == self.snapshotInvalidationGeneration else { return }
                guard self.stashes.contains(where: { $0.ref == stash.ref && $0.sha == stash.sha }) else { return }
                self.stashFilesByRef[stash.ref] = files
            } catch {
                guard snapshotGeneration == self.snapshotInvalidationGeneration else { return }
                self.sidebarError = error.localizedDescription
            }
        }
    }

    func applyStash(_ stash: GitStash) {
        guard !checkpointMutationsDisabled else { return }
        runStashOperation {
            try await self.git.applyStash(worktreePath: self.worktree.path, stash: stash)
        }
    }

    func popStash(_ stash: GitStash) {
        guard !checkpointMutationsDisabled else { return }
        runStashOperation {
            try await self.git.popStash(worktreePath: self.worktree.path, stash: stash)
        }
    }

    func requestDropStash(_ stash: GitStash) {
        pendingStashDrop = PendingStashDrop(stash: stash)
    }

    func cancelDropStash() {
        pendingStashDrop = nil
    }

    func confirmDropStash(_ pending: PendingStashDrop) {
        if pendingStashDrop == pending {
            pendingStashDrop = nil
        }
        guard !stashOperationInFlight, !checkpointMutationsDisabled else { return }
        stashOperationInFlight = true
        sidebarError = nil
        Task { @MainActor in
            defer { self.stashOperationInFlight = false }
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                try await self.git.dropStash(worktreePath: self.worktree.path, stash: pending.stash)
                await self.refresh()
            } catch {
                self.sidebarError = error.localizedDescription
            }
        }
    }

    func reconcileStashCaches(with newStashes: [GitStash]) {
        let previousSHAsByRef = Dictionary(uniqueKeysWithValues: stashes.map { ($0.ref, $0.sha) })
        let newSHAsByRef = Dictionary(uniqueKeysWithValues: newStashes.map { ($0.ref, $0.sha) })
        let stableRefs = Set(newSHAsByRef.compactMap { ref, sha in
            previousSHAsByRef[ref] == sha ? ref : nil
        })

        expandedStashRefs.formIntersection(stableRefs)
        stashFilesByRef = stashFilesByRef.filter { stableRefs.contains($0.key) }
    }

    private func runStashOperation(_ operation: @escaping @MainActor () async throws -> StashOperationResult) {
        guard !stashOperationInFlight, !checkpointMutationsDisabled else { return }
        stashOperationInFlight = true
        sidebarError = nil
        Task { @MainActor in
            defer { self.stashOperationInFlight = false }
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let result = try await operation()
                await self.refresh()
                self.handleStashOperationResult(result)
            } catch {
                self.sidebarError = error.localizedDescription
            }
        }
    }

    private func handleStashOperationResult(_ result: StashOperationResult) {
        switch result {
        case .clean:
            return
        case .conflict(let message), .error(let message):
            sidebarError = message
        }
    }

    /// Run `git diff HEAD -- <file>` (or `--cached` on unborn HEAD, or
    /// `/dev/null` for untracked) and put the unified-diff output on the
    /// general pasteboard. `renameFrom` is the staged-rename origin path
    /// (from `ChangedFile.renameFrom`); when present it's included in the
    /// pathspec so `git diff` emits the rename-from/rename-to header
    /// instead of an add-only patch. Best-effort: errors are surfaced via
    /// `sidebarError`. Single source of truth so the context menu and
    /// any future "Copy Diff" affordances agree.
    func copyDiff(for path: String, renameFrom: String? = nil) {
        let wt = worktree.path
        Task { @MainActor in
            do {
                // A staged deletion is *not* in the index (`ls-files` returns
                // non-zero) but IS in HEAD — falling back to `--no-index` for
                // that case yields an empty patch. Probe HEAD via `cat-file`
                // so staged D entries still route through HEAD-based diff.
                let inIndex = (try? await Process.git(
                    ["ls-files", "--error-unmatch", "--", path],
                    cwd: wt
                ))?.exitCode == 0
                let head = (try? await self.git.hasHead(worktreePath: wt)) ?? true
                let inHead: Bool
                if head {
                    inHead = (try? await Process.git(
                        ["cat-file", "-e", "HEAD:\(path)"],
                        cwd: wt
                    ))?.exitCode == 0
                } else {
                    inHead = false
                }
                // For staged renames, `git diff HEAD -- <new>` strips the
                // rename header (emits an add-only patch). Pass both paths
                // in the pathspec so the rename-from/rename-to header is
                // preserved. Only relevant when we're using a HEAD-based
                // diff; the rename concept doesn't apply to untracked or
                // unborn-HEAD cases.
                let extraPath: String? = (renameFrom?.isEmpty == false) ? renameFrom : nil
                let args: [String]
                if head, inIndex || inHead {
                    var a = ["diff", "--no-color", "HEAD", "--", path]
                    if let extraPath { a.append(extraPath) }
                    args = a
                } else if !head, inIndex {
                    // Unborn HEAD: staged-add — diff index vs empty tree.
                    args = ["diff", "--no-color", "--cached", "--", path]
                } else {
                    args = ["diff", "--no-color", "--no-index", "--", "/dev/null", path]
                }
                let result = try await Process.git(args, cwd: wt)
                // `--no-index` exits 1 when there ARE differences (the expected
                // case for an untracked file).
                if result.exitCode > 1 {
                    self.sidebarError = result.stderr
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(result.stdout, forType: .string)
            } catch {
                self.sidebarError = (error as NSError).localizedDescription
            }
        }
    }

    /// Append a gitignore pattern for `path` to `destination` and refresh
    /// the changes list. Idempotent at the service level — calling this for
    /// a pattern that already exists in the destination is a no-op.
    ///
    /// For `.infoExclude`, resolves the actual `info/exclude` path via
    /// `git rev-parse --git-path` so linked worktrees write to the
    /// per-worktree git dir (where `.git` is a gitfile, not a directory).
    func ignore(path: String, isDirectory: Bool, destination: IgnoreDestination) {
        let repoURL = worktree.path
        Task { @MainActor in
            do {
                let infoExcludeURL: URL?
                if destination == .infoExclude {
                    infoExcludeURL = try await resolveInfoExcludeURL(worktreePath: repoURL)
                } else {
                    infoExcludeURL = nil
                }
                _ = try GitIgnoreService.appendIgnore(
                    entryPath: path,
                    isDirectory: isDirectory,
                    destination: destination,
                    repoURL: repoURL,
                    infoExcludeURL: infoExcludeURL
                )
            } catch {
                logger.error("ignore failed for \(path, privacy: .public) in worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await self.refresh()
        }
    }

    /// Resolve the absolute URL of `info/exclude` for this worktree via
    /// `git rev-parse --git-path info/exclude`. Output is relative to the
    /// worktree path unless git emits an absolute path.
    private func resolveInfoExcludeURL(worktreePath: URL) async throws -> URL {
        let result = try await Process.git(
            ["rev-parse", "--git-path", "info/exclude"],
            cwd: worktreePath
        )
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") {
            // A remote git prints a host path; keep it off a same-path local twin.
            return URL(fileURLWithPath: RemotePath.virtualizing(raw, like: worktreePath.path))
        }
        return URL(fileURLWithPath: raw, relativeTo: worktreePath).standardizedFileURL
    }
}
