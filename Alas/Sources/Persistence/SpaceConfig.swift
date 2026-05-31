import Foundation

struct SpacesFile: Codable, Equatable {
    var version: Int = 1
    var activeSpaceId: String
    var spaces: [SpaceConfig]
}

struct SpaceConfig: Codable, Equatable, Identifiable {
    static let defaultName = "Main"
    static let defaultEmoji = "🏠"

    var id: String
    var name: String
    var emoji: String
    var projectIds: [String]
    var lastSelectedWorktreeId: String?
    var createdAt: Date
}
