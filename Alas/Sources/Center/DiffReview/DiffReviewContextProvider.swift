import Foundation

struct DiffReviewContextProvider {
    let id: UUID
    let snapshot: @Sendable () async throws -> DiffReviewFileContextSnapshot

    init(
        id: UUID = UUID(),
        snapshot: @escaping @Sendable () async throws -> DiffReviewFileContextSnapshot
    ) {
        self.id = id
        self.snapshot = snapshot
    }
}
