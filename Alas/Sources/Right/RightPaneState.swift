import Foundation
import Observation

@Observable
@MainActor
final class RightPaneState {
    let worktree: Worktree
    var changes: [ChangedFile] = []
    var fileTree: [FileTreeNode] = []
    var loading: Bool = false
    var openPaths: Set<String> = []   // expanded directories in the tree

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
            let entries = try await git.status(worktreePath: worktree.path)
            let tree = try await git.fileTree(worktreePath: worktree.path, statusEntries: entries)
            self.changes = entries
            self.fileTree = tree
        } catch {
            // Surface elsewhere; for v1, just log.
            print("RightPaneState refresh error: \(error)")
        }
    }
}
