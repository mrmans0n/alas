import Foundation
import Testing
@testable import Alas

struct TextEditCoordinatesTests {
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
