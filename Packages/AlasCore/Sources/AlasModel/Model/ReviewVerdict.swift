import Foundation

public enum ReviewVerdict: String, Codable, Equatable, Sendable {
    case approve
    case requestChanges
    case comment
}
