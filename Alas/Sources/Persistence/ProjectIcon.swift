import Foundation

struct ProjectIcon: Codable, Equatable {
    enum Mode: String, Codable, Equatable, Hashable, CaseIterable {
        case letter
        case symbol
        case emoji
        case image
    }

    static let defaultColor = "#5fb7c4"

    var mode: Mode
    var color: String
    var label: String?
    var symbolName: String?
    var emoji: String?
    var imagePath: String?

    enum CodingKeys: String, CodingKey {
        case mode, color, label, symbolName, emoji, imagePath, imageAssetName
    }

    init(
        mode: Mode,
        color: String,
        label: String? = nil,
        symbolName: String? = nil,
        emoji: String? = nil,
        imagePath: String? = nil
    ) {
        self.init(
            mode: mode,
            color: color,
            fallbackColor: Self.defaultColor,
            label: label,
            symbolName: symbolName,
            emoji: emoji,
            imagePath: imagePath
        )
    }

    private init(
        mode: Mode,
        color: String?,
        fallbackColor: String,
        label: String?,
        symbolName: String?,
        emoji: String?,
        imagePath: String?
    ) {
        self.mode = mode
        self.color = Self.sanitizedColor(color, fallback: fallbackColor)
        self.label = Self.sanitizedLabel(label)
        self.symbolName = Self.sanitizedNonEmpty(symbolName)
        self.emoji = Self.sanitizedEmoji(emoji)
        self.imagePath = Self.sanitizedNonEmpty(imagePath)
    }

    init(from decoder: Decoder) throws {
        self = try Self.decode(from: decoder, fallbackColor: Self.defaultColor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(symbolName, forKey: .symbolName)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
    }

    static func decode(from decoder: Decoder, fallbackColor: String) throws -> ProjectIcon {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        return ProjectIcon(
            mode: try c.decode(Mode.self, forKey: .mode),
            color: try? c.decode(String.self, forKey: .color),
            fallbackColor: fallbackColor,
            label: try? c.decode(String.self, forKey: .label),
            symbolName: try? c.decode(String.self, forKey: .symbolName),
            emoji: try? c.decode(String.self, forKey: .emoji),
            imagePath: (try? c.decode(String.self, forKey: .imagePath))
                ?? (try? c.decode(String.self, forKey: .imageAssetName))
        )
    }

    static func `default`(color: String = defaultColor) -> ProjectIcon {
        ProjectIcon(mode: .letter, color: color)
    }

    func withColor(_ color: String) -> ProjectIcon {
        ProjectIcon(
            mode: mode,
            color: color,
            label: label,
            symbolName: symbolName,
            emoji: emoji,
            imagePath: imagePath
        )
    }

    static func fallbackLabel(projectName: String) -> String {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = name.split(separator: "/").last.map(String.init) ?? name
        guard let first = tail.first else { return "?" }
        return String(first).uppercased()
    }

    static func sanitizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(2)).uppercased()
    }

    static func sanitizedColor(_ raw: String) -> String {
        normalizedHex(raw) ?? defaultColor
    }

    static func sanitizedColor(_ raw: String?, fallback: String) -> String {
        raw.flatMap(normalizedHex) ?? normalizedHex(fallback) ?? defaultColor
    }

    private static func normalizedHex(_ raw: String) -> String? {
        let value = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard value.count == 6,
              value.allSatisfy({ $0.isHexDigit })
        else {
            return nil
        }
        return "#\(value)"
    }

    static func sanitizedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sanitizedEmoji(_ raw: String?) -> String? {
        EmojiIcon.sanitized(raw)
    }
}
