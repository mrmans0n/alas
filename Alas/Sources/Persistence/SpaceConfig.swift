import Foundation

struct SpacesFile: Codable, Equatable {
    var version: Int = 1
    var activeSpaceId: String
    var spaces: [SpaceConfig]
    var showSingleSpaceAffordance: Bool = false

    enum CodingKeys: String, CodingKey {
        case version
        case activeSpaceId
        case spaces
        case showSingleSpaceAffordance
    }

    init(
        version: Int = 1,
        activeSpaceId: String,
        spaces: [SpaceConfig],
        showSingleSpaceAffordance: Bool = false
    ) {
        self.version = version
        self.activeSpaceId = activeSpaceId
        self.spaces = spaces
        self.showSingleSpaceAffordance = showSingleSpaceAffordance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        activeSpaceId = try container.decode(String.self, forKey: .activeSpaceId)
        spaces = try container.decode([SpaceConfig].self, forKey: .spaces)
        showSingleSpaceAffordance = try container.decodeIfPresent(Bool.self, forKey: .showSingleSpaceAffordance) ?? false
    }
}

struct SpaceConfig: Codable, Equatable, Identifiable {
    static let defaultName = "Main"
    static let defaultEmoji = "🏠"

    var id: String
    var name: String
    var emoji: String
    var projectIds: [String]
    /// Current builds retain mixed Project and Workspace ordering here. `projectIds`
    /// stays as the downgrade-safe projection written for older builds.
    var members: [SpaceMemberReference]?
    var lastSelectedWorktreeId: String?
    var createdAt: Date
}

enum SpaceIcon {
    static let emojiOptions = EmojiIcon.emojiOptions

    static func sanitized(_ rawValue: String, fallback: String = SpaceConfig.defaultEmoji) -> String {
        EmojiIcon.sanitized(rawValue, fallback: fallback) ?? fallback
    }
}

enum EmojiIcon {
    static let emojiOptions = ["🏠", "💼", "✨", "🚀", "🧪", "🎨", "📚", "🔧", "🌱", "🔥", "⭐️", "🧠"]

    static func sanitized(_ rawValue: String?, fallback: String? = nil) -> String? {
        guard let rawValue else { return fallback }
        for character in rawValue.trimmingCharacters(in: .whitespacesAndNewlines) where isAllowed(character) {
            return String(character)
        }
        return fallback
    }

    private static func isAllowed(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && !CharacterSet.alphanumerics.contains(scalar))
        }
    }
}
