import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("DiffPaneLSPLineMap")
struct DiffPaneLSPLineMapTests {
    @Test func mapsNewLineCharacterToRealFilePosition() {
        let line = DiffDisplayLine(
            id: "file:new:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 42),
            text: "let value = service.fetch()",
            lineNumber: 42,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .add,
                range: NSRange(location: 0, length: 27),
                tone: .add,
                sourceLine: line
            )
        ]

        let result = DiffPaneLSPLineMap.position(
            at: 11,
            metadata: metadata,
            allowedSide: .new
        )

        #expect(result == LSPPosition(line: 41, character: 11))
    }

    @Test func mapsPairedContextLineToNewFilePosition() {
        let line = DiffDisplayLine(
            id: "file:paired:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .paired, oldLine: 40, newLine: 40),
            text: "let context = value",
            lineNumber: 40,
            kind: .context,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: 0, length: 19),
                tone: .context,
                sourceLine: line
            )
        ]

        let result = DiffPaneLSPLineMap.position(
            at: 12,
            metadata: metadata,
            allowedSide: .new
        )

        #expect(result == LSPPosition(line: 39, character: 12))
    }

    @MainActor
    @Test func mapsPrefixedStackedRowsFromSourceCodeColumn() throws {
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,1 +1,2 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .context, text: "let context = value", oldNumber: 1, newNumber: 1),
                    .init(kind: .add, text: "let inserted = value", oldNumber: nil, newNumber: 2),
                ]
            ),
        ])
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/App.swift")
        let group = try #require(model.groups.first)
        let document = DiffPaneTextDocumentBuilder.build(
            group: group,
            expandedCollapsedRowIDs: [],
            layoutMode: .stacked,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )
        let rendered = document.attributedString.string as NSString
        let contextStart = rendered.range(of: "let context").location
        let insertStart = rendered.range(of: "let inserted").location

        #expect(contextStart != NSNotFound)
        #expect(insertStart != NSNotFound)
        #expect(DiffPaneLSPLineMap.position(
            at: contextStart,
            metadata: document.lines,
            allowedSide: .new
        ) == LSPPosition(line: 0, character: 0))
        #expect(DiffPaneLSPLineMap.position(
            at: insertStart,
            metadata: document.lines,
            allowedSide: .new
        ) == LSPPosition(line: 1, character: 0))
        #expect(DiffPaneLSPLineMap.position(
            at: insertStart - 1,
            metadata: document.lines,
            allowedSide: .new
        ) == nil)
    }

    @Test func rejectsOldSideLine() {
        let line = DiffDisplayLine(
            id: "file:old:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .old, oldLine: 41, newLine: nil),
            text: "let old = value",
            lineNumber: 41,
            kind: .delete,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .delete,
                range: NSRange(location: 0, length: 15),
                tone: .delete,
                sourceLine: line
            )
        ]

        let result = DiffPaneLSPLineMap.position(
            at: 4,
            metadata: metadata,
            allowedSide: .new
        )

        #expect(result == nil)
    }

    @Test func rejectsCharacterOutsideSourceText() {
        let line = DiffDisplayLine(
            id: "file:new:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 8),
            text: "abc",
            lineNumber: 8,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .add,
                range: NSRange(location: 10, length: 3),
                tone: .add,
                sourceLine: line
            )
        ]

        #expect(DiffPaneLSPLineMap.position(at: 9, metadata: metadata, allowedSide: .new) == nil)
        #expect(DiffPaneLSPLineMap.position(at: 13, metadata: metadata, allowedSide: .new) == nil)
    }

    @Test func rejectsCollapsedRows() {
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .collapsed,
                range: NSRange(location: 0, length: 20),
                tone: .collapsed,
                sourceLine: nil
            )
        ]

        #expect(DiffPaneLSPLineMap.position(at: 5, metadata: metadata, allowedSide: .new) == nil)
    }

    @MainActor
    @Test func retainOpenLoadsFileTextAndCallsOpenClosure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-lsp-retain-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let value = service.fetch()\n".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        var captured: (URL, URL, String, String)?
        let retain = try await DiffPaneLSPDocumentRetain.open(
            worktreeRoot: root,
            fileURL: source,
            language: "swift",
            open: { worktreeRoot, fileURL, language, text in
                captured = (worktreeRoot, fileURL, language, text)
                return nil
            },
            close: { _, _, _ in }
        )
        await retain.close()

        let opened = try #require(captured)
        #expect(opened.0 == root)
        #expect(opened.1 == source)
        #expect(opened.2 == "swift")
        #expect(opened.3 == "let value = service.fetch()\n")
    }

    @MainActor
    @Test func retainCloseCallsCloseClosureOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-lsp-retain-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let value = 1\n".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        var closeCount = 0
        let retain = try await DiffPaneLSPDocumentRetain.open(
            worktreeRoot: root,
            fileURL: source,
            language: "swift",
            open: { _, _, _, _ in nil },
            close: { _, _, _ in closeCount += 1 }
        )

        await retain.close()
        await retain.close()

        #expect(closeCount == 1)
    }

    @MainActor
    @Test func controllerPositionUsesTextViewMetadataAndRejectsOldSide() {
        let textView = DiffPaneCodeTextView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 80),
            textContainer: NSTextContainer()
        )
        let newLine = DiffDisplayLine(
            id: "file:new:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 12),
            text: "let value",
            lineNumber: 12,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let oldLine = DiffDisplayLine(
            id: "file:old:0:1",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 1, side: .old, oldLine: 13, newLine: nil),
            text: "let stale",
            lineNumber: 13,
            kind: .delete,
            inlineSpans: [],
            noTrailingNewline: false
        )
        textView.lineMetadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .add,
                range: NSRange(location: 0, length: 9),
                tone: .add,
                sourceLine: newLine
            ),
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .delete,
                range: NSRange(location: 10, length: 9),
                tone: .delete,
                sourceLine: oldLine
            ),
        ]

        let controller = DiffPaneLSPController(textView: textView)
        controller.update(context: nil, allowedSide: .new)

        #expect(controller.lspPosition(forCharacterIndex: 4) == LSPPosition(line: 11, character: 4))
        #expect(controller.lspPosition(forCharacterIndex: 14) == nil)

        controller.tearDown()
    }

    @MainActor
    @Test func controllerRejectsStaleSourceLineBeforeLSPRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-lsp-stale-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let current = value\n".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let textView = DiffPaneCodeTextView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 80),
            textContainer: NSTextContainer()
        )
        let renderedLine = DiffDisplayLine(
            id: "file:new:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 1),
            text: "let stale = value",
            lineNumber: 1,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        textView.lineMetadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .add,
                range: NSRange(location: 0, length: 17),
                tone: .add,
                sourceLine: renderedLine
            ),
        ]
        let controller = DiffPaneLSPController(textView: textView)
        controller.update(context: nil, allowedSide: .new)
        let match = try #require(controller.lspMatch(forCharacterIndex: 4))
        let context = DiffPaneLSPContext(
            worktreeId: "worktree-1",
            worktreeRoot: root,
            relativePath: "Sources/App.swift",
            language: "swift",
            lsp: WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [])),
            openTarget: { _, _, _ in }
        )

        let isCurrent = await controller.matchesCurrentSourceForTesting(match, context: context)

        #expect(!isCurrent)
        controller.tearDown()
    }

    @MainActor
    @Test func controllerAcceptsMatchingSourceLineBeforeLSPRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-lsp-current-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let current = value\n".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let textView = DiffPaneCodeTextView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 80),
            textContainer: NSTextContainer()
        )
        let renderedLine = DiffDisplayLine(
            id: "file:new:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 1),
            text: "let current = value",
            lineNumber: 1,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        textView.lineMetadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .add,
                range: NSRange(location: 0, length: 19),
                tone: .add,
                sourceLine: renderedLine
            ),
        ]
        let controller = DiffPaneLSPController(textView: textView)
        controller.update(context: nil, allowedSide: .new)
        let match = try #require(controller.lspMatch(forCharacterIndex: 4))
        let context = DiffPaneLSPContext(
            worktreeId: "worktree-1",
            worktreeRoot: root,
            relativePath: "Sources/App.swift",
            language: "swift",
            lsp: WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [])),
            openTarget: { _, _, _ in }
        )

        let isCurrent = await controller.matchesCurrentSourceForTesting(match, context: context)

        #expect(isCurrent)
        controller.tearDown()
    }

    private func theme() -> Theme {
        try! ThemeStore().current
    }
}
