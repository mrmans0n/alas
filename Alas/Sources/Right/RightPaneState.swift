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
            async let s = git.status(worktreePath: worktree.path)
            async let c = git.commitsAhead(at: worktree.path, baseBranch: baseBranch)
            let entries = try await s
            let tree = try await git.fileTree(worktreePath: worktree.path, statusEntries: entries)
            let (commits, ref) = try await c
            self.changes = entries
            self.fileTree = tree
            self.commits = commits
            self.comparisonRef = ref

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
        let path = file.path
        composer.pendingStageOps.insert(path)
        Task { @MainActor in
            do {
                if file.stage == .staged {
                    try await git.unstage(worktreePath: worktree.path, files: [path])
                } else {
                    try await git.stage(worktreePath: worktree.path, files: [path])
                }
            } catch {
                self.composer.error = (error as NSError).localizedDescription
            }
            self.composer.pendingStageOps.remove(path)
            await self.refresh()
        }
    }

    func stageAll(_ files: [ChangedFile]) {
        let paths = files.map(\.path)
        Task { @MainActor in
            do { try await git.stageAll(worktreePath: worktree.path, files: paths) }
            catch { self.composer.error = (error as NSError).localizedDescription }
            await self.refresh()
        }
    }

    func unstageAll(_ files: [ChangedFile]) {
        let paths = files.map(\.path)
        Task { @MainActor in
            do { try await git.unstageAll(worktreePath: worktree.path, files: paths) }
            catch { self.composer.error = (error as NSError).localizedDescription }
            await self.refresh()
        }
    }
}
