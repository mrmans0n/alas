import AppKit
import Foundation
import Observation
import os

enum RightPaneTab: String { case changes, files }

@Observable
@MainActor
final class RightPaneState {
    let worktree: Worktree
    var changes: [ChangedFile] = []
    /// Per-worktree in-progress merge / rebase / cherry-pick state.
    /// Refreshed alongside `changes` from `refresh()`.
    let mergeOp: MergeOperationState
    var composer = CommitComposerState()
    var fileTree: [FileTreeNode] = []
    var loading: Bool = false
    var openPaths: Set<String> = []   // expanded directories in the tree
    private(set) var loadedFileTreeChildPaths: Set<String> = [""]
    private(set) var loadingFileTreeChildPaths: Set<String> = []
    private(set) var failedFileTreeChildPaths: Set<String> = []
    private(set) var fileTreeGeneration: Int = 0

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

    // Sync-nudge state. All fields are in-memory only; nothing is
    // persisted to AppConfig. Two independent conditions:
    //   - behindBase: HEAD is behind the trunk base (origin/main).
    //   - behindUpstream: HEAD is behind its own remote tracking branch
    //     (someone else pushed to it, or you pushed from elsewhere).
    var behindBase: GitService.BehindStatus? = nil
    var behindUpstream: GitService.BehindStatus? = nil

    /// Live branch name, refreshed on each `refresh()`. The `worktree.branch`
    /// snapshot captured at construction goes stale after a `git checkout`
    /// inside the same worktree, so the chip predicates read this instead.
    /// Empty when HEAD is detached or unborn.
    var currentBranch: String

    /// Live HEAD SHA, refreshed on each `refresh()`. Detects rebase, reset,
    /// amend, fast-forward, etc. so the behind chips update even when the
    /// branch name hasn't changed.
    var currentHeadSHA: String = ""

    /// `true` once `refresh()` has decided the initial `activeTab`. After
    /// that, the user's tab choice is sticky and refreshes leave it alone.
    private var didInitDefaultTab: Bool = false

    /// `var` so `RightPaneStore` can keep this in sync with
    /// `AppConfig.worktrees.baseBranch` when the user edits it in Settings,
    /// without throwing away the rest of the cached state.
    var baseBranch: String

    /// `true` once the user has explicitly picked a base branch via the
    /// selector. Prevents `RightPaneStore` from snapping the branch back to
    /// the global config default on the next render.
    var userOverrodeBaseBranch: Bool = false

    /// The last base branch value that came from `AppConfig` (not from the
    /// selector). Used by `RightPaneStore` to distinguish a Settings change
    /// (new config value) from a normal render (same config value).
    var lastConfigBaseBranch: String = ""

    var pendingDiscard: PendingDiscard? = nil

    /// Injected by `RightPaneStore` after creation so `confirmDiscard` can
    /// close any open diff tabs whose path was just discarded. Nil in tests
    /// that construct `RightPaneState` directly.
    var closeDiffTabs: (([String]) -> Void)? = nil

    /// Injected by `RightPaneStore` to open the conflict resolution UI for a
    /// given file. In Plan 1, this routes to the existing unified DiffTabView.
    /// In Plan 2, it will route to the new 3-column merge editor.
    var openConflict: ((String) -> Void)? = nil

    /// In-memory ring buffer of recently selected base branches for this
    /// worktree. Max 3 entries; newest at the end. Not persisted.
    private(set) var recentBaseBranches: [String] = []

    /// Branches available in this worktree, populated on-demand by
    /// `fetchBranches()`. Used by the base-branch picker.
    private(set) var availableBranches: [String] = []

    /// Upstream tracking ref of the current branch (e.g. `origin/main`),
    /// resolved during `refreshSyncStatus()`. Used by the base-branch
    /// picker to include the upstream in the smart shortlist.
    private(set) var upstreamRef: String? = nil

    private let git = GitService()
    private let watcher: WorktreeWatcher
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "right-pane-state")

    @ObservationIgnored
    private var syncStatusTimer: Task<Void, Never>? = nil

    /// Refresh interval for `syncStatusTimer`. 5 minutes per design;
    /// constant in v1.
    @ObservationIgnored
    private let syncStatusInterval: UInt64 = 5 * 60 * 1_000_000_000 // ns

    /// True iff the "behind base" chip should be shown.
    var showBehindBaseChip: Bool {
        guard let s = behindBase else { return false }
        guard s.count > 0 else { return false }
        guard !currentBranch.isEmpty else { return false } // detached HEAD
        guard currentBranch != baseBranch else { return false }
        return true
    }

    /// True iff the "behind upstream" chip should be shown. Independent of
    /// `showBehindBaseChip` — both can be true simultaneously.
    var showBehindUpstreamChip: Bool {
        guard let s = behindUpstream else { return false }
        guard s.count > 0 else { return false }
        guard !currentBranch.isEmpty else { return false } // detached HEAD
        return true
    }

    init(worktree: Worktree, baseBranch: String) {
        self.worktree = worktree
        self.baseBranch = baseBranch
        self.currentBranch = worktree.branch
        self.mergeOp = MergeOperationState(worktreePath: worktree.path, gitService: GitService())
        self.watcher = WorktreeWatcher(path: worktree.path)
        watcher.onChange = { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func start() {
        watcher.start()
        Task { @MainActor in await self.refresh() }
        Task { @MainActor in await self.refreshSyncStatus() }
        syncStatusTimer?.cancel()
        syncStatusTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.syncStatusInterval ?? 0)
                } catch {
                    return // cancelled
                }
                guard let self else { return }
                await self.refreshSyncStatus()
            }
        }
    }

    func stop() {
        watcher.stop()
        syncStatusTimer?.cancel()
        syncStatusTimer = nil
    }

    /// Update the base branch, record it in the recent list, and refresh.
    func selectBaseBranch(_ branch: String) {
        baseBranch = branch
        userOverrodeBaseBranch = true
        behindBase = nil
        recentBaseBranches.removeAll { $0 == branch }
        recentBaseBranches.append(branch)
        if recentBaseBranches.count > 3 {
            recentBaseBranches = Array(recentBaseBranches.suffix(3))
        }
        Task { @MainActor in
            async let r = refresh()
            async let s = refreshSyncStatus()
            _ = await (r, s)
        }
    }

    /// Populate `availableBranches` from git. Best-effort; errors are logged.
    func fetchBranches() async {
        do {
            availableBranches = try await git.branches(at: worktree.path)
        } catch {
            logger.error("branch list fetch failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    func refresh() async {
        loading = true
        defer { loading = false }
        invalidateFileTreeChildLoadsForRefresh()
        do {
            // Any refresh re-anchors the older-history cursor; drop the
            // accumulated pages so we don't accidentally splice an old
            // page onto a new HEAD.
            self.olderCommits = []
            self.hasMoreOlder = true
            self.isLoadingOlder = false
            async let s = git.status(worktreePath: worktree.path)
            async let c = git.commitsAhead(at: worktree.path, baseBranch: baseBranch, ignoreUpstream: userOverrodeBaseBranch)
            async let br = git.currentBranch(worktreePath: worktree.path)
            async let mergeRefresh: Void = mergeOp.refresh()
            let entries = try await s
            let tree = try await git.fileTree(worktreePath: worktree.path, statusEntries: entries)
            let (commits, ref) = try await c
            _ = await mergeRefresh
            self.changes = entries
            self.fileTree = tree
            self.commits = commits
            self.comparisonRef = ref
            let previousBranch = self.currentBranch
            self.currentBranch = (try? await br) ?? self.currentBranch
            let previousHeadSHA = self.currentHeadSHA
            let headSHA = (try? await self.git.revParseHEAD(worktreePath: self.worktree.path)) ?? self.currentHeadSHA
            self.currentHeadSHA = headSHA
            if previousBranch != self.currentBranch || previousHeadSHA != self.currentHeadSHA {
                // Branch or HEAD changed (checkout, rebase, reset, amend, …).
                // The behind chips were probed against the OLD branch's base
                // and upstream — clear them so the header doesn't render
                // stale counts, then re-probe in the background.
                self.behindBase = nil
                self.behindUpstream = nil
                Task { @MainActor in await self.refreshSyncStatus() }
            }
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

    func invalidateFileTreeChildLoadsForRefresh() {
        fileTreeGeneration += 1
        loadedFileTreeChildPaths = [""]
        loadingFileTreeChildPaths = []
        failedFileTreeChildPaths = []
        fileTree = Self.resetLoadingFileTreeChildren(in: fileTree)
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

    nonisolated static func mergingChildren(
        in nodes: [FileTreeNode],
        for path: String,
        with children: [FileTreeNode],
        state: DirectoryChildrenState
    ) -> (nodes: [FileTreeNode], didMerge: Bool) {
        var didMerge = false
        let updatedNodes = nodes.map { node in
            if node.path == path {
                didMerge = true
                var updated = node
                var merged: [String: FileTreeNode] = [:]
                for child in node.children ?? [] {
                    merged[child.id] = child
                }
                for child in children {
                    if let existing = merged[child.id] {
                        var refreshed = existing
                        refreshed.badge = child.badge ?? existing.badge
                        refreshed.visibility = mergedVisibility(existing: existing.visibility, incoming: child.visibility)
                        refreshed.isSubmodule = child.isSubmodule || existing.isSubmodule
                        refreshed.childrenState = mergedChildrenState(existing: existing.childrenState, incoming: child.childrenState)
                        if refreshed.children == nil {
                            refreshed.children = child.children
                        }
                        merged[child.id] = refreshed
                    } else {
                        merged[child.id] = child
                    }
                }
                updated.children = merged.values.sorted { lhs, rhs in
                    if lhs.kind != rhs.kind { return lhs.kind == .dir }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                updated.childrenState = state
                return updated
            }
            guard let existing = node.children else { return node }
            var updated = node
            let result = mergingChildren(in: existing, for: path, with: children, state: state)
            didMerge = didMerge || result.didMerge
            updated.children = result.nodes
            return updated
        }
        return (updatedNodes, didMerge)
    }

    nonisolated private static func mergedVisibility(
        existing: FileVisibility,
        incoming: FileVisibility
    ) -> FileVisibility {
        if incoming == .tracked, existing != .tracked {
            return existing
        }
        return incoming
    }

    nonisolated private static func mergedChildrenState(
        existing: DirectoryChildrenState,
        incoming: DirectoryChildrenState
    ) -> DirectoryChildrenState {
        if incoming == .notLoaded, existing != .notLoaded {
            return existing
        }
        return incoming
    }

    nonisolated static func resetLoadingFileTreeChildren(in nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.map { node in
            var updated = node
            if let children = node.children {
                updated.children = resetLoadingFileTreeChildren(in: children)
            }
            if node.kind == .dir, node.childrenState == .loading {
                updated.children = nil
                updated.childrenState = .notLoaded
            }
            return updated
        }
    }

    nonisolated static func shouldAutoLoadFileTreeChildren(
        path: String,
        childrenState: DirectoryChildrenState,
        loadedPaths: Set<String>,
        loadingPaths: Set<String>,
        failedPaths: Set<String>
    ) -> Bool {
        guard !loadedPaths.contains(path),
              !loadingPaths.contains(path),
              !failedPaths.contains(path) else { return false }
        return childrenState == .notLoaded || childrenState == .loaded
    }

    func shouldAutoLoadFileTreeChildren(path: String, childrenState: DirectoryChildrenState) -> Bool {
        Self.shouldAutoLoadFileTreeChildren(
            path: path,
            childrenState: childrenState,
            loadedPaths: loadedFileTreeChildPaths,
            loadingPaths: loadingFileTreeChildPaths,
            failedPaths: failedFileTreeChildPaths
        )
    }

    func loadFileTreeChildren(path: String) {
        guard !loadedFileTreeChildPaths.contains(path),
              !loadingFileTreeChildPaths.contains(path) else { return }
        loadingFileTreeChildPaths.insert(path)
        let loadingMerge = Self.mergingChildren(in: fileTree, for: path, with: [], state: .loading)
        guard loadingMerge.didMerge else {
            loadingFileTreeChildPaths.remove(path)
            return
        }
        fileTree = loadingMerge.nodes
        let generation = fileTreeGeneration
        Task { @MainActor in
            defer {
                if self.fileTreeGeneration == generation {
                    self.loadingFileTreeChildPaths.remove(path)
                }
            }
            do {
                let children = try await git.fileTreeChildren(worktreePath: worktree.path, path: path)
                guard self.fileTreeGeneration == generation else { return }
                let result = Self.mergingChildren(in: self.fileTree, for: path, with: children, state: .loaded)
                guard result.didMerge else { return }
                self.loadedFileTreeChildPaths.insert(path)
                self.failedFileTreeChildPaths.remove(path)
                self.fileTree = result.nodes
            } catch {
                guard self.fileTreeGeneration == generation else { return }
                let result = Self.mergingChildren(in: self.fileTree, for: path, with: [], state: .failed)
                guard result.didMerge else { return }
                self.failedFileTreeChildPaths.insert(path)
                self.fileTree = result.nodes
                logger.error("file tree child load failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Paths to discard for the given file path. Expands staged renames into
    /// both new and original paths so the deletion of the old side is also
    /// restored. Returns `[]` if the path is not in `changes` (stale request).
    static func discardPaths(forFileAt path: String, in changes: [ChangedFile]) -> [String] {
        guard let file = changes.first(where: { $0.path == path }) else { return [] }
        return unstagePaths(for: file)
    }

    /// Paths to discard for every change under a folder (recursive). Folders
    /// in the Changes tree are virtual — built from changed paths only — so
    /// a prefix match against `"<folder>/"` is exhaustive. Staged renames
    /// under the folder include their original path even if the origin lives
    /// outside the folder (rare but possible after a refactor).
    static func discardPaths(forFolderAt folder: String, in changes: [ChangedFile]) -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let matching = changes.filter { $0.path.hasPrefix(prefix) }
        return matching.flatMap(unstagePaths(for:))
    }

    /// Every changed path in the worktree (staged + unstaged + untracked),
    /// with staged renames expanded.
    static func discardPaths(forAllIn changes: [ChangedFile]) -> [String] {
        // Deduplicate while preserving first-seen order.
        var seen = Set<String>()
        var out: [String] = []
        for file in changes {
            for p in unstagePaths(for: file) where seen.insert(p).inserted {
                out.append(p)
            }
        }
        return out
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

    func requestDiscardFile(path: String) {
        let paths = Self.discardPaths(forFileAt: path, in: changes)
        guard !paths.isEmpty else { return }
        pendingDiscard = PendingDiscard(target: .file(path: path), paths: paths)
    }

    func requestDiscardFolder(path: String) {
        let paths = Self.discardPaths(forFolderAt: path, in: changes)
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
        let paths = Self.discardPaths(forAllIn: changes)
        guard !changes.isEmpty else { return }
        pendingDiscard = PendingDiscard(
            target: .all(fileCount: changes.count),
            paths: paths
        )
    }

    func cancelDiscard() {
        pendingDiscard = nil
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
        let paths = pending.paths
        composer.error = nil
        do {
            try await git.discardPaths(worktreePath: worktree.path, files: paths)
        } catch {
            composer.error = (error as NSError).localizedDescription
            return
        }
        await refresh()
        closeDiffTabs?(paths)
    }

    /// Run `git diff HEAD -- <file>` (or `--cached` on unborn HEAD, or
    /// `/dev/null` for untracked) and put the unified-diff output on the
    /// general pasteboard. `renameFrom` is the staged-rename origin path
    /// (from `ChangedFile.renameFrom`); when present it's included in the
    /// pathspec so `git diff` emits the rename-from/rename-to header
    /// instead of an add-only patch. Best-effort: errors are surfaced via
    /// `composer.error`. Single source of truth so the context menu and
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
                    self.composer.error = result.stderr
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(result.stdout, forType: .string)
            } catch {
                self.composer.error = (error as NSError).localizedDescription
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
            return URL(fileURLWithPath: raw)
        }
        return URL(fileURLWithPath: raw, relativeTo: worktreePath).standardizedFileURL
    }

    // MARK: - Commit composer wiring

    /// Run an AI commit-message CLI with the staged diff + repo context as
    /// stdin and the user's prompt as `--prompt`. Cancellable via
    /// `cancelGenerate()` (or by re-calling `generate` — the new Task
    /// replaces the old). On success, populates `composer.subject`/`body`
    /// and expands the composer so the user sees the result.
    func generate(promptOverride: String, agent: AgentDefinition) {
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

                let message = try await AgentRunner.runPrompt(
                    agent: agent,
                    input: payload,
                    prompt: promptOverride,
                    workingDirectory: wt.path
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

    /// Probes the worktree's "behind" status against the trunk base AND
    /// against the branch's own upstream tracking ref (when one exists).
    /// Fetches each resolvable remote ref when the last probe was older
    /// than 30s. Errors are logged but never surfaced; chips reflect the
    /// last successful probe (or stay hidden if none has succeeded yet).
    @MainActor
    func refreshSyncStatus() async {
        await refreshBehindBase()
        await refreshBehindUpstream()
    }

    @MainActor
    private func refreshBehindBase() async {
        do {
            guard let resolved = try await git.resolveBaseRef(
                worktreePath: worktree.path,
                baseBranch: baseBranch,
                preferLocal: userOverrodeBaseBranch
            ) else {
                behindBase = nil
                return
            }
            if let remote = resolved.remote {
                let last = behindBase?.probedAt ?? .distantPast
                if Date().timeIntervalSince(last) > 30 {
                    do {
                        try await git.fetchRef(
                            worktreePath: worktree.path,
                            remote: remote,
                            branch: resolved.fetchBranch ?? baseBranch
                        )
                    } catch {
                        logger.error("base fetch failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            self.behindBase = try await git.behindStatus(
                worktreePath: worktree.path,
                ref: resolved.baseRef
            )
        } catch {
            logger.error("behind-base probe failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func refreshBehindUpstream() async {
        do {
            guard let upstream = try await git.resolveUpstreamRef(
                worktreePath: worktree.path
            ) else {
                behindUpstream = nil
                upstreamRef = nil
                return
            }
            upstreamRef = upstream.ref
            // Upstream ref looks like "origin/<branch>"; the local branch name
            // is what we fetch.
            let branchName = String(upstream.ref.dropFirst(upstream.remote.count + 1))
            let last = behindUpstream?.probedAt ?? .distantPast
            if Date().timeIntervalSince(last) > 30 {
                do {
                    try await git.fetchRef(
                        worktreePath: worktree.path,
                        remote: upstream.remote,
                        branch: branchName
                    )
                } catch {
                    logger.error("upstream fetch failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            self.behindUpstream = try await git.behindStatus(
                worktreePath: worktree.path,
                ref: upstream.ref
            )
        } catch {
            logger.error("behind-upstream probe failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    // MARK: - Merge / rebase / cherry-pick operations

    /// Runs `git merge <branch>`, refreshes state, and auto-opens the first
    /// conflicted file (via `openConflict`) when the result is a conflict.
    @MainActor
    func runMerge(branch: String) {
        Task { @MainActor in
            do {
                let result = try await git.merge(worktreePath: worktree.path, branch: branch)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("merge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func runRebase(onto: String) {
        Task { @MainActor in
            do {
                let result = try await git.rebase(worktreePath: worktree.path, onto: onto)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("rebase failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func runCherryPick(sha: String) {
        Task { @MainActor in
            do {
                let result = try await git.cherryPick(worktreePath: worktree.path, sha: sha)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("cherry-pick failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func continueOperation() {
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
                let result = try await git.continueOperation(worktreePath: worktree.path, op: op)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("continue failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func abortOperation() {
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
                try await git.abortOperation(worktreePath: worktree.path, op: op)
                await refresh()
            } catch {
                logger.error("abort failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func skipOperation() {
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
                let result = try await git.skipOperation(worktreePath: worktree.path, op: op)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("skip failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func useOurs(file: ChangedFile) {
        Task { @MainActor in
            do {
                try await git.useOurs(worktreePath: worktree.path, relativePath: file.path)
                try await git.markResolved(worktreePath: worktree.path, relativePath: file.path)
                await refresh()
            } catch {
                logger.error("useOurs failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func useTheirs(file: ChangedFile) {
        Task { @MainActor in
            do {
                try await git.useTheirs(worktreePath: worktree.path, relativePath: file.path)
                try await git.markResolved(worktreePath: worktree.path, relativePath: file.path)
                await refresh()
            } catch {
                logger.error("useTheirs failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func keepDeleted(file: ChangedFile) {
        Task { @MainActor in
            do {
                try await git.keepDeleted(worktreePath: worktree.path, relativePath: file.path)
                await refresh()
            } catch {
                logger.error("keepDeleted failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func markResolved(file: ChangedFile) {
        Task { @MainActor in
            do {
                try await git.markResolved(worktreePath: worktree.path, relativePath: file.path)
                await refresh()
            } catch {
                logger.error("markResolved failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// On `.conflict`, auto-open the first conflicted file via the injected
    /// `openConflict` closure. On `.clean`/`.error`, do nothing (refresh already
    /// updated the operation card; `.error` is logged but not surfaced for v1).
    private func handleOperationResult(_ result: MergeResult) {
        switch result {
        case .clean:
            return
        case .conflict(let files):
            guard let first = files.first else { return }
            openConflict?(first.path)
        case .error(let message):
            logger.error("operation returned error: \(message, privacy: .public)")
        }
    }
}
