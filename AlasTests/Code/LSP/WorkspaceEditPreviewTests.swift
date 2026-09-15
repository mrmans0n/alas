import Foundation
import Testing
@testable import Alas

@MainActor
struct WorkspaceEditPreviewTests {
    private let a = EditorDocumentID(host: nil, worktreeID: "w", uri: "file:///workspace/a")
    private let b = EditorDocumentID(host: nil, worktreeID: "w", uri: "file:///workspace/b")

    private func plan(_ changes: [LSPDocumentChange]) throws -> WorkspaceEditPlan {
        try WorkspaceEditPlanner.plan(edit: .init(documentChanges: changes), context: .init(document: a, version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))), snapshots: [
            a: .init(document: a, content: Data("old".utf8), bufferVersion: 1, isOpen: true),
            b: .init(document: b, content: Data("old".utf8))
        ])
    }

    private func edit(_ document: EditorDocumentID) -> LSPDocumentChange {
        .textDocument(document: .init(uri: document.uri, version: nil), edits: [.init(range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 3)), newText: "new")])
    }

    @Test func previewPolicyAndWholePlan() throws {
        for changes in [[edit(b)], [edit(a), edit(b)], [.delete(uri: b.uri, options: .init(), annotationID: nil)]] {
            let plan = try plan(changes)
            #expect(plan.requiresPreview)
            let model = WorkspaceEditPreviewModel(plan: plan) { received in
                #expect(received == plan)
                return .applied(UUID())
            }
            #expect(model.plan == plan)
            #expect(model.fileCount == Set(plan.steps.map(\.document)).count)
        }
        #expect(try !plan([edit(a)]).requiresPreview)
    }

    @Test func staleApplyRetainsPlanAndError() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        let plan = fixture.plan
        let model = WorkspaceEditPreviewModel(plan: plan) { await fixture.executor.apply($0) }
        fixture.access.files[fixture.b] = .init(document: fixture.b, content: Data("changed after preview".utf8))
        #expect(await model.apply() == false)
        #expect(model.plan == plan)
        #expect(model.errorMessage?.contains("b") == true)
        #expect(!model.isApplying)
        #expect(!fixture.access.calls.contains(where: { $0.hasPrefix("write:") }))
    }

    @Test func uncertainOutcomeDisablesRetry() async throws {
        let model = WorkspaceEditPreviewModel(plan: try plan([edit(b)])) { _ in .recoveryRequired(UUID(), "Connection lost") }
        #expect(await model.apply() == false)
        #expect(model.requiresRecovery)
        #expect(model.errorMessage?.contains("Connection lost") == true)
    }

    @Test func resourcePreviewIncludesDestinationAndDiff() throws {
        let plan = try plan([
            .rename(oldURI: a.uri, newURI: b.uri, options: .init(overwrite: true), annotationID: nil),
            edit(b)
        ])
        let model = WorkspaceEditPreviewModel(plan: plan) { _ in .applied(UUID()) }
        #expect(plan.requiresPreview)
        #expect(model.fileCount == 2)
        #expect(model.diffs[1].map(\.prefix) == ["−", "+"])
        #expect(model.diffs[1].map(\.text) == ["old", "new"])
    }

    @Test func renameOverwriteDiffShowsDiscardedDestinationContent() {
        let source = WorkspaceFileSnapshot(document: a, content: Data("source text".utf8))
        let destination = WorkspaceFileSnapshot(document: b, content: Data("unsaved destination".utf8), isOpen: true, isDirty: true)
        let step = WorkspaceEditPlanStep(kind: .rename, document: a, destination: b, before: source,
                                         after: source.replacing(document: b, content: source.content), destinationBefore: destination,
                                         annotationID: nil, annotationIDs: [], resourceOptions: nil)
        let diff = WorkspaceEditPreviewModel.diff(step)
        #expect(diff.map(\.text) == ["unsaved destination", "source text"])
        #expect(diff.map(\.prefix) == ["−", "+"])
    }
}
