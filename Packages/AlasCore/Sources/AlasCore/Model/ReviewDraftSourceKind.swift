import Foundation

public enum ReviewDraftSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case localChanges = "local-changes"
    case commit
    case trackedCommit = "tracked-commit"
    case commitRange = "commit-range"
    case draftCommit = "draft-commit"
    case branch
    case branchWithLocalChanges = "branch-with-local-changes"
    case sinceSnapshot = "since-snapshot"
    case reviewRequest = "review-request"
    case draftReviewRequest = "draft-review-request"
}
