import Foundation
import Testing
@testable import Alas

@MainActor
struct RightPaneVisibilityTests {
    @Test func toggleRightPaneVisibilityHidesAndShowsAgain() {
        let state = AppState(store: TestPersistenceStore())
        #expect(state.config.rightPaneVisible)

        state.toggleRightPaneVisibility()
        #expect(!state.config.rightPaneVisible)

        state.toggleRightPaneVisibility()
        #expect(state.config.rightPaneVisible)
    }
}
