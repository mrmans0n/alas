import Foundation
import SwiftUI

struct Theme: Codable, Equatable {
    let id: String
    let name: String
    let tokens: [String: String]   // raw OKLCH strings

    /// Optional runtime override for `accent` (and `accent-soft`). Set by
    /// `ThemeStore.setAccent(_:)` based on `config.accent`. Stored as a hex
    /// SwiftUI Color via the Color(hex:) extension so we can also derive a
    /// muted variant if needed in future.
    var accentOverrideHex: String? = nil

    enum CodingKeys: String, CodingKey { case id, name, tokens }

    static let bundledIds = ["cool-slate", "light"]

    /// Hex strings for the 5 named accents in AppearancePane.
    /// Keep in sync with the picker's `accents` array.
    static let accentHexById: [String: String] = [
        "teal":  "#5fb7c4",
        "mint":  "#7fc6a8",
        "amber": "#d3a25c",
        "coral": "#d77b88",
        "iris":  "#9789c7",
    ]

    /// Whether this theme is a dark variant. Drives `NSApp.appearance`
    /// so system materials (sidebar vibrancy, scrollers, focus rings)
    /// render the right way for the in-app theme. The convention is
    /// "everything except the explicit `light` theme is dark"; the
    /// `light` id is the only one of its kind we ship.
    var darkMode: Bool { id != "light" }

    static func loadBundled(id: String) throws -> Theme {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json") else {
            throw NSError(domain: "Theme", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing theme \(id)"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Theme.self, from: data)
    }

    func color(_ token: String) -> Color {
        // Accent override wins over the theme JSON when set (so the
        // settings-pane picker actually changes the chrome).
        if let hex = accentOverrideHex {
            if token == "accent" {
                return Color(hex: hex)
            }
            if token == "accent-soft" {
                return Color(hex: hex).opacity(0.18)
            }
        }
        guard let raw = tokens[token],
              let parsed = try? OKLCH.parse(raw) else {
            return .pink   // sentinel, easy to spot
        }
        return parsed.toColor()
    }
}
