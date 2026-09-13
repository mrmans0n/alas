import Foundation
import Testing
@testable import Alas

struct WorkspaceEditPlannerTests {
    @Test func decodesResourceOperationWithoutDroppingIt() throws {
        let data = Data(#"{"documentChanges":[{"kind":"rename","oldUri":"file:///a","newUri":"file:///b"}]}"#.utf8)
        let edit = try JSONDecoder().decode(LSPWorkspaceEdit.self, from: data)

        #expect(edit.documentChanges?.count == 1)
        #expect(edit.documentChanges?.first == .rename(
            oldURI: "file:///a", newURI: "file:///b", options: .init(), annotationID: nil
        ))
    }

    @Test func plansCurrentDocumentEditsWithoutPreview() throws {
        let document = document("file:///workspace/main.swift")
        let context = context(for: document, version: 7)
        let edit = LSPWorkspaceEdit(documentChanges: [
            .textDocument(
                document: .init(uri: document.uri, version: 7),
                edits: [LSPTextEdit(range: range(0, 4, 0, 5), newText: "B")]
            )
        ])

        let plan = try WorkspaceEditPlanner.plan(edit: edit, context: context, snapshots: [
            document: snapshot(document, content: "let a = 1", version: 7)
        ])

        #expect(!plan.requiresPreview)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].after.content == Data("let B = 1".utf8))
    }

    @Test func rejectsStaleDocumentVersion() {
        let document = document("file:///workspace/main.swift")
        let edit = LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: document.uri, version: 3), edits: [])
        ])

        #expect(throws: WorkspaceEditPlanner.Error.staleVersion.self) {
            try WorkspaceEditPlanner.plan(edit: edit, context: context(for: document, version: 4), snapshots: [
                document: snapshot(document, content: "text", version: 4)
            ])
        }
    }

    @Test func rejectsMissingSnapshot() {
        let document = document("file:///workspace/main.swift")
        let other = self.document("file:///workspace/other.swift")
        let edit = LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: other.uri, version: nil), edits: [])
        ])

        #expect(throws: WorkspaceEditPlanner.Error.missingSnapshot.self) {
            try WorkspaceEditPlanner.plan(edit: edit, context: context(for: document), snapshots: [:])
        }
    }

    @Test func rejectsMalformedAndOverlappingRanges() {
        let document = document("file:///workspace/main.swift")
        let malformed = LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: document.uri, version: nil), edits: [
                LSPTextEdit(range: range(0, 5, 0, 2), newText: "")
            ])
        ])
        let overlap = LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: document.uri, version: nil), edits: [
                LSPTextEdit(range: range(0, 0, 0, 2), newText: "A"),
                LSPTextEdit(range: range(0, 1, 0, 3), newText: "B")
            ])
        ])
        let snapshots = [document: snapshot(document, content: "abcd")]

        #expect(throws: WorkspaceEditPlanner.Error.malformedRange.self) {
            try WorkspaceEditPlanner.plan(edit: malformed, context: context(for: document), snapshots: snapshots)
        }
        #expect(throws: WorkspaceEditPlanner.Error.overlappingEdits.self) {
            try WorkspaceEditPlanner.plan(edit: overlap, context: context(for: document), snapshots: snapshots)
        }
    }

    @Test func retainsEqualPositionInsertionOrder() throws {
        let document = document("file:///workspace/main.swift")
        let edit = LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: document.uri, version: nil), edits: [
                LSPTextEdit(range: range(0, 1, 0, 1), newText: "A"),
                LSPTextEdit(range: range(0, 1, 0, 1), newText: "B")
            ])
        ])

        let plan = try WorkspaceEditPlanner.plan(edit: edit, context: context(for: document), snapshots: [
            document: snapshot(document, content: "xy")
        ])

        #expect(plan.steps[0].after.content == Data("xABy".utf8))
    }

    @Test func simulatesEditRenameEditInProtocolOrder() throws {
        let old = document("file:///workspace/a.swift")
        let new = document("file:///workspace/b.swift")
        let edit = LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: old.uri, version: nil), edits: [
                LSPTextEdit(range: range(0, 0, 0, 1), newText: "A")
            ]),
            .rename(oldURI: old.uri, newURI: new.uri, options: .init(), annotationID: nil),
            .textDocument(document: .init(uri: new.uri, version: nil), edits: [
                LSPTextEdit(range: range(0, 1, 0, 2), newText: "B")
            ])
        ])

        let plan = try WorkspaceEditPlanner.plan(edit: edit, context: context(for: old), snapshots: [
            old: snapshot(old, content: "xy")
        ])

        #expect(plan.requiresPreview)
        #expect(plan.steps.map(\.kind) == [.text, .rename, .text])
        #expect(plan.steps.last?.after.content == Data("ABy".utf8))
    }

    @Test func honorsOverwriteAndIgnoreOptions() throws {
        let source = document("file:///workspace/a.swift")
        let destination = document("file:///workspace/b.swift")
        let base = [
            source: snapshot(source, content: "source"),
            destination: snapshot(destination, content: "destination", open: true, dirty: true)
        ]
        let ignored = LSPWorkspaceEdit(documentChanges: [
            .rename(oldURI: source.uri, newURI: destination.uri, options: .init(ignoreIfExists: true), annotationID: nil)
        ])
        let overwrite = LSPWorkspaceEdit(documentChanges: [
            .rename(oldURI: source.uri, newURI: destination.uri, options: .init(overwrite: true), annotationID: nil)
        ])

        let ignoredPlan = try WorkspaceEditPlanner.plan(edit: ignored, context: context(for: source), snapshots: base)
        let overwritePlan = try WorkspaceEditPlanner.plan(edit: overwrite, context: context(for: source), snapshots: base)

        #expect(ignoredPlan.steps[0].before == ignoredPlan.steps[0].after)
        #expect(overwritePlan.warnings.contains(.destinationOverwriteWithUnsavedContent(destination)))
    }

    @Test func keepsMixedAnnotationsAndMapsRemoteHost() throws {
        let document = EditorDocumentID(host: "ssh.example", worktreeID: "worktree", uri: "file:///repo/a.swift")
        let otherURI = "file:///repo/b.swift"
        let edit = LSPWorkspaceEdit(
            documentChanges: [
                .textDocument(document: .init(uri: document.uri, version: nil), edits: []),
                .create(uri: otherURI, options: .init(), annotationID: "confirm")
            ],
            changeAnnotations: ["confirm": .init(label: "Create file", needsConfirmation: true, description: "Generated output")]
        )

        let plan = try WorkspaceEditPlanner.plan(edit: edit, context: context(for: document), snapshots: [
            document: snapshot(document, content: "text")
        ])

        #expect(plan.steps[1].document.host == "ssh.example")
        #expect(plan.reviewAnnotations["confirm"]?.needsConfirmation == true)
        #expect(plan.requiresPreview)
    }

    @Test func preservesAnnotatedTextEdits() throws {
        let document = self.document("file:///workspace/main.swift")
        let edit = LSPWorkspaceEdit(
            documentChanges: [
                .textDocument(document: .init(uri: document.uri, version: nil), edits: [
                    LSPTextEdit(range: range(0, 0, 0, 1), newText: "A", annotationID: "confirm")
                ])
            ],
            changeAnnotations: ["confirm": .init(label: "Replace", needsConfirmation: true)]
        )

        let plan = try WorkspaceEditPlanner.plan(edit: edit, context: context(for: document), snapshots: [
            document: snapshot(document, content: "text")
        ])

        #expect(plan.steps[0].annotationIDs == ["confirm"])
        #expect(plan.requiresPreview)
    }

    private func document(_ uri: String) -> EditorDocumentID {
        EditorDocumentID(host: nil, worktreeID: "worktree", uri: uri)
    }

    private func context(for document: EditorDocumentID, version: Int = 1) -> EditorRequestContext {
        EditorRequestContext(
            document: document, version: version, serverGeneration: UUID(), range: range(0, 0, 0, 0)
        )
    }

    private func snapshot(
        _ document: EditorDocumentID,
        content: String,
        version: Int? = nil,
        open: Bool = false,
        dirty: Bool = false
    ) -> WorkspaceFileSnapshot {
        WorkspaceFileSnapshot(
            document: document, content: Data(content.utf8), bufferVersion: version, isOpen: open, isDirty: dirty
        )
    }

    private func range(_ startLine: Int, _ startCharacter: Int, _ endLine: Int, _ endCharacter: Int) -> LSPRange {
        LSPRange(
            start: .init(line: startLine, character: startCharacter),
            end: .init(line: endLine, character: endCharacter)
        )
    }
}
