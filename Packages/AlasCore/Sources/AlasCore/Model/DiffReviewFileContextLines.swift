import Foundation

public enum DiffReviewFileContextLines: Equatable, Sendable {
    case unavailable
    case available([String])
}
