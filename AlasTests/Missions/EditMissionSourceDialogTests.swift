import Testing
@testable import Alas

@MainActor
struct EditMissionSourceDialogTests {
    @Test func editorTrimsTitleButPreservesContextFormatting() async {
        let recorder = ManualSourceEditRecorder()
        let model = EditMissionSourceDialogModel(
            source: MissionFixtures.manualSource(),
            save: recorder.save
        )
        model.title = "  Updated title  "
        model.body = "First line\n\nSecond line"

        #expect(await model.submit())
        #expect(recorder.title == "Updated title")
        #expect(recorder.body == "First line\n\nSecond line")
        #expect(model.title == "Updated title")
    }

    @Test func editorRejectsEmptyTitleWithoutSaving() async {
        let recorder = ManualSourceEditRecorder()
        let model = EditMissionSourceDialogModel(
            source: MissionFixtures.manualSource(),
            save: recorder.save
        )
        model.title = " \n "

        #expect(!(await model.submit()))
        #expect(model.errorMessage == "Enter a work-item title.")
        #expect(recorder.saveCount == 0)
    }
}

@MainActor
private final class ManualSourceEditRecorder {
    var title: String?
    var body: String?
    var saveCount = 0

    func save(title: String, body: String) async -> Bool {
        saveCount += 1
        self.title = title
        self.body = body
        return true
    }
}
