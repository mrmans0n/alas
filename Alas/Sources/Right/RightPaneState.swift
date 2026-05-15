import Foundation
import Observation
import os

enum RightPaneTab: String { case changes, files }

@Observable
@MainActor
final class RightPaneState {
    let worktree: Worktree
    var changes: [ChangedFile] = []
    var composer = CommitComposerState()
    var fileTree: [FileTreeNode] = []
    var loading: Bool = false
    var openPaths: Set<String> = []   // expanded directories in the tree

    // New in right-sidebar-refactor:
    var activeTab: RightPaneTab = .changes
    var commits: [CommitInfo] = []
    var comparisonRef: String? = nil
    var workingTreeExpanded: Bool = true
    var commitsExpanded: Bool = true

    // Older-history paging — populated lazily by `loadOlder()`.
    // Cleared (and `hasMoreOlder` reset to true) on any `refresh()`
    // that re-fetches `commits`, because the divergence cursor may
    // have moved.
    var olderCommits: [CommitInfo] = []
    var hasMoreOlder: Bool = true
    var isLoadingOlder: Bool = false

    /// `true` once `refresh()` has decided the initial `activeTab`. After
    /// that, the user's tab choice is sticky and refreshes leave it alone.
    private var didInitDefaultTab: Bool = false

    /// `var` so `RightPaneStore` can keep this in sync with
    /// `AppConfig.worktrees.baseBranch` when the user edits it in Settings,
    /// without throwing away the rest of the cached state.
    var baseBranch: String

    private let git = GitService()
    private let watcher: WorktreeWatcher
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "right-pane-state")

    init(worktree: Worktree, baseBranch: String) {
        self.worktree = worktree
        self.baseBranch = baseBranch
        self.watcher = WorktreeWatcher(path: worktree.path)
        watcher.onChange = { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func start() {
        watcher.start()
        Task { @MainActor in await self.refresh() }
    }

    func stop() { watcher.stop() }

    @MainActor
    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            // Any refresh re-anchors the older-history cursor; drop the
            // accumulated pages so we don't accidentally splice an old
            // page onto a new HEAD.
            self.olderCommits = []
            self.hasMoreOlder = true
            self.isLoadingOlder = false
            async let s = git.status(worktreePath: worktree.path)
            async let c = git.commitsAhead(at: worktree.path, baseBranch: baseBranch)
            let entries = try await s
            let tree = try await git.fileTree(worktreePath: worktree.path, statusEntries: entries)
            let (commits, ref) = try await c
            self.changes = entries
            self.fileTree = tree
            self.commits = commits
            self.comparisonRef = ref
            // Gate the Amend toggle: an unborn branch (no commits yet)
            // has nothing to amend. If the probe itself throws, default
            // to `true` so we never wrongly disable the control on a
            // transient git failure.
            self.composer.canAmend = (try? await git.hasHead(worktreePath: worktree.path)) ?? true

            // Smart first-open default: if there are no working-tree
            // changes AND no commits ahead of upstream, surface Files
            // instead of an empty Changes pane. A clean worktree with
            // ahead commits should stay on Changes so the Commits section
            // is visible. Applied exactly once; user toggles win thereafter.
            if !didInitDefaultTab {
                if entries.isEmpty && commits.isEmpty && !tree.isEmpty {
                    activeTab = .files
                }
                didInitDefaultTab = true
            }
        } catch {
            // Surface failures via os.Logger so they're visible in Console.app
            // and the unified log. The previous `print` here silently kept
            // `self.changes` at its last successful value, which presented as
            // an empty Changes pane when the very first refresh failed.
            logger.error("refresh failed for worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func toggleStage(_ file: ChangedFile) {
        composer.error = nil
        Task { @MainActor in
            do {
                if file.stage == .staged {
                    // For a staged rename, include the original path so both
                    // sides of the rename are restored to the working tree;
                    // otherwise the deletion of the old path remains staged.
                    try await git.unstage(worktreePath: worktree.path, files: Self.unstagePaths(for: file))
                } else {
                    try await git.stage(worktreePath: worktree.path, files: [file.path])
                }
            } catch {
                self.composer.error = (error as NSError).localizedDescription
            }
            await self.refresh()
        }
    }

    static func unstagePaths(for file: ChangedFile) -> [String] {
        if file.status == "R", let from = file.renameFrom, !from.isEmpty {
            return [file.path, from]
        }
        return [file.path]
    }

    func stageAll(_ files: [ChangedFile]) {
        let paths = files.map(\.path)
        composer.error = nil
        Task { @MainActor in
            do { try await git.stageAll(worktreePath: worktree.path, files: paths) }
            catch { self.composer.error = (error as NSError).localizedDescription }
            await self.refresh()
        }
    }

    func unstageAll(_ files: [ChangedFile]) {
        let paths = files.flatMap(Self.unstagePaths(for:))
        composer.error = nil
        Task { @MainActor in
            do { try await git.unstageAll(worktreePath: worktree.path, files: paths) }
            catch { self.composer.error = (error as NSError).localizedDescription }
            await self.refresh()
        }
    }

    // MARK: - Commit composer wiring

    /// Run an AI commit-message CLI with the staged diff + repo context as
    /// stdin and the user's prompt as `--prompt`. Cancellable via
    /// `cancelGenerate()` (or by re-calling `generate` — the new Task
    /// replaces the old). On success, populates `composer.subject`/`body`
    /// and expands the composer so the user sees the result.
    func generate(promptOverride: String, tool: CommitAITool) {
        guard let adapter = tool.makeAdapter() else { return }
        composer.error = nil
        composer.busy = true
        let wt = worktree.path
        let amend = composer.amend
        let base = self.baseBranch
        composer.generation = Task { @MainActor in
            defer { self.composer.busy = false }
            do {
                // Pull prior commit message when amending so the AI knows
                // it's rewriting, not adding. `headMessage` is throwing +
                // optional (nil = unborn HEAD). Flatten both into a single
                // optional — failure or unborn both mean "no prior".
                let priorMessage: GitService.HeadMessage?
                if amend {
                    priorMessage = (try? await self.git.headMessage(worktreePath: wt)) ?? nil
                } else {
                    priorMessage = nil
                }

                let diffResult = try await Process.git(
                    ["diff", "--cached", "--no-color"],
                    cwd: wt
                )
                let recentResult = try await Process.git(
                    ["log", "-3", "--pretty=format:%s"],
                    cwd: wt
                )
                let branchResult = try await Process.git(
                    ["rev-parse", "--abbrev-ref", "HEAD"],
                    cwd: wt
                )

                try Task.checkCancellation()

                let diff = diffResult.stdout
                let recentSubjects = recentResult.stdout
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                let branchRaw = branchResult.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let branch: String? = branchRaw == "HEAD" ? nil : branchRaw

                let payload = CommitContextBuilder.build(
                    branch: branch,
                    base: base,
                    recentSubjects: recentSubjects,
                    priorMessage: priorMessage,
                    diff: diff
                )

                let message = try await adapter.generate(
                    input: payload,
                    prompt: promptOverride
                )
                guard !Task.isCancelled else { return }
                self.composer.subject = message.subject
                self.composer.body = message.body
                self.composer.expanded = true
            } catch is CancellationError {
                // user-cancelled
            } catch {
                self.composer.error = (error as NSError).localizedDescription
            }
        }
    }

    /// Cancel an in-flight `generate(...)` Task. Safe to call when no
    /// generation is running.
    func cancelGenerate() {
        composer.generation?.cancel()
        composer.generation = nil
    }

    /// Create the commit (or amend HEAD) using the current composer draft.
    /// On success the composer is reset and the pane refreshes. On failure
    /// the error is surfaced via `composer.error` (the inline error strip).
    func runCommit() {
        let subject = composer.subject
        let body = composer.body
        let amend = composer.amend
        let wt = worktree.path
        Task { @MainActor in
            do {
                try await git.commit(
                    worktreePath: wt,
                    subject: subject,
                    body: body,
                    amend: amend
                )
                self.composer.resetAfterCommit()
            } catch {
                self.composer.error = (error as NSError).localizedDescription
            }
            await self.refresh()
        }
    }

    /// Wire the Amend checkbox: toggling on prefills empty drafts with the
    /// HEAD message and surfaces a "rewrites history" warning when HEAD is
    /// at/behind its upstream. Toggling off clears the prefill iff it
    /// hasn't been edited, so the user's typed draft is never clobbered.
    ///
    /// Re-checks `composer.amend` between the async hops because the user
    /// can toggle off mid-flight (slow `git` on a large repo). Without the
    /// guard, a stale on-task could resume after the off-path has already
    /// cleared state and still prefill the composer.
    func amendDidChange(_ on: Bool) {
        let wt = worktree.path
        Task { @MainActor in
            if on {
                let priorResult = (try? await self.git.headMessage(worktreePath: wt)) ?? nil
                guard self.composer.amend else { return }
                if let prior = priorResult {
                    self.composer.applyAmendPrefill(prior)
                }
                let behind = (try? await self.git.isHeadAtOrBehindUpstream(worktreePath: wt)) ?? false
                guard self.composer.amend else { return }
                self.composer.amendWarning = behind
            } else {
                self.composer.clearAmendPrefillIfUnchanged()
                self.composer.amendWarning = false
            }
        }
    }

    /// Load the next page of pre-divergence history. Uses the oldest
    /// currently-visible SHA as the cursor; falls back to HEAD when the
    /// section is sitting on base (or there's no comparison ref at all).
    /// Concurrent re-entry is blocked by `isLoadingOlder` — the view
    /// hides the tap target while a load is in flight.
    @MainActor
    func loadOlder() async {
        guard !isLoadingOlder, hasMoreOlder else { return }
        let cursor: String
        if let last = olderCommits.last {
            cursor = last.sha
        } else if let last = commits.last {
            cursor = last.sha
        } else {
            cursor = "HEAD"
        }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await git.commitsOlder(
                worktreePath: worktree.path,
                beforeSha: cursor,
                count: 20
            )
            let cursorStillValid = (olderCommits.last?.sha == cursor)
                || (olderCommits.isEmpty && commits.last?.sha == cursor)
                || (olderCommits.isEmpty && commits.isEmpty && cursor == "HEAD")
            guard cursorStillValid else { return }
            self.olderCommits.append(contentsOf: page)
            if page.count < 20 {
                self.hasMoreOlder = false
            }
        } catch is CancellationError {
            // user-cancelled
        } catch {
            logger.error("loadOlder failed for worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.hasMoreOlder = false
        }
    }
}
