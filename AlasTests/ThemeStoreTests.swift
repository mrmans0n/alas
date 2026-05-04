import Testing
@testable import Alas

struct ThemeStoreTests {
    @Test func defaultIsCoolSlate() throws {
        let store = try ThemeStore()
        #expect(store.current.id == "cool-slate")
    }

    @Test func switchChangesCurrent() throws {
        let store = try ThemeStore()
        try store.activate(id: "warm-amber")
        #expect(store.current.id == "warm-amber")
    }

    @Test func switchToUnknownThrows() throws {
        let store = try ThemeStore()
        #expect(throws: Error.self) {
            try store.activate(id: "nope")
        }
    }
}
