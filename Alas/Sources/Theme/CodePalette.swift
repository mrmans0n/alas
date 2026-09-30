import AppKit
import Foundation

/// A bundled editor color theme variant (e.g. "Solarized Dark"). Applied to
/// code surfaces through `Theme.codePalette`; `nil` there means the app
/// theme's own syntax tokens ("Default").
struct CodePalette: Equatable {
    let id: String
    let name: String
    let bg, fg, gutterFG, selection: NSColor
    let comment, keyword, string, number, type, function, constant, attribute: NSColor

    static func == (lhs: CodePalette, rhs: CodePalette) -> Bool { lhs.id == rhs.id }

    struct Family: Identifiable {
        let id: String
        let name: String
        let light: String?
        let dark: String?
    }

    static let families: [Family] = [
        Family(id: "default", name: "Default", light: nil, dark: nil),
        Family(id: "ayu", name: "Ayu", light: "ayu-light", dark: "ayu-mirage"),
        Family(id: "catppuccin", name: "Catppuccin", light: "catppuccin-latte", dark: "catppuccin-mocha"),
        Family(id: "dracula", name: "Dracula", light: nil, dark: "dracula"),
        Family(id: "github", name: "GitHub", light: "github-light", dark: "github-dark"),
        Family(id: "gruvbox", name: "Gruvbox", light: "gruvbox-light", dark: "gruvbox-dark"),
        Family(id: "nord", name: "Nord", light: nil, dark: "nord"),
        Family(id: "one", name: "One", light: "one-light", dark: "one-dark"),
        Family(id: "solarized", name: "Solarized", light: "solarized-light", dark: "solarized-dark"),
        Family(id: "tokyo-night", name: "Tokyo Night", light: "tokyo-night-day", dark: "tokyo-night-night"),
    ]

    /// Unknown families and unloadable palettes resolve to nil (Default).
    static func resolve(family: String, darkMode: Bool) -> CodePalette? {
        guard let entry = families.first(where: { $0.id == family }),
              let id = darkMode ? entry.dark : entry.light else { return nil }
        return loadBundled(id: id)
    }

    static func loadBundled(id: String) -> CodePalette? {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            #if DEBUG
            NSLog("CodePalette: failed to load \(id)")
            #endif
            return nil
        }
        return CodePalette(file: file)
    }

    private struct File: Decodable {
        let id: String
        let name: String
        let colors: [String: String]
    }

    private init?(file: File) {
        func c(_ key: String) -> NSColor? { file.colors[key].flatMap(Self.parseHex) }
        guard let bg = c("bg"), let fg = c("fg"), let gutterFG = c("gutter-fg"),
              let selection = c("selection"), let comment = c("comment"),
              let keyword = c("keyword"), let string = c("string"), let number = c("number"),
              let type = c("type"), let function = c("function"),
              let constant = c("constant"), let attribute = c("attribute") else { return nil }
        self.id = file.id
        self.name = file.name
        self.bg = bg; self.fg = fg; self.gutterFG = gutterFG; self.selection = selection
        self.comment = comment; self.keyword = keyword; self.string = string; self.number = number
        self.type = type; self.function = function; self.constant = constant; self.attribute = attribute
    }

    /// Strict `#rrggbb`; anything else is rejected so typos fail the test.
    private static func parseHex(_ raw: String) -> NSColor? {
        guard raw.count == 7, raw.hasPrefix("#"),
              let value = UInt32(raw.dropFirst(), radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
