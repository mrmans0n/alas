import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct HoverWindowControllerTests {
    @Test func isVisibleStartsFalse() {
        let controller = HoverWindowController()
        #expect(controller.isVisible == false)
    }
}
