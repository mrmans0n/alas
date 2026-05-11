import Foundation
import Observation

enum RightPaneTab: String { case changes, files }

@Observable
@MainActor
final class RightPaneState {
    let worktree: Worktree
    var changes: [ChangedFile] = []
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
            print("RightPaneState refresh error: \(error)")
        }
    }
}
