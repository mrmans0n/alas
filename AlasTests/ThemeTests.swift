import Testing
import AppKit
import SwiftUI
@testable import Alas

struct ThemeTests {
    @Test func decodesBundledCoolSlate() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        #expect(theme.id == "cool-slate")
        #expect(theme.name == "Cool Slate")
        #expect(theme.tokens["accent"] != nil)
    }

    @Test func decodesBundledLight() throws {
        let theme = try Theme.loadBundled(id: "light")
        #expect(theme.id == "light")
        #expect(theme.name == "Light")
        #expect(theme.tokens["accent"] != nil)
    }

    @Test func bundledIdsAreLightAndDark() {
        #expect(Theme.bundledIds.sorted() == ["cool-slate", "light"])
    }

    @Test func bundledThemesPrecomputeTokenColors() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        #expect(theme.resolvedColors.count == theme.tokens.count)
        #expect(theme.resolvedColors["fg"] != nil)
        #expect(theme.resolvedColors["accent"] != nil)
    }

    @Test func themeEqualityIgnoresDerivedColorCache() throws {
        let cached = try Theme.loadBundled(id: "cool-slate")
        let uncached = Theme(id: cached.id, name: cached.name, tokens: cached.tokens)
        #expect(cached == uncached)
    }

    @Test func colorLookupUsesAccentOverrideBeforePrecomputedToken() throws {
        var theme = try Theme.loadBundled(id: "cool-slate")
        theme.accentOverrideHex = "#123456"
        #expect(theme.color("accent") == Color(hex: "#123456"))
    }

    @Test func lightThemeDarkensAccentOverride() throws {
        var theme = try Theme.loadBundled(id: "light")
        theme.accentOverrideHex = "#5fb7c4"
        #expect(theme.color("accent") == Color.blend(Color(hex: "#5fb7c4"), .black, t: 0.45))
    }

    @Test func colorLookupUsesRuntimeOverrideBeforePrecomputedToken() throws {
        var theme = try Theme.loadBundled(id: "cool-slate")
        theme.resolvedColorOverrides["fg"] = .white
        #expect(theme.color("fg") == .white)
    }

    @Test func darkModeIsFalseForLight() throws {
        let theme = try Theme.loadBundled(id: "light")
        #expect(theme.darkMode == false)
    }

    @Test func darkModeIsTrueForCoolSlate() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        #expect(theme.darkMode == true)
    }

    @Test(arguments: CodePalette.families.flatMap { [$0.light, $0.dark] }.compactMap { $0 })
    func bundledCodePaletteLoadsEverySlot(id: String) throws {
        // `loadBundled` returns nil unless every slot parses as #rrggbb,
        // so non-nil proves the file is bundled and complete.
        let palette = try #require(CodePalette.loadBundled(id: id))
        #expect(palette.id == id)
    }

    @Test func drawingColorIsStandardSRGBWithTheSameComponents() throws {
        // Extended-sRGB colors make Core Graphics look up content headroom on
        // every draw call; drawing colors must land in standard sRGB.
        let theme = try Theme.loadBundled(id: "cool-slate")
        let color = theme.color("add").opacity(0.24)
        let drawing = NSColor.drawingColor(color)
        let bridged = try #require(NSColor(color).usingColorSpace(.extendedSRGB))
        #expect(drawing.cgColor.colorSpace?.name == CGColorSpace.sRGB)
        for (lhs, rhs) in zip(drawing.cgColor.components ?? [], bridged.cgColor.components ?? []) {
            #expect(abs(lhs - rhs) < 1e-5)
        }
    }
}
