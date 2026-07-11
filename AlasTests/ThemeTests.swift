import Testing
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
}
