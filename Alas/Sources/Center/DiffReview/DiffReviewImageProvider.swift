import Foundation

struct DiffReviewImageProviderID: Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        case workingCopy
        case commit
        case range
        case stash
        case hostedReview
    }

    let source: Source
    let repository: String
    let beforeRevision: String
    let afterRevision: String
    let beforePath: String?
    let afterPath: String
}

struct DiffReviewImageProvider {
    let id: DiffReviewImageProviderID
    let load: @MainActor () async -> ImageDiffPair
}
