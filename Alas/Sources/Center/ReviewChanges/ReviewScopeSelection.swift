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
        repositoryPath: URL
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
            return .branch(
                worktreeID: worktreeID,
                repositoryPath: repositoryPath,
                base: name,
                head: "HEAD",
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
