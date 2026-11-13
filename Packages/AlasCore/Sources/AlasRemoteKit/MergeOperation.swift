import Foundation

/// An in-progress conflict-producing operation. Detected by the presence
/// of marker files inside `.git`: `MERGE_HEAD`, `rebase-merge/`,
/// `CHERRY_PICK_HEAD`, or `REVERT_HEAD`.
public enum MergeOperation: Equatable, Sendable, Codable {
    /// Merging another branch into the current one.
    /// - sourceBranch: the branch being merged in (read from MERGE_MSG / MERGE_HEAD ref)
    case merge(sourceBranch: String?)

    /// Rebase in progress. `plan` is the parsed contents of
    /// `.git/rebase-merge/git-rebase-todo` plus `done`.
    case rebase(plan: RebasePlan)

    /// Cherry-picking a single commit. `sha` and the first line of the
    /// commit message are exposed for the operation card.
    case cherryPick(sha: String, summary: String)

    /// Reverting a single commit. `sha` and the first line of the commit
    /// message are exposed for the operation card.
    case revert(sha: String, summary: String)
}

public struct RebasePlan: Equatable, Sendable, Codable {
    public let ontoBranch: String?    // target ref, read from rebase-merge/onto
    public let sourceBranch: String?  // original branch, read from rebase-merge/head-name
    public let commits: [RebasePlanCommit]
    public var currentIndex: Int? {
        commits.firstIndex(where: { $0.state == .current })
    }

    public init(ontoBranch: String?, sourceBranch: String?, commits: [RebasePlanCommit]) {
        self.ontoBranch = ontoBranch
        self.sourceBranch = sourceBranch
        self.commits = commits
    }
}

public struct RebasePlanCommit: Equatable, Sendable, Codable {
    public enum State: String, Equatable, Sendable, Codable { case done, current, pending }
    public let sha: String          // short SHA as it appears in the todo file
    public let summary: String      // first line of commit message
    public let state: State

    public init(sha: String, summary: String, state: State) {
        self.sha = sha
        self.summary = summary
        self.state = state
    }
}
