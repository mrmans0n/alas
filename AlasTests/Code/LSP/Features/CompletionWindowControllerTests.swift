import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct CompletionWindowControllerTests {
    @Test("suggestion panel hides when the app deactivates")
    func suggestionPanelHidesWhenAppDeactivates() {
        #expect(CompletionWindowController.panelHidesOnDeactivate)
    }
}
