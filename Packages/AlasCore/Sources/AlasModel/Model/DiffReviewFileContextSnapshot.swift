import Foundation
import AlasFoundation

public struct DiffReviewFileContextSnapshot: Equatable, Sendable {
    public let old: DiffReviewFileContextLines
    public let new: DiffReviewFileContextLines

    public init(old: DiffReviewFileContextLines, new: DiffReviewFileContextLines) {
        self.old = old
        self.new = new
    }
}
