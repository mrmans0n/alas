import Foundation
import AlasFoundation

public struct ProjectIcon: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
        case letter
        case symbol
        case emoji
        case image
    }

    public static let defaultColor = "#5fb7c4"

    public var mode: Mode
    public var color: String
    public var label: String?
    public var symbolName: String?
    public var emoji: String?
    public var imagePath: String?
    /// Drops the squircle fill and tints the glyph with `color` instead.
    /// Ignored in `.image` mode, which never draws a background.
    public var transparentBackground: Bool

    public enum CodingKeys: String, CodingKey, Sendable {
        case mode, color, label, symbolName, emoji, imagePath, imageAssetName
        case transparentBackground
    }

    public init(
        mode: Mode,
        color: String,
        label: String? = nil,
        symbolName: String? = nil,
        emoji: String? = nil,
        imagePath: String? = nil,
        transparentBackground: Bool = false
    ) {
        self.init(
            mode: mode,
            color: color,
            fallbackColor: Self.defaultColor,
            label: label,
            symbolName: symbolName,
            emoji: emoji,
            imagePath: imagePath,
            transparentBackground: transparentBackground
        )
    }

    private init(
        mode: Mode,
        color: String?,
        fallbackColor: String,
        label: String?,
        symbolName: String?,
        emoji: String?,
        imagePath: String?,
        transparentBackground: Bool
    ) {
        self.mode = mode
        self.color = Self.sanitizedColor(color, fallback: fallbackColor)
        self.label = Self.sanitizedLabel(label)
        self.symbolName = Self.sanitizedNonEmpty(symbolName)
        self.emoji = Self.sanitizedEmoji(emoji)
        self.imagePath = Self.sanitizedNonEmpty(imagePath)
        self.transparentBackground = transparentBackground
    }

    public init(from decoder: Decoder) throws {
        self = try Self.decode(from: decoder, fallbackColor: Self.defaultColor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(symbolName, forKey: .symbolName)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
        // Omitted when opaque so existing files stay byte-identical.
        if transparentBackground {
            try c.encode(true, forKey: .transparentBackground)
        }
    }

    public static func decode(from decoder: Decoder, fallbackColor: String) throws -> ProjectIcon {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        return ProjectIcon(
            mode: try c.decode(Mode.self, forKey: .mode),
            color: try? c.decode(String.self, forKey: .color),
            fallbackColor: fallbackColor,
            label: try? c.decode(String.self, forKey: .label),
            symbolName: try? c.decode(String.self, forKey: .symbolName),
            emoji: try? c.decode(String.self, forKey: .emoji),
            imagePath: (try? c.decode(String.self, forKey: .imagePath))
                ?? (try? c.decode(String.self, forKey: .imageAssetName)),
            transparentBackground: (try? c.decode(Bool.self, forKey: .transparentBackground)) ?? false
        )
    }

    public static func `default`(color: String = defaultColor) -> ProjectIcon {
        ProjectIcon(mode: .letter, color: color)
    }

    public func withColor(_ color: String) -> ProjectIcon {
        ProjectIcon(
            mode: mode,
            color: color,
            label: label,
            symbolName: symbolName,
            emoji: emoji,
            imagePath: imagePath,
            transparentBackground: transparentBackground
        )
    }

    public static func fallbackLabel(projectName: String) -> String {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = name.split(separator: "/").last.map(String.init) ?? name
        guard let first = tail.first else { return "?" }
        return String(first).uppercased()
    }

    public static func sanitizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(2)).uppercased()
    }

    public static func sanitizedColor(_ raw: String) -> String {
        normalizedHex(raw) ?? defaultColor
    }

    public static func sanitizedColor(_ raw: String?, fallback: String) -> String {
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

    public static func sanitizedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func sanitizedEmoji(_ raw: String?) -> String? {
        EmojiIcon.sanitized(raw)
    }
}
