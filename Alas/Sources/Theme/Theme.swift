import AppKit
import Foundation
import SwiftUI

struct Theme: Codable, Equatable, Hashable {
    let id: String
    let name: String
    let tokens: [String: String]   // raw OKLCH strings

    /// Optional runtime override for `accent` (and `accent-soft`). Set by
    /// `ThemeStore.setAccent(_:)` based on `config.accent`. Stored as a hex
    /// SwiftUI Color via the Color(hex:) extension so we can also derive a
    /// muted variant if needed in future.
    var accentOverrideHex: String? = nil {
        didSet { accentOverride = accentOverrideHex.map { Theme.resolvedAccentColor(hex: $0, darkMode: darkMode) } }
    }

    /// `accentOverrideHex` resolved once per assignment.
    private(set) var accentOverride: Color? = nil

    /// The named accents are pastels tuned for dark surfaces; on the light
    /// theme they wash out (and `accent-soft` vanishes), so they are
    /// darkened until text in them clears 4.5:1 on the light section-header
    /// band. Also used by `AppearancePane` to preview swatches as-applied.
    static func resolvedAccentColor(hex: String, darkMode: Bool) -> Color {
        darkMode ? Color(hex: hex) : Color.blend(Color(hex: hex), .black, t: 0.45)
    }

    /// Token-name → precomputed `Color` overrides that win over the raw
    /// OKLCH lookup. Populated by `applyingSidebarTextContrast(_:)` when
    /// a non-zero contrast is requested. Excluded from `Codable` (see
    /// `CodingKeys`) because `Color` is not directly Codable and these
    /// are purely runtime-derived.
    var resolvedColorOverrides: [String: Color] = [:]

    /// Token-name → precomputed `Color` values derived from `tokens`.
    /// Populated when bundled themes load so `color(_:)` does not parse and
    /// convert OKLCH strings during every SwiftUI body pass.
    private(set) var resolvedColors: [String: Color] = [:]

    /// Editor palette for code surfaces, resolved by `ThemeStore` from the
    /// user's code theme family. `nil` = use this theme's syntax tokens.
    /// Runtime-only: excluded from `Codable` via `CodingKeys`.
    var codePalette: CodePalette? = nil

    enum CodingKeys: String, CodingKey { case id, name, tokens }

    static func == (lhs: Theme, rhs: Theme) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.tokens == rhs.tokens
            && lhs.accentOverrideHex == rhs.accentOverrideHex
            && lhs.resolvedColorOverrides == rhs.resolvedColorOverrides
            && lhs.codePalette == rhs.codePalette
    }

    // Hashes exactly the fields `==` compares; `resolvedColors` stays
    // excluded from both because it is derived from `tokens`.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(tokens)
        hasher.combine(accentOverrideHex)
        hasher.combine(resolvedColorOverrides)
        hasher.combine(codePalette?.id)
    }

    static let bundledIds = ["cool-slate", "light"]

    /// Last-resort theme used when no bundled theme resource can be loaded
    /// (e.g. missing bundle resources). Renders plain but keeps the app
    /// running; `color(_:)` returns its pink sentinel for missing tokens.
    static let fallback = Theme(id: "fallback", name: "Fallback", tokens: [:])

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
        var theme = try JSONDecoder().decode(Theme.self, from: data)
        theme.resolvedColors = precomputedColors(from: theme.tokens)
        return theme
    }

    func color(_ token: String) -> Color {
        if let override = resolvedColorOverrides[token] {
            return override
        }
        if let accent = accentOverride {
            if token == "accent" {
                return accent
            }
            if token == "accent-soft" {
                // Matches the bundled `accent-soft` alpha of each theme.
                return accent.opacity(darkMode ? 0.18 : 0.30)
            }
        }
        if let resolved = resolvedColors[token] {
            return resolved
        }
        guard let raw = tokens[token],
              let parsed = try? OKLCH.parse(raw) else {
            return .pink   // sentinel, easy to spot
        }
        return parsed.toColor()
    }

    private static func precomputedColors(from tokens: [String: String]) -> [String: Color] {
        var colors: [String: Color] = [:]
        colors.reserveCapacity(tokens.count)
        for (token, raw) in tokens {
            guard let parsed = try? OKLCH.parse(raw) else { continue }
            colors[token] = parsed.toColor()
        }
        return colors
    }
}

extension Theme {
    static let sidebarTextContrastTokens: [String] = [
        "fg", "fg-muted", "fg-dim", "fg-faint",
    ]

    /// Returns a copy of this theme where the sidebar fg tokens have been
    /// blended `value` (clamped to 0…1) of the way toward maximum contrast.
    /// Maximum contrast = white for dark themes, black for light themes.
    /// `value == 0` returns the receiver unchanged.
    func applyingSidebarTextContrast(_ value: Double) -> Theme {
        let t = max(0, min(1, value))
        if t == 0 { return self }
        let target: Color = darkMode ? .white : .black
        var copy = self
        var overrides = resolvedColorOverrides
        for token in Theme.sidebarTextContrastTokens {
            let base = self.color(token)
            overrides[token] = Color.blend(base, target, t: t)
        }
        copy.resolvedColorOverrides = overrides
        return copy
    }
}

extension Color {
    /// Linear blend in sRGB. `t == 0` → `a`, `t == 1` → `b`.
    static func blend(_ a: Color, _ b: Color, t: Double) -> Color {
        if t <= 0 { return a }
        if t >= 1 { return b }
        let aN = NSColor(a).usingColorSpace(.sRGB) ?? NSColor(a)
        let bN = NSColor(b).usingColorSpace(.sRGB) ?? NSColor(b)
        let r  = aN.redComponent   + (bN.redComponent   - aN.redComponent)   * CGFloat(t)
        let g  = aN.greenComponent + (bN.greenComponent - aN.greenComponent) * CGFloat(t)
        let bl = aN.blueComponent  + (bN.blueComponent  - aN.blueComponent)  * CGFloat(t)
        let al = aN.alphaComponent + (bN.alphaComponent - aN.alphaComponent) * CGFloat(t)
        return Color(.sRGB, red: r, green: g, blue: bl, opacity: al)
    }
}

extension Theme {
    /// `color(_:)` as an AppKit drawing color; see `NSColor.drawingColor(_:)`.
    func nsColor(_ token: String) -> NSColor {
        NSColor.drawingColor(color(token))
    }
}

extension NSColor {
    /// Bridges a static SwiftUI color to an AppKit drawing color in standard
    /// sRGB. `NSColor(color)` alone lands in extended sRGB, and Core Graphics
    /// checks the content headroom of every extended-range color it records
    /// into a layer's display list (a ColorSync profile lookup per draw call),
    /// which roughly doubles the draw cost of color-dense text such as diffs.
    /// Theme colors are clipped to 0...1, so the conversion is lossless.
    ///
    /// Only for static colors (theme tokens and values derived from them).
    /// Converting a dynamic or catalog color freezes it to the current
    /// appearance.
    static func drawingColor(_ color: Color) -> NSColor {
        let bridged = NSColor(color)
        return bridged.usingColorSpace(.sRGB) ?? bridged
    }

    /// Resolves per appearance, so AppKit drawing with no `Theme` in reach
    /// still follows the in-app theme (which drives `NSApp.appearance`).
    static func appearanceAware(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    /// Label color for text over a translucent wash of `self`: lightened on
    /// dark surfaces, darkened on light ones so it keeps its contrast.
    var chipLabelColor: NSColor {
        .appearanceAware(
            dark: blended(withFraction: 0.55, of: .white) ?? .white,
            light: blended(withFraction: 0.45, of: .black) ?? .black
        )
    }
}
