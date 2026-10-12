import Foundation
import Testing
@testable import Alas

@MainActor
struct SidebarVisibilityTests {
    @Test func toggleSidebarVisibilityHidesAndShowsAgain() {
        let state = AppState(store: TestPersistenceStore())
        #expect(state.config.sidebarVisible)

        state.toggleSidebarVisibility()
        #expect(!state.config.sidebarVisible)

        state.toggleSidebarVisibility()
        #expect(state.config.sidebarVisible)
    }
}
