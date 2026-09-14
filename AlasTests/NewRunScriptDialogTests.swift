import Testing
@testable import Alas

struct NewRunScriptDialogTests {
    private let gradle = RunScriptStackDetection(stack: .gradle, context: .init(hasWrapper: true))
    private let cargo = RunScriptStackDetection(stack: .cargo, context: .init())

    @Test func repoScopeStartsFromFirstDetectedStack() {
        #expect(NewRunScriptDialog.initialStart(scope: .repo, detections: [gradle, cargo]) == .stack(.gradle))
    }

    @Test func repoScopeWithoutDetectionStartsBlank() {
        #expect(NewRunScriptDialog.initialStart(scope: .repo, detections: []) == .blank)
    }

    @Test func globalScopeIgnoresDetections() {
        #expect(NewRunScriptDialog.initialStart(scope: .global, detections: [gradle]) == .blank)
    }

    @Test func detectedStacksListFirstThenTheRest() {
        let ordered = NewRunScriptDialog.orderedStacks(detections: [cargo, gradle])
        #expect(ordered.detected == [.cargo, .gradle])
        #expect(ordered.others == RunScriptStack.allCases.filter { $0 != .cargo && $0 != .gradle })
    }

    @Test func defaultChecksComeFromDetectedContext() {
        let js = RunScriptStackDetection(stack: .javascript, context: .init(packageScripts: ["build"]))
        let checked = NewRunScriptDialog.defaultCheckedActionIDs(start: .stack(.javascript), detections: [js])
        #expect(checked == ["install", "build"])
        let rails = RunScriptStackDetection(stack: .rails, context: .init(hasRubocopConfig: false))
        let railsChecked = NewRunScriptDialog.defaultCheckedActionIDs(start: .stack(.rails), detections: [rails])
        #expect(!railsChecked.contains("lint"))
        #expect(NewRunScriptDialog.defaultCheckedActionIDs(start: .blank, detections: [js]).isEmpty)
    }

    @Test func undetectedStackChecksEverything() {
        let checked = NewRunScriptDialog.defaultCheckedActionIDs(start: .stack(.cargo), detections: [])
        #expect(checked == Set(RunScriptStackCatalog.actions(for: .cargo).map(\.id)))
    }

    @Test func confirmTitleReflectsMode() {
        #expect(NewRunScriptDialog.confirmTitle(start: .blank, selectedCount: 0, wantsWritingHelp: false) == "Create script")
        #expect(NewRunScriptDialog.confirmTitle(start: .blank, selectedCount: 0, wantsWritingHelp: true) == "Create script and open chat")
        #expect(NewRunScriptDialog.confirmTitle(start: .stack(.cargo), selectedCount: 1, wantsWritingHelp: true) == "Create 1 script")
        #expect(NewRunScriptDialog.confirmTitle(start: .stack(.cargo), selectedCount: 4, wantsWritingHelp: false) == "Create 4 scripts")
    }

    @Test func commandPreviewSkipsLeadingComments() {
        let dev = RunScriptStackCatalog.actions(for: .javascript, context: .init(packageManager: .pnpm)).first { $0.id == "dev" }!
        #expect(NewRunScriptDialog.commandPreview(for: dev) == "pnpm run dev")
        let build = RunScriptStackCatalog.actions(for: .cargo).first { $0.id == "build" }!
        #expect(NewRunScriptDialog.commandPreview(for: build) == "cargo build")
    }
}
