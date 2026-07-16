import Foundation

enum ReviewScopeChoice: Equatable {
    case workingTree
    case commit(CommitInfo)
    case range(older: CommitInfo, newer: CommitInfo)
    case branch(name: String)
}

enum ReviewScopeSelection {
    static func target(
        for choice: ReviewScopeChoice,
        worktreeID: String,
        repositoryPath: URL,
        headSHA: String? = nil,
        branchBaseSHA: String? = nil
    ) -> ReviewSessionTarget {
        switch choice {
        case .workingTree:
            return .localChanges(worktreeID: worktreeID, repositoryPath: repositoryPath, scope: .all)
        case .commit(let info):
            return .commit(
                worktreeID: worktreeID,
                repositoryPath: repositoryPath,
                sha: info.sha,
                title: "\(info.shortSha) \(info.subject)"
            )
        case .range(let older, let newer):
            return .commitRange(
                worktreeID: worktreeID,
                repositoryPath: repositoryPath,
                base: "\(older.sha)^",
                head: newer.sha,
                title: "Review \(older.shortSha)…\(newer.shortSha)"
            )
        case .branch(let name):
            // The picked branch is the BASE; the current worktree HEAD is the
            // head — this reviews "my work on top of `name`". The CLI's
            // `alas review <branch>` (AppState.cliOpenRevisionReview) reviews
            // the opposite direction ("`name`'s changes vs the configured
            // base branch"). Both are intentional for their own entry point;
            // do not "fix" one to match the other without an explicit design
            // decision — see docs/superpowers/specs/2026-07-16-review-target-palette-design.md.
            //
            // Pin both endpoints to immutable SHAs when resolved, so a stored
            // review keeps the same merge base even if the branch advances.
            // The branch name is retained only for the display title.
            return .branch(
                worktreeID: worktreeID,
                repositoryPath: repositoryPath,
                base: branchBaseSHA ?? name,
                head: headSHA ?? "HEAD",
                title: "Review HEAD against \(name)"
            )
        }
    }

    static func filteredCommits(_ commits: [CommitInfo], query: String) -> [CommitInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commits }
        let needle = trimmed.lowercased()
        return commits.filter { commit in
            commit.sha.lowercased().contains(needle)
                || commit.shortSha.lowercased().contains(needle)
                || commit.subject.lowercased().contains(needle)
                || commit.author.lowercased().contains(needle)
        }
    }
}
