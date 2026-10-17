import Foundation

/// Which worktree a CLI or delegation selector names: a path, a branch or
/// name, a directory name, or a unique prefix of one.
public enum AlasCLIWorktreeResolver {
    public enum Result: Equatable, Sendable {
        case matched(Worktree)
        case missing(String)
        case ambiguous([String])
    }

    public static func rows(worktrees: [Worktree], currentWorktreeId: String) -> [String] {
        let labels = worktrees.map(\.branch)
        let width = max(labels.map(\.count).max() ?? 0, 1) + 4
        return worktrees.map { worktree in
            let marker = worktree.id == currentWorktreeId ? "*" : " "
            let label = worktree.branch.padding(toLength: width, withPad: " ", startingAt: 0)
            return "\(marker) \(label)\(RemotePath.realPath(worktree.path.path))"
        }
    }

    public static func resolve(target: String, worktrees: [Worktree]) -> Result {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing(trimmed) }

        // Absolute paths match a worktree root exactly, and never fall
        // through to branch/prefix matching.
        if trimmed.hasPrefix("/") {
            let requested = URL(fileURLWithPath: trimmed)
            let standardized = requested.standardizedFileURL.path
            var byPath = worktrees.filter { $0.path.standardizedFileURL.path == standardized }
            if byPath.isEmpty {
                // The target may reach a worktree root through a symlink (or the
                // worktree itself was registered via one) — resolve symlinks on
                // both sides and compare file identity before giving up, mirroring
                // `WorktreePaths.worktree(owning:in:)`.
                if let requestedIdentity = WorktreePaths.fileIdentity(at: requested.resolvingSymlinksInPath().path) {
                    byPath = worktrees.filter {
                        WorktreePaths.fileIdentity(at: $0.path.resolvingSymlinksInPath().path) == requestedIdentity
                    }
                }
            }
            if byPath.count == 1 { return .matched(byPath[0]) }
            if byPath.count > 1 { return .ambiguous(labels(for: byPath)) }

            // The target may be a subdirectory of a worktree rather than its
            // exact root (e.g. a bare `.` absolutized against a nested cwd).
            // Walk up to find the deepest worktree root that is an ancestor of
            // the target.
            if let containing = WorktreePaths.containing(requested, in: worktrees) {
                return .matched(containing.worktree)
            }
            return .missing(trimmed)
        }

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
            duplicateLabels.contains(label) ? "\(label) (\(RemotePath.display(worktree.path.path)))" : label
        }
        .sorted()
    }

    private static func baseLabel(for worktree: Worktree) -> String {
        worktree.branch.isEmpty ? worktree.path.lastPathComponent : worktree.branch
    }
}
