import Foundation

public enum ReviewDraftLocalChangesScope: String, Codable, Equatable, Hashable, Sendable {
    case all
    case unstaged
    case staged
}
