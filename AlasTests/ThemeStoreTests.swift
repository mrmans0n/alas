import Foundation
import Testing
@testable import Alas

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
}
