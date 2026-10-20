import Foundation
import AlasFoundation

public enum DiffReviewFileContextLines: Equatable, Sendable {
    case unavailable
    case available([String])
}
