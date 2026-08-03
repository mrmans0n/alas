import Testing
@testable import Alas

struct DialogChromeLayoutTests {
    @Test("project dialogs reserve enough width for icon controls")
    func projectDialogWidthFitsIconControls() {
        #expect(DialogContainerLayout.projectWidth >= 640)
    }

    @Test("Mission confirmation reserves room for the issue and prompt")
    func missionConfirmationWidthFitsEditableDraft() {
        #expect(NewMissionDialog.confirmationWidth >= DialogContainerLayout.projectWidth)
    }
}
