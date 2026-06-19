import Foundation

enum AlasCLIWorktreeResolver {
    enum Result: Equatable {
        case matched(Worktree)
        case missing(String)
        case ambiguous([String])
    }

    static func rows(worktrees: [Worktree], currentWorktreeId: String) -> [String] {
        let labels = worktrees.map(\.branch)
        let width = max(labels.map(\.count).max() ?? 0, 1) + 4
        return worktrees.map { worktree in
            let marker = worktree.id == currentWorktreeId ? "*" : " "
            let label = worktree.branch.padding(toLength: width, withPad: " ", startingAt: 0)
            return "\(marker) \(label)\(worktree.path.path)"
        }
    }

    static func resolve(target: String, worktrees: [Worktree]) -> Result {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing(trimmed) }

        let exactBranch = worktrees.filter { $0.branch == trimmed || $0.name == trimmed }
        if exactBranch.count == 1 { return .matched(exactBranch[0]) }
        if exactBranch.count > 1 { return .ambiguous(labels(for: exactBranch)) }

        let exactBasename = worktrees.filter { $0.path.lastPathComponent == trimmed }
        if exactBasename.count == 1 { return .matched(exactBasename[0]) }
        if exactBasename.count > 1 { return .ambiguous(labels(for: exactBasename)) }

        let prefixMatches = worktrees.filter {
            $0.branch.hasPrefix(trimmed)
                || $0.name.hasPrefix(trimmed)
                || $0.path.lastPathComponent.hasPrefix(trimmed)
        }
        if prefixMatches.count == 1 { return .matched(prefixMatches[0]) }
        if prefixMatches.count > 1 { return .ambiguous(labels(for: prefixMatches)) }

        return .missing(trimmed)
    }

    private static func labels(for worktrees: [Worktree]) -> [String] {
        let baseLabels = worktrees.map(baseLabel)
        let duplicateLabels = Set(
            Dictionary(grouping: baseLabels, by: { $0 })
                .filter { $0.value.count > 1 }
                .keys
        )

        return zip(worktrees, baseLabels).map { worktree, label in
            duplicateLabels.contains(label) ? "\(label) (\(worktree.path.path))" : label
        }
        .sorted()
    }

    private static func baseLabel(for worktree: Worktree) -> String {
        worktree.branch.isEmpty ? worktree.path.lastPathComponent : worktree.branch
    }
}
