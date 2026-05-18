import AppKit
import Testing
@testable import Alas

@MainActor
struct TabDragWindowShieldTests {
    @Test func shieldedTabDragViewDoesNotMoveWindowOnMouseDown() {
        let view = TabDragWindowShieldView()

        #expect(view.mouseDownCanMoveWindow == false)
    }
}
