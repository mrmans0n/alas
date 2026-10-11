import Foundation

public struct DiffReviewContextProvider: Sendable {
    public let id: UUID
    public let snapshot: @Sendable () async throws -> DiffReviewFileContextSnapshot

    public init(
        id: UUID = UUID(),
        snapshot: @escaping @Sendable () async throws -> DiffReviewFileContextSnapshot
    ) {
        self.id = id
        self.snapshot = snapshot
    }
}
