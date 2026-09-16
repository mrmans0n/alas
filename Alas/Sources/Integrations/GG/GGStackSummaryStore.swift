import Foundation
import Observation

/// Background-managed paths derive their badge from local inventories and
/// the shared inbox. Right-pane summaries remain a fallback for older CLIs
/// and contexts not covered by the project refresh.
@MainActor
@Observable
final class GGStackSummaryStore {
    static let shared = GGStackSummaryStore()
    var summaries: [String: GGStackSummary] = [:]

    struct Inventory: Equatable {
        let projectId: String
        let stackName: String?
        var stack: GGStack?
    }

    private(set) var inventories: [String: Inventory] = [:]

    func prepare(path: String, projectId: String, stackName: String?) {
        if let current = inventories[path], current.projectId == projectId, current.stackName == stackName { return }
        inventories[path] = Inventory(projectId: projectId, stackName: stackName)
    }

    func update(path: String, projectId: String, stackName: String?, stack: GGStack?) {
        guard var current = inventories[path], current.projectId == projectId,
              current.stackName == stackName else { return }
        current.stack = stackName == nil || stack?.name == stackName ? stack : nil
        if inventories[path] != current { inventories[path] = current }
    }

    func retainManagedPaths(_ paths: Set<String>) {
        let removed = Set(inventories.keys).subtracting(paths)
        for path in removed {
            inventories[path] = nil
            summaries[path] = nil
        }
    }

    func remove(projectId: String) {
        retainManagedPaths(Set(inventories.filter { $0.value.projectId != projectId }.keys))
    }

    func summary(forPath path: String, inbox: GGInboxStore = .shared) -> GGStackSummary? {
        guard let inventory = inventories[path] else { return summaries[path] }
        guard let stack = inventory.stack, stack.totalCommits > 0 else { return nil }
        let states = inbox.states[inventory.projectId]?.reviewStates ?? [:]
        var merged = 0
        var known = true
        for entry in stack.entries {
            guard let number = entry.prNumber else { continue }
            let identity = GGInboxEntryIdentity(stackName: stack.name, sha: entry.sha, prNumber: number)
            // Both CLI outputs abbreviate SHAs. Exact matching also prevents
            // an old commit's review from being applied after a rewrite.
            switch states[identity] {
            case "merged": merged += 1
            case "open", "closed", "draft": break
            default: known = false
            }
        }
        return GGStackSummary(merged: merged, total: stack.totalCommits, isRemoteStateKnown: known)
    }

    /// Drops summaries for worktrees that no longer exist. Called after the
    /// app's worktree cleanup pass; value-diffed to avoid invalidating
    /// observers when nothing was pruned.
    func prune(keepingPaths: Set<String>) {
        retainManagedPaths(keepingPaths)
        let pruned = summaries.filter { keepingPaths.contains($0.key) }
        if pruned.count != summaries.count { summaries = pruned }
    }
}
