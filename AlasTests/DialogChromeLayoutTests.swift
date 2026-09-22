import CoreGraphics
import Testing
@testable import Alas

struct DialogChromeLayoutTests {
    @Test("project dialogs reserve enough width for icon controls")
    func projectDialogWidthFitsIconControls() {
        #expect(DialogContainerLayout.projectWidth >= 640)
    }

    /// A dialog body is capped so the footer stays on screen. The cap has to
    /// leave room for the chrome around it, and has to stop shrinking before
    /// the body becomes a letterbox on a short screen.
    @Test("the body cap leaves room for chrome and never collapses")
    func bodyHeightCapLeavesRoomForChrome() {
        let screen: CGFloat = 900
        let laptop = DialogContainerLayout.bodyMaxHeight(availableHeight: screen)
        let expected: CGFloat = screen - DialogContainerLayout.chromeHeight
        #expect(laptop == expected)
        // Whatever the cap is, body plus chrome has to fit on the screen.
        #expect(laptop + DialogContainerLayout.chromeHeight <= screen)
        #expect(laptop > DialogContainerLayout.minimumBodyHeight)

        // A taller display gets a taller body rather than a fixed one.
        #expect(DialogContainerLayout.bodyMaxHeight(availableHeight: 1_400) > laptop)

        // Below the floor the cap stops following the screen, so the body
        // keeps a usable height even if the dialog then overflows.
        #expect(DialogContainerLayout.bodyMaxHeight(availableHeight: 300) == DialogContainerLayout.minimumBodyHeight)
        #expect(DialogContainerLayout.bodyMaxHeight(availableHeight: 0) == DialogContainerLayout.minimumBodyHeight)
    }
}
