import Foundation

public enum ReviewEvidenceStatus: String, Codable, Equatable, Sendable {
    case failed
    case pending
    case passed
    case cancelled
    case actionable
    case resolved
    case unknown

    public var isBlocking: Bool {
        switch self {
        case .failed, .actionable:
            true
        case .pending, .passed, .cancelled, .resolved, .unknown:
            false
        }
    }
}
