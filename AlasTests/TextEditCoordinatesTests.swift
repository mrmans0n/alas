import Foundation
import SwiftTreeSitter
import Testing
@testable import Alas

struct TextEditCoordinatesTests {
    @Test func inputEditUsesUtf16BytesForAsciiInsertion() {
        let oldText = "abcd"
        let edit = EditorTextEdit(location: 2, oldLength: 0, replacementText: "X")
        let newText = TextEditCoordinates.apply(edit, to: oldText)!
        let inputEdit = TextEditCoordinates.inputEdit(for: edit, oldText: oldText, newText: newText)!

        #expect(inputEdit.startByte == 4)
        #expect(inputEdit.oldEndByte == 4)
        #expect(inputEdit.newEndByte == 6)
        #expect(inputEdit.startPoint.row == 0)
        #expect(inputEdit.startPoint.column == 4)
        #expect(inputEdit.oldEndPoint.row == 0)
        #expect(inputEdit.oldEndPoint.column == 4)
        #expect(inputEdit.newEndPoint.row == 0)
        #expect(inputEdit.newEndPoint.column == 6)
    }

    @Test func inputEditUsesUtf16BytesAfterSurrogatePair() {
        let oldText = "𐍈\nabcd"
        let edit = EditorTextEdit(location: 3, oldLength: 0, replacementText: "X")
        let newText = TextEditCoordinates.apply(edit, to: oldText)!
        let inputEdit = TextEditCoordinates.inputEdit(for: edit, oldText: oldText, newText: newText)!

        #expect(inputEdit.startByte == 6)
        #expect(inputEdit.oldEndByte == 6)
        #expect(inputEdit.newEndByte == 8)
        #expect(inputEdit.startPoint.row == 1)
        #expect(inputEdit.startPoint.column == 0)
        #expect(inputEdit.oldEndPoint.row == 1)
        #expect(inputEdit.oldEndPoint.column == 0)
        #expect(inputEdit.newEndPoint.row == 1)
        #expect(inputEdit.newEndPoint.column == 2)
    }

    @Test func asciiOffsetRoundTrip() {
        let text = "hello\nworld"
        let pos = TextEditCoordinates.lspPosition(utf16Offset: 6, in: text)!
        #expect(pos == LSPPosition(line: 1, character: 0))
        let back = TextEditCoordinates.utf16Offset(from: pos, in: text)!
        #expect(back == 6)
    }

    @Test func emptyLine() {
        let text = "a\n\nb"
        let pos = LSPPosition(line: 1, character: 0)
        #expect(TextEditCoordinates.utf16Offset(from: pos, in: text) == 2)
    }

    @Test func utf16SurrogatePair() {
        let text = "𐍈\nabc"
        // First line has 1 visible character but 2 UTF-16 code units.
        let pos = LSPPosition(line: 1, character: 0)
        #expect(TextEditCoordinates.utf16Offset(from: pos, in: text) == 3)
        let mid = TextEditCoordinates.lspPosition(utf16Offset: 3, in: text)!
        #expect(mid == LSPPosition(line: 1, character: 0))
        #expect(TextEditCoordinates.utf16Offset(from: mid, in: text) == 3)
    }

    @Test func endOfDocument() {
        let text = "hello"
        let pos = LSPPosition(line: 0, character: 5)
        #expect(TextEditCoordinates.utf16Offset(from: pos, in: text) == 5)
    }

    @Test func invalidLineReturnsNil() {
        let text = "a\nb"
        #expect(TextEditCoordinates.utf16Offset(from: LSPPosition(line: 5, character: 0), in: text) == nil)
    }

    @Test func invalidCharacterReturnsNil() {
        let text = "ab"
        #expect(TextEditCoordinates.utf16Offset(from: LSPPosition(line: 0, character: 3), in: text) == nil)
    }

    @Test func characterPastLineEndReturnsNil() {
        let text = "ab\ncd"
        #expect(TextEditCoordinates.utf16Offset(from: LSPPosition(line: 0, character: 3), in: text) == nil)
        #expect(TextEditCoordinates.utf16Offset(from: LSPPosition(line: 1, character: 3), in: text) == nil)
    }

    @Test func negativePositionReturnsNil() {
        let text = "ab"
        #expect(TextEditCoordinates.utf16Offset(from: LSPPosition(line: -1, character: 0), in: text) == nil)
        #expect(TextEditCoordinates.utf16Offset(from: LSPPosition(line: 0, character: -1), in: text) == nil)
    }

    @Test func lineIndexReusesUtf16LineStartsForConversions() {
        let index = TextEditCoordinates.LineIndex("first\n𐍈second\nthird")

        #expect(index.utf16Offset(from: LSPPosition(line: 1, character: 2)) == 8)
        #expect(index.lspPosition(utf16Offset: 15) == LSPPosition(line: 2, character: 0))
        #expect(index.utf16Offset(from: LSPPosition(line: 1, character: 9)) == nil)
    }

    @Test func applyLspTextEditSingleReplacement() {
        let text = "hello"
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 2), end: LSPPosition(line: 0, character: 4)),
            newText: "YY"
        )
        let start = TextEditCoordinates.utf16Offset(from: edit.range.start, in: text)!
        let end = TextEditCoordinates.utf16Offset(from: edit.range.end, in: text)!
        let ns = text as NSString
        let result = ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: edit.newText)
        #expect(result == "heYYo")
    }

    @Test func applyLspTextEditBottomUp() {
        let text = "a\nb\nc"
        let edits = [
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 1)), newText: "X"),
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 2, character: 0), end: LSPPosition(line: 2, character: 1)), newText: "Z")
        ]
        var storage = NSMutableString(string: text)
        let nsEdits: [(NSRange, String)] = edits.compactMap { edit in
            guard let s = TextEditCoordinates.utf16Offset(from: edit.range.start, in: storage as String),
                  let e = TextEditCoordinates.utf16Offset(from: edit.range.end, in: storage as String) else { return nil }
            return (NSRange(location: s, length: e - s), edit.newText)
        }
        let sorted = nsEdits.sorted { first, second in first.0.location > second.0.location }
        for edit in sorted {
            storage.replaceCharacters(in: edit.0, with: edit.1)
        }
        #expect(storage as String == "X\nb\nZ")
    }
}
