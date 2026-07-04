import Foundation

struct ProjectIcon: Codable, Equatable {
    enum Mode: String, Codable, Equatable, CaseIterable {
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
    var imageAssetName: String?

    enum CodingKeys: String, CodingKey {
        case mode, color, label, symbolName, emoji, imageAssetName
    }

    init(
        mode: Mode,
        color: String,
        label: String? = nil,
        symbolName: String? = nil,
        emoji: String? = nil,
        imageAssetName: String? = nil
    ) {
        self.mode = mode
        self.color = Self.sanitizedColor(color)
        self.label = Self.sanitizedLabel(label)
        self.symbolName = Self.sanitizedNonEmpty(symbolName)
        self.emoji = Self.sanitizedNonEmpty(emoji)
        self.imageAssetName = Self.sanitizedNonEmpty(imageAssetName)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try c.decode(Mode.self, forKey: .mode),
            color: (try? c.decode(String.self, forKey: .color)) ?? Self.defaultColor,
            label: try? c.decode(String.self, forKey: .label),
            symbolName: try? c.decode(String.self, forKey: .symbolName),
            emoji: try? c.decode(String.self, forKey: .emoji),
            imageAssetName: try? c.decode(String.self, forKey: .imageAssetName)
        )
    }

    static func `default`(color: String = defaultColor) -> ProjectIcon {
        ProjectIcon(mode: .letter, color: color)
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
        let value = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard value.count == 6,
              value.allSatisfy({ $0.isHexDigit })
        else {
            return defaultColor
        }
        return "#\(value)"
    }

    static func sanitizedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
