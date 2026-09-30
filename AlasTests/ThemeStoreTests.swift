import Foundation
import Testing
@testable import Alas

@MainActor
struct ThemeStoreTests {
    @Test func defaultIsCoolSlate() throws {
        let store = try ThemeStore()
        #expect(store.current.id == "cool-slate")
    }

    @Test func switchChangesCurrent() throws {
        let store = try ThemeStore()
        try store.activate(id: "light")
        #expect(store.current.id == "light")
    }

    @Test func switchToUnknownThrows() throws {
        let store = try ThemeStore()
        #expect(throws: Error.self) {
            try store.activate(id: "nope")
        }
    }

    @Test func matchSystemOffRestoresUserPick() throws {
        let store = try ThemeStore()
        try store.activate(id: "light")
        store.setMatchSystem(true)
        store.setMatchSystem(false)
        #expect(store.current.id == "light")
    }

    @Test func creatingUsesInitialIdWhenLoadable() {
        let store = ThemeStore.creating(initialId: "light")
        #expect(store.current.id == "light")
    }

    @Test func creatingFallsBackToBundledThemeWhenInitialIdMissing() {
        let store = ThemeStore.creating(initialId: "nope")
        #expect(store.current.id == "cool-slate")
    }

    @Test func creatingTriesPersistedThenBundledOrderWithInjectedLoader() {
        var requestedIds: [String] = []
        let store = ThemeStore.creating(initialId: "nope") { id in
            requestedIds.append(id)
            if id == "light" { return Theme(id: id, name: "Light", tokens: [:]) }
            throw NSError(domain: "Theme", code: 1)
        }
        #expect(requestedIds == ["nope", "cool-slate", "light"])
        #expect(store.current.id == "light")
    }

    @Test func creatingNeverThrowsWhenNothingLoads() {
        let store = ThemeStore.creating(initialId: "nope") { _ in
            throw NSError(domain: "Theme", code: 1)
        }
        #expect(store.current.id == "fallback")
    }

    @Test func failedActivationPreservesUserPick() throws {
        let store = try ThemeStore()
        try store.activate(id: "light")

        #expect(throws: Error.self) {
            try store.activate(id: "nope")
        }

        store.setMatchSystem(true)
        store.setMatchSystem(false)
        #expect(store.current.id == "light")
    }

    @Test(arguments: [
        ("solarized", "cool-slate", "solarized-dark"),
        ("solarized", "light", "solarized-light"),
        ("nord", "light", nil),
        ("default", "cool-slate", nil),
        ("monokai", "cool-slate", nil),
    ] as [(String, String, String?)])
    func codeThemeResolvesVariantFromAppTheme(family: String, appTheme: String, expected: String?) throws {
        let store = try ThemeStore()
        // Family first, app theme second: switching the app theme must
        // re-resolve the variant.
        store.setCodeTheme(family: family)
        try store.activate(id: appTheme)
        #expect(store.current.codePalette?.id == expected)
    }
}
