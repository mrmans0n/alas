import Foundation

public struct DiffReviewImageProviderID: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        case workingCopy
        case commit
        case range
        case stash
        case hostedReview
    }

    public let source: Source
    public let repository: String
    public let beforeRevision: String
    public let afterRevision: String
    public let beforePath: String?
    public let afterPath: String

    public init(source: Source, repository: String, beforeRevision: String, afterRevision: String, beforePath: String?, afterPath: String) {
        self.source = source
        self.repository = repository
        self.beforeRevision = beforeRevision
        self.afterRevision = afterRevision
        self.beforePath = beforePath
        self.afterPath = afterPath
    }
}

public struct DiffReviewImageProvider: Sendable {
    public let id: DiffReviewImageProviderID
    public let load: @MainActor () async -> ImageDiffPair

    public init(id: DiffReviewImageProviderID, load: @escaping @MainActor () async -> ImageDiffPair) {
        self.id = id
        self.load = load
    }
}
