import Foundation
import SwiftUI

struct Theme: Codable, Equatable {
    let id: String
    let name: String
    let tokens: [String: String]   // raw OKLCH strings

    static let bundledIds = ["cool-slate", "warm-amber", "neutral", "light"]

    static func loadBundled(id: String) throws -> Theme {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json") else {
            throw NSError(domain: "Theme", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing theme \(id)"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Theme.self, from: data)
    }

    func color(_ token: String) -> Color {
        guard let raw = tokens[token],
              let parsed = try? OKLCH.parse(raw) else {
            return .pink   // sentinel, easy to spot
        }
        return parsed.toColor()
    }
}
