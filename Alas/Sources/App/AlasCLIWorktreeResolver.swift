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
                // `AlasActionService.resolveWorktree(forDirectory:)`.
                if let requestedIdentity = AlasActionService.fileIdentity(at: requested.resolvingSymlinksInPath().path) {
                    byPath = worktrees.filter {
                        AlasActionService.fileIdentity(at: $0.path.resolvingSymlinksInPath().path) == requestedIdentity
                    }
                }
            }
            if byPath.count == 1 { return .matched(byPath[0]) }
            if byPath.count > 1 { return .ambiguous(labels(for: byPath)) }

            // The target may be a subdirectory of a worktree rather than its
            // exact root (e.g. a bare `.` absolutized against a nested cwd).
            // Walk up to find the deepest worktree root that is an ancestor of
            // the target, mirroring `AlasActionService.containingWorktree(for:)`.
            if let containing = containingWorktree(for: requested, in: worktrees) {
                return .matched(containing)
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

    /// Deepest worktree root that is an ancestor of `url`, mirroring
    /// `AlasActionService.containingWorktree(for:)` — reused here (rather than
    /// duplicated) via `AlasActionService.relativePathAndDepth(for:in:)`, which
    /// doesn't depend on any `AlasActionService` instance state.
    private static func containingWorktree(for url: URL, in worktrees: [Worktree]) -> Worktree? {
        var bestMatch: (worktree: Worktree, rootComponentCount: Int)?
        for worktree in worktrees {
            let rootURL = worktree.path.standardizedFileURL
            guard let match = AlasActionService.relativePathAndDepth(for: url, in: rootURL) else { continue }
            if let currentBest = bestMatch, match.rootComponentCount <= currentBest.rootComponentCount {
                continue
            }
            bestMatch = (worktree, match.rootComponentCount)
        }
        return bestMatch?.worktree
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
