import Foundation
import AlasFoundation

public struct SpacesFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var activeSpaceId: String
    public var spaces: [SpaceConfig]
    public var showSingleSpaceAffordance: Bool = false

    public enum CodingKeys: String, CodingKey, Sendable {
        case version
        case activeSpaceId
        case spaces
        case showSingleSpaceAffordance
    }

    public init(
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        activeSpaceId = try container.decode(String.self, forKey: .activeSpaceId)
        spaces = try container.decode([SpaceConfig].self, forKey: .spaces)
        showSingleSpaceAffordance = try container.decodeIfPresent(Bool.self, forKey: .showSingleSpaceAffordance) ?? false
    }
}

public struct SpaceConfig: Codable, Equatable, Identifiable, Sendable {
    public static let defaultName = "Main"
    public static let defaultEmoji = "🏠"

    public var id: String
    public var name: String
    public var emoji: String
    public var projectIds: [String]
    /// Current builds retain mixed Project and Workspace ordering here. `projectIds`
    /// stays as the downgrade-safe projection written for older builds.
    public var members: [SpaceMemberReference]?
    public var lastSelectedWorktreeId: String?
    public var createdAt: Date

    public init(id: String, name: String, emoji: String, projectIds: [String], members: [SpaceMemberReference]? = nil, lastSelectedWorktreeId: String? = nil, createdAt: Date) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.projectIds = projectIds
        self.members = members
        self.lastSelectedWorktreeId = lastSelectedWorktreeId
        self.createdAt = createdAt
    }
}

public enum SpaceIcon: Sendable {
    public static let emojiOptions = EmojiIcon.emojiOptions

    public static func sanitized(_ rawValue: String, fallback: String = SpaceConfig.defaultEmoji) -> String {
        EmojiIcon.sanitized(rawValue, fallback: fallback) ?? fallback
    }
}

public enum EmojiIcon: Sendable {
    public static let emojiOptions = ["🏠", "💼", "✨", "🚀", "🧪", "🎨", "📚", "🔧", "🌱", "🔥", "⭐️", "🧠"]

    public static func sanitized(_ rawValue: String?, fallback: String? = nil) -> String? {
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
