import Foundation
import Testing
@testable import Alas

@MainActor
struct SidebarVisibilityTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func toggleSidebarVisibilityHidesAndShowsAgain() {
        let state = AppState(store: MemoryStore())
        #expect(state.config.sidebarVisible)

        state.toggleSidebarVisibility()
        #expect(!state.config.sidebarVisible)

        state.toggleSidebarVisibility()
        #expect(state.config.sidebarVisible)
    }
}
