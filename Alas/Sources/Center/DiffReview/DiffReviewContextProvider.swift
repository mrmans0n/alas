import Foundation

struct DiffReviewContextProvider {
    let snapshot: @Sendable () async throws -> DiffReviewFileContextSnapshot
}
