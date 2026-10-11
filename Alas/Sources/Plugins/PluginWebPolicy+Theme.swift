import AppKit
import Foundation

extension PluginWebPolicy {
    /// The colors Alas's own views draw with (`Theme.nsColor`), so the user's accent and contrast overrides apply,
    /// written as numeric `rgb(…)` values: a theme file can't put arbitrary CSS into the shell. Tokens the theme
    /// lacks are left out, so the page falls back instead of getting the missing-token sentinel.
    static func cssVariables(_ theme: Theme) -> [String: String] {
        var variables: [String: String] = [:]
        for (variable, token) in themeVariables {
            let overridden = theme.resolvedColorOverrides[token] != nil || (token == "accent" && theme.accentOverride != nil)
            guard overridden || theme.tokens[token] != nil, let color = theme.nsColor(token).usingColorSpace(.sRGB) else { continue }
            func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            let alpha = String(format: "%.3f", min(max(color.alphaComponent, 0), 1))
            variables[variable] = "rgb(\(channel(color.redComponent)) \(channel(color.greenComponent)) \(channel(color.blueComponent)) / \(alpha))"
        }
        return variables
    }

    /// `alas.context` as JSON text: in the page script for a new document, and as the detail of `themeEvent` when the
    /// theme changes, passed as data.
    static func context(surface: PluginSurface, theme: Theme) -> String {
        struct Context: Encodable {
            let tab: Int?
            let panel: String?
            let theme: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let context = Context(tab: surface.tab, panel: surface.panel, theme: theme.darkMode ? "dark" : "light")
        let data = (try? encoder.encode(context)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
