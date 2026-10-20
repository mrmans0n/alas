import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

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
