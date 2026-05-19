import Testing
import SwiftUI
@testable import Alas

struct ThemeSidebarContrastTests {
    @Test func zeroContrastReturnsUnchangedTheme() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let derived = theme.applyingSidebarTextContrast(0)
        #expect(derived.resolvedColorOverrides.isEmpty)
    }

    @Test func nonZeroContrastPopulatesOverridesForFgFamily() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let derived = theme.applyingSidebarTextContrast(0.5)
        #expect(derived.resolvedColorOverrides["fg"] != nil)
        #expect(derived.resolvedColorOverrides["fg-muted"] != nil)
        #expect(derived.resolvedColorOverrides["fg-dim"] != nil)
        #expect(derived.resolvedColorOverrides["fg-faint"] != nil)
        #expect(derived.resolvedColorOverrides["bg-0"] == nil)
        #expect(derived.resolvedColorOverrides["accent"] == nil)
    }

    @Test func fullContrastReturnsTargetForDarkTheme() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let derived = theme.applyingSidebarTextContrast(1)
        #expect(derived.resolvedColorOverrides["fg"] == Color.white)
    }

    @Test func fullContrastReturnsTargetForLightTheme() throws {
        let theme = try Theme.loadBundled(id: "light")
        let derived = theme.applyingSidebarTextContrast(1)
        #expect(derived.resolvedColorOverrides["fg"] == Color.black)
    }

    @Test func colorLookupUsesOverrideWhenPresent() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let derived = theme.applyingSidebarTextContrast(1)
        #expect(derived.color("fg") == Color.white)
    }

    @Test func colorLookupFallsThroughForUnsetTokens() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let derived = theme.applyingSidebarTextContrast(1)
        #expect(derived.color("bg-0") == theme.color("bg-0"))
    }

    @Test func clampsValuesOutsideZeroOne() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        #expect(theme.applyingSidebarTextContrast(-1).resolvedColorOverrides.isEmpty)
        let high = theme.applyingSidebarTextContrast(2)
        #expect(high.resolvedColorOverrides["fg"] == Color.white)
    }
}
