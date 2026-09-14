import Foundation
import Testing
@testable import Alas

struct WorkspaceEditPlannerTests {
    @Test func rejectsCreateOverOpenBufferBeforeExecution() {
        let owner = document("file:///workspace/a.swift")
        let edit = LSPWorkspaceEdit(documentChanges: [.create(uri: owner.uri, options: .init(overwrite: true), annotationID: nil)])
        #expect(throws: (any Swift.Error).self) {
            try WorkspaceEditPlanner.plan(edit: edit, context: context(for: owner), snapshots: [owner: snapshot(owner, content: "dirty", open: true, dirty: true)])
        }
    }

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
            old: snapshot(old, content: "xy"),
            new: absentSnapshot(new)
        ])

        #expect(plan.requiresPreview)
        #expect(plan.steps.map(\.kind) == [.text, .rename, .text])
        #expect(plan.steps.last?.after.content == Data("AB".utf8))
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
        #expect(ignoredPlan.steps[0].before == ignoredPlan.steps[0].after)
        #expect(throws: (any Swift.Error).self) {
            try WorkspaceEditPlanner.plan(edit: overwrite, context: context(for: source), snapshots: base)
        }
    }

    @Test func requiresExplicitSnapshotsForEveryResourceTargetAndSource() {
        let source = document("file:///workspace/a.swift")
        let destination = document("file:///workspace/b.swift")
        let cases: [(LSPWorkspaceEdit, [EditorDocumentID: WorkspaceFileSnapshot])] = [
            (
                LSPWorkspaceEdit(documentChanges: [.create(uri: destination.uri, options: .init(), annotationID: nil)]),
                [:]
            ),
            (
                LSPWorkspaceEdit(documentChanges: [.rename(oldURI: source.uri, newURI: destination.uri, options: .init(), annotationID: nil)]),
                [source: snapshot(source, content: "source")]
            ),
            (
                LSPWorkspaceEdit(documentChanges: [.delete(uri: destination.uri, options: .init(ignoreIfNotExists: true), annotationID: nil)]),
                [:]
            )
        ]

        for (edit, snapshots) in cases {
            #expect(throws: WorkspaceEditPlanner.Error.missingSnapshot.self) {
                try WorkspaceEditPlanner.plan(edit: edit, context: context(for: source), snapshots: snapshots)
            }
        }
    }

    @Test func rejectsInsertionTouchingReplacementBoundary() {
        let document = document("file:///workspace/main.swift")
        let edit = LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: document.uri, version: 1), edits: [
                LSPTextEdit(range: range(0, 1, 0, 2), newText: "X"),
                LSPTextEdit(range: range(0, 1, 0, 1), newText: "Y")
            ])
        ])

        #expect(throws: WorkspaceEditPlanner.Error.overlappingEdits.self) {
            try WorkspaceEditPlanner.plan(edit: edit, context: context(for: document), snapshots: [
                document: snapshot(document, content: "abc", version: 1)
            ])
        }
    }

    @Test func overwriteWinsOverIgnoreIfExists() throws {
        let source = document("file:///workspace/a.swift")
        let destination = document("file:///workspace/b.swift")
        let edit = LSPWorkspaceEdit(documentChanges: [
            .rename(
                oldURI: source.uri,
                newURI: destination.uri,
                options: .init(overwrite: true, ignoreIfExists: true),
                annotationID: nil
            )
        ])

        let plan = try WorkspaceEditPlanner.plan(edit: edit, context: context(for: source), snapshots: [
            source: snapshot(source, content: "source", version: 1),
            destination: snapshot(destination, content: "destination"),
        ])

        #expect(plan.steps[0].after.content == Data("source".utf8))
    }

    @Test func requiresInitiatingDocumentBufferVersion() {
        let document = document("file:///workspace/main.swift")
        let edit = LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: document.uri, version: nil), edits: [])
        ])

        #expect(throws: WorkspaceEditPlanner.Error.staleVersion.self) {
            try WorkspaceEditPlanner.plan(edit: edit, context: context(for: document, version: 1), snapshots: [
                document: snapshot(document, content: "text", version: nil)
            ])
        }
    }

    @Test func rejectsUnsafePlannerInputs() {
        let document = document("file:///workspace/main.swift")
        let textEdit = LSPTextEdit(range: range(0, 0, 0, 0), newText: "x")
        let cases: [(LSPWorkspaceEdit, [EditorDocumentID: WorkspaceFileSnapshot], WorkspaceEditPlanner.Error)] = [
            (
                LSPWorkspaceEdit(
                    changes: [document.uri: [textEdit]],
                    documentChanges: [.textDocument(document: .init(uri: document.uri, version: nil), edits: [textEdit])]
                ),
                [document: snapshot(document, content: "text", version: 1)],
                .conflictingRepresentations
            ),
            (
                LSPWorkspaceEdit(documentChanges: [
                    .textDocument(document: .init(uri: "untitled:main.swift", version: nil), edits: [])
                ]),
                [document: snapshot(document, content: "text", version: 1)],
                .unsupportedURI
            ),
            (
                LSPWorkspaceEdit(documentChanges: [
                    .textDocument(document: .init(uri: document.uri, version: nil), edits: [])
                ]),
                [document: snapshot(document, content: "text", version: 1, symbolicLink: true)],
                .symbolicLinkAmbiguity
            ),
            (
                LSPWorkspaceEdit(documentChanges: [
                    .delete(uri: document.uri, options: .init(recursive: true), annotationID: nil)
                ]),
                [document: snapshot(document, content: "text", version: 1, directory: true)],
                .unboundedDirectoryDelete
            ),
            (
                LSPWorkspaceEdit(documentChanges: [
                    .textDocument(document: .init(uri: document.uri, version: nil), edits: [])
                ]),
                [document: WorkspaceFileSnapshot(document: document, content: Data([0xFF]), bufferVersion: 1)],
                .nonTextInput
            )
        ]

        for (edit, snapshots, expected) in cases {
            let result = Result {
                try WorkspaceEditPlanner.plan(edit: edit, context: context(for: document), snapshots: snapshots)
            }
            switch result {
            case .success:
                #expect(Bool(false), "Expected planner preflight to reject \(expected)")
            case .failure(let error):
                #expect(error as? WorkspaceEditPlanner.Error == expected)
            }
        }
    }

    @Test func preservesArbitraryJSONNumberTokens() throws {
        let token = "12345678901234567890123456789012345678901234567890e+200"
        let value = try LSPJSONValue.decode(from: Data(token.utf8))

        #expect(value == .number(token))
        #expect(try value.encodedData() == Data(token.utf8))
    }

    @Test func rejectsDuplicateJSONKeys() {
        #expect(jsonParsingFails(#"{"value":1,"value":2}"#))
    }

    @Test func acceptsJSONWith128NestedArrays() throws {
        let source = nestedArrayJSON(containers: 128)

        #expect(try LSPJSONValue.decode(from: Data(source.utf8)).encodedData() == Data(source.utf8))
    }

    @Test func rejectsJSONWith129NestedArrays() {
        let source = nestedArrayJSON(containers: 129)

        #expect(jsonParsingFails(source))
    }

    @Test func acceptsJSONWith128NestedObjects() throws {
        let source = nestedObjectJSON(containers: 128)

        #expect(try LSPJSONValue.decode(from: Data(source.utf8)).encodedData() == Data(source.utf8))
    }

    @Test func rejectsJSONWith129NestedObjects() {
        let source = nestedObjectJSON(containers: 129)

        #expect(jsonParsingFails(source))
    }

    @Test func acceptsJSONWith128MixedContainers() throws {
        let source = nestedMixedJSON(containers: 128)

        #expect(try LSPJSONValue.decode(from: Data(source.utf8)).encodedData() == Data(source.utf8))
    }

    @Test func rejectsJSONWith129MixedContainers() {
        let source = nestedMixedJSON(containers: 129)

        #expect(jsonParsingFails(source))
    }

    @Test func rejectsJSONWith10000MixedContainers() {
        #expect(jsonParsingFails(nestedMixedJSON(containers: 10_000)))
    }

    @Test func resetsJSONNestingDepthBetweenSiblings() throws {
        let source = "[\(nestedArrayJSON(containers: 127)),\(nestedObjectJSON(containers: 127)),\(nestedMixedJSON(containers: 127))]"

        #expect(try LSPJSONValue.decode(from: Data(source.utf8)).encodedData() == Data(source.utf8))
    }

    @Test func genericCodableSupportsNumbersInsideNestedValues() throws {
        let source = Data(#"[42,{"fraction":12.5,"negative":-7}]"#.utf8)
        let value = try JSONDecoder().decode(LSPJSONValue.self, from: source)

        #expect(value == .array([
            .number("42"),
            .object(["fraction": .number("12.5"), "negative": .number("-7")])
        ]))

        let encoded = try JSONEncoder().encode(value)
        let roundTripped = try JSONDecoder().decode(LSPJSONValue.self, from: encoded)
        #expect(roundTripped == value)
    }

    @Test func genericCodablePreservesFoundationRepresentableStandaloneNumber() throws {
        let token = "12345678901234567890123456789012345678"
        let value = try JSONDecoder().decode(LSPJSONValue.self, from: Data(token.utf8))

        #expect(value == .number(token))
        #expect(try JSONDecoder().decode(LSPJSONValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func genericCodableCanonicalizesNumberFormatting() throws {
        let value = try JSONDecoder().decode(LSPJSONValue.self, from: Data("1.2300e+2".utf8))

        #expect(value == .number("123"))
        #expect(try JSONEncoder().encode(value) == Data("123".utf8))
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
            document: snapshot(document, content: "text"),
            EditorDocumentID(host: "ssh.example", worktreeID: "worktree", uri: otherURI): absentSnapshot(
                EditorDocumentID(host: "ssh.example", worktreeID: "worktree", uri: otherURI)
            )
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
        version: Int? = 1,
        open: Bool = false,
        dirty: Bool = false,
        directory: Bool = false,
        symbolicLink: Bool = false
    ) -> WorkspaceFileSnapshot {
        WorkspaceFileSnapshot(
            document: document,
            content: Data(content.utf8),
            bufferVersion: version,
            isOpen: open,
            isDirty: dirty,
            isDirectory: directory,
            isSymbolicLink: symbolicLink
        )
    }

    private func absentSnapshot(_ document: EditorDocumentID) -> WorkspaceFileSnapshot {
        WorkspaceFileSnapshot(document: document, content: nil)
    }

    private func range(_ startLine: Int, _ startCharacter: Int, _ endLine: Int, _ endCharacter: Int) -> LSPRange {
        LSPRange(
            start: .init(line: startLine, character: startCharacter),
            end: .init(line: endLine, character: endCharacter)
        )
    }

    private func nestedArrayJSON(containers: Int) -> String {
        String(repeating: "[", count: containers) + "null" + String(repeating: "]", count: containers)
    }

    private func nestedObjectJSON(containers: Int) -> String {
        String(repeating: #"{"value":"#, count: containers) + "null" + String(repeating: "}", count: containers)
    }

    private func nestedMixedJSON(containers: Int) -> String {
        var source = ""
        var closings = ""
        for depth in 0..<containers {
            if depth.isMultiple(of: 2) {
                source += "["
                closings += "]"
            } else {
                source += #"{"value":"#
                closings += "}"
            }
        }
        return source + "null" + String(closings.reversed())
    }

    private func jsonParsingFails(_ source: String) -> Bool {
        do {
            _ = try LSPJSONValue.decode(from: Data(source.utf8))
            return false
        } catch {
            return true
        }
    }
}
