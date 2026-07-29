import Foundation
import Testing
@testable import Alas

@MainActor
struct RunScriptPaletteModelTests {
    private func script(_ name: String, scope: RunScriptScope = .repo) -> RunScript {
        RunScript(
            scope: scope, fileName: "\(name).sh",
            fileURL: URL(fileURLWithPath: "/tmp/\(name).sh"),
            displayName: name, onExit: .keep, cwd: nil, isExecutable: true
        )
    }

    private func environment(
        scripts: [RunScript],
        onRun: @escaping (RunScript) -> Void = { _ in },
        onRestart: @escaping (RunScript) -> Void = { _ in },
        onEdit: @escaping (RunScript) -> Void = { _ in },
        onNew: @escaping (RunScriptScope) -> Void = { _ in }
    ) -> RunScriptPaletteEnvironment {
        RunScriptPaletteEnvironment(
            scripts: { scripts },
            isRunning: { _ in false },
            run: onRun, restart: onRestart, edit: onEdit, newScript: onNew
        )
    }

    @Test func rowsAreSectionedWithTrailingNewActions() {
        let model = RunScriptPaletteModel()
        model.load(environment: environment(scripts: [
            script("build"), script("deploy", scope: .global),
        ]))
        let rows = model.rows()
        #expect(rows == [
            .header("Repo"), .script(script("build")),
            .header("Global"), .script(script("deploy", scope: .global)),
            .newRepoScript, .newGlobalScript,
        ])
    }

    @Test func queryFiltersAndHidesNewActions() {
        let model = RunScriptPaletteModel()
        model.load(environment: environment(scripts: [script("build"), script("bench")]))
        model.query = "bu"
        #expect(model.rows() == [.header("Repo"), .script(script("build"))])
    }

    @Test func initialSelectionSkipsHeader() {
        let model = RunScriptPaletteModel()
        model.load(environment: environment(scripts: [script("build")]))
        #expect(model.rows()[model.selectedIndex] == .script(script("build")))
    }

    @Test func enterRunsSelectedScript() {
        var ran: RunScript?
        let model = RunScriptPaletteModel()
        let env = environment(scripts: [script("build")], onRun: { ran = $0 })
        model.load(environment: env)
        model.activateSelection(environment: env)
        #expect(ran == script("build"))
    }

    @Test func enterEditsSelectedScriptInEditMode() {
        var ran: RunScript?
        var edited: RunScript?
        let model = RunScriptPaletteModel()
        let env = environment(
            scripts: [script("build")],
            onRun: { ran = $0 },
            onEdit: { edited = $0 }
        )
        model.prepareForOpen(mode: .edit)
        model.load(environment: env)
        model.activateSelection(environment: env)
        #expect(ran == nil)
        #expect(edited == script("build"))
    }

    @Test func newRowsInvokeNewScript() {
        var newScope: RunScriptScope?
        let model = RunScriptPaletteModel()
        let env = environment(scripts: [], onNew: { newScope = $0 })
        model.load(environment: env)
        // Rows: [.newRepoScript, .newGlobalScript]; move to the second one.
        model.moveSelection(step: 1)
        model.activateSelection(environment: env)
        #expect(newScope == .global)
    }

    @Test func editSelectionUsesEditClosure() {
        var edited: RunScript?
        let model = RunScriptPaletteModel()
        let env = environment(scripts: [script("build")], onEdit: { edited = $0 })
        model.load(environment: env)
        model.editSelection(environment: env)
        #expect(edited == script("build"))
    }
}
