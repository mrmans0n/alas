import Foundation

/// A minimal reference to a merged review request. Deliberately far smaller
/// than `ReviewRequest`: worktree cleanup only needs to answer "was this head
/// branch merged, and where can I link to it", and building a full
/// `ReviewRequest` would mean per-item thread and check queries.
public struct MergedReviewRequestRef: Equatable, Sendable {
    public let number: Int
    public let headRefName: String
    public let url: URL
    /// The head commit SHA the code host recorded for this merged review.
    /// A branch name match alone is not enough to call a worktree
    /// forge-merged: branch names get reused after an old, unrelated PR on
    /// the same name merged, so the caller must also verify this SHA is
    /// actually present in the worktree's current history before trusting
    /// the match.
    public let headSHA: String

    public init(number: Int, headRefName: String, url: URL, headSHA: String) {
        self.number = number
        self.headRefName = headRefName
        self.url = url
        self.headSHA = headSHA
    }
}
