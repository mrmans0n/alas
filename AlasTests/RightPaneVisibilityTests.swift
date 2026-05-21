import Foundation
import Testing
@testable import Alas

@MainActor
struct RightPaneVisibilityTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func toggleRightPaneVisibilityHidesAndShowsAgain() {
        let state = AppState(store: MemoryStore())
        #expect(state.config.rightPaneVisible)

        state.toggleRightPaneVisibility()
        #expect(!state.config.rightPaneVisible)

        state.toggleRightPaneVisibility()
        #expect(state.config.rightPaneVisible)
    }
}
