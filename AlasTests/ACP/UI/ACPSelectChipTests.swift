import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite("ACP select chip")
struct ACPSelectChipTests {
    @Test func labelForegroundPreservesDarkModeTreatment() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let accent = theme.color("accent")
        let foreground = ACPSelectChip.labelForeground(accent: accent, theme: theme)
        let existing = Color.blend(accent, .white, t: 0.55)

        #expect(Self.colorComponents(foreground).isClose(to: Self.colorComponents(existing)))
    }

    @Test func labelForegroundPreservesDarkModeTreatmentForAccentOverrides() throws {
        let baseTheme = try Theme.loadBundled(id: "cool-slate")

        for hex in Theme.accentHexById.values {
            var theme = baseTheme
            theme.accentOverrideHex = hex
            let accent = theme.color("accent")
            let foreground = ACPSelectChip.labelForeground(accent: accent, theme: theme)
            let existing = Color.blend(accent, .white, t: 0.55)

            #expect(Self.colorComponents(foreground).isClose(to: Self.colorComponents(existing)))
        }
    }

    @Test func labelForegroundImprovesLightModeContrast() throws {
        let theme = try Theme.loadBundled(id: "light")
        let accent = theme.color("accent")
        let chipBackground = Self.composited(foreground: accent, alpha: 0.18, over: theme.color("bg-1"))
        let previousForeground = Color.blend(accent, .white, t: 0.55)
        let foreground = ACPSelectChip.labelForeground(accent: accent, theme: theme)

        #expect(Self.contrastRatio(foreground, chipBackground) > Self.contrastRatio(previousForeground, chipBackground))
        #expect(Self.contrastRatio(foreground, chipBackground) >= 4.5)
    }

    @Test func labelForegroundMeetsLightModeContrastForAccentOverrides() throws {
        let baseTheme = try Theme.loadBundled(id: "light")

        for (id, hex) in Theme.accentHexById {
            var theme = baseTheme
            theme.accentOverrideHex = hex
            let accent = theme.color("accent")
            let chipBackground = Self.composited(foreground: accent, alpha: 0.18, over: theme.color("bg-1"))
            let previousForeground = Color.blend(accent, .white, t: 0.55)
            let foreground = ACPSelectChip.labelForeground(accent: accent, theme: theme)

            #expect(Self.contrastRatio(foreground, chipBackground) > Self.contrastRatio(previousForeground, chipBackground), "\(id) should improve contrast over the previous dark-mode treatment")
            #expect(Self.contrastRatio(foreground, chipBackground) >= 4.5, "\(id) should meet AA contrast")
        }
    }

    private struct Components {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        func isClose(to other: Components, tolerance: Double = 0.001) -> Bool {
            abs(red - other.red) <= tolerance
                && abs(green - other.green) <= tolerance
                && abs(blue - other.blue) <= tolerance
                && abs(alpha - other.alpha) <= tolerance
        }
    }

    private static func colorComponents(_ color: Color) -> Components {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return Components(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            alpha: Double(nsColor.alphaComponent)
        )
    }

    private static func composited(foreground: Color, alpha: Double, over background: Color) -> Color {
        let fg = colorComponents(foreground)
        let bg = colorComponents(background)
        let a = max(0, min(1, alpha))
        return Color(
            .sRGB,
            red: fg.red * a + bg.red * (1 - a),
            green: fg.green * a + bg.green * (1 - a),
            blue: fg.blue * a + bg.blue * (1 - a),
            opacity: fg.alpha * a + bg.alpha * (1 - a)
        )
    }

    private static func contrastRatio(_ lhs: Color, _ rhs: Color) -> Double {
        let l1 = relativeLuminance(lhs)
        let l2 = relativeLuminance(rhs)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func relativeLuminance(_ color: Color) -> Double {
        let c = colorComponents(color)
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }
}
