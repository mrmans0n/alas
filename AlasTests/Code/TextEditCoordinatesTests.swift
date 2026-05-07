import Foundation
import Testing
@testable import Alas

@Suite("TextEditCoordinates")
struct TextEditCoordinatesTests {
    @Test("tree-sitter input edit points use UTF-16 byte columns")
    func inputEditUsesUTF16ByteColumns() throws {
        let oldText = "let a\nlet b\n"
        let edit = EditorTextEdit(location: 8, oldLength: 0, replacementText: "xy")
        let newText = try #require(TextEditCoordinates.apply(edit, to: oldText))
        let inputEdit = try #require(TextEditCoordinates.inputEdit(for: edit, oldText: oldText, newText: newText))

        #expect(inputEdit.startByte == 16)
        #expect(inputEdit.oldEndByte == 16)
        #expect(inputEdit.newEndByte == 20)
        #expect(inputEdit.startPoint.row == 1)
        #expect(inputEdit.startPoint.column == 4)
        #expect(inputEdit.oldEndPoint.row == 1)
        #expect(inputEdit.oldEndPoint.column == 4)
        #expect(inputEdit.newEndPoint.row == 1)
        #expect(inputEdit.newEndPoint.column == 8)
    }
}
