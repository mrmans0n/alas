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
}
