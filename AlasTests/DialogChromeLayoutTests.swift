import Testing
@testable import Alas

struct DialogChromeLayoutTests {
    @Test("project dialogs reserve enough width for icon controls")
    func projectDialogWidthFitsIconControls() {
        #expect(DialogContainerLayout.projectWidth >= 640)
    }

}
