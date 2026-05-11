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
    var upstreamRef: String? = nil
    var workingTreeExpanded: Bool = true
    var commitsExpanded: Bool = true

    /// `true` once `refresh()` has decided the initial `activeTab`. After
    /// that, the user's tab choice is sticky and refreshes leave it alone.
    private var didInitDefaultTab: Bool = false

    private let git = GitService()
    private let watcher: WorktreeWatcher

    init(worktree: Worktree) {
        self.worktree = worktree
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
            async let c = git.commitsAhead(at: worktree.path)
            let entries = try await s
            let tree = try await git.fileTree(worktreePath: worktree.path, statusEntries: entries)
            let (commits, upstream) = try await c
            self.changes = entries
            self.fileTree = tree
            self.commits = commits
            self.upstreamRef = upstream

            // Smart first-open default: if there are no working-tree
            // changes, surface Files instead of an empty Changes pane.
            // Applied exactly once; user toggles win thereafter.
            if !didInitDefaultTab {
                if entries.isEmpty && !tree.isEmpty {
                    activeTab = .files
                }
                didInitDefaultTab = true
            }
        } catch {
            print("RightPaneState refresh error: \(error)")
        }
    }
}
