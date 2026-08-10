import AppKit
import Testing
@testable import Alas

struct PairedDelimiterEditingTests {
    @Test(arguments: [
        ("(", "value", NSRange(location: 0, length: 5), PairedDelimiterEditAction.wrap(opening: "(", closing: ")")),
        ("[", "", NSRange(location: 0, length: 0), PairedDelimiterEditAction.insertPair(opening: "[", closing: "]")),
        (")", "()", NSRange(location: 1, length: 0), PairedDelimiterEditAction.stepOver),
        ("`", "word", NSRange(location: 4, length: 0), PairedDelimiterEditAction.native),
        ("paste", "", NSRange(location: 0, length: 0), PairedDelimiterEditAction.native),
    ])
    func resolvesRepresentativeEdits(
        input: String,
        text: String,
        range: NSRange,
        expected: PairedDelimiterEditAction
    ) {
        #expect(PairedDelimiterEditing.resolve(insertedText: input, in: text, selectedRange: range) == expected)
    }

    @Test(arguments: [
        ("(", ")"),
        ("[", "]"),
        ("{", "}"),
        ("\"", "\""),
        ("'", "'"),
        ("`", "`"),
    ])
    func insertsEverySupportedPair(opening: Character, closing: Character) {
        #expect(
            PairedDelimiterEditing.resolve(
                insertedText: String(opening),
                in: "",
                selectedRange: NSRange(location: 0, length: 0)
            ) == .insertPair(opening: opening, closing: closing)
        )
    }

    @Test(arguments: [
        ("\\", PairedDelimiterEditAction.native),
        ("\\\\", PairedDelimiterEditAction.insertPair(opening: "\"", closing: "\"")),
    ])
    func countsBackslashesBeforeSymmetricDelimiter(text: String, expected: PairedDelimiterEditAction) {
        #expect(
            PairedDelimiterEditing.resolve(
                insertedText: "\"",
                in: text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0)
            ) == expected
        )
    }

    @Test(arguments: [
        ("word", 4),
        ("word", 0),
    ])
    func symmetricDelimiterAdjacentToIdentifierUsesNativeInsertion(text: String, location: Int) {
        #expect(
            PairedDelimiterEditing.resolve(
                insertedText: "'",
                in: text,
                selectedRange: NSRange(location: location, length: 0)
            ) == .native
        )
    }

    @Test func selectedSymmetricDelimiterWrapsSelection() {
        #expect(
            PairedDelimiterEditing.resolve(
                insertedText: "`",
                in: "value",
                selectedRange: NSRange(location: 0, length: 5)
            ) == .wrap(opening: "`", closing: "`")
        )
    }

    @Test func closerOnlyStepsOverItsMatchingCharacter() {
        #expect(
            PairedDelimiterEditing.resolve(
                insertedText: ")",
                in: "]",
                selectedRange: NSRange(location: 0, length: 0)
            ) == .native
        )
    }

    @Test(arguments: [
        NSRange(location: NSNotFound, length: 0),
        NSRange(location: -1, length: 0),
        NSRange(location: 0, length: -1),
        NSRange(location: 6, length: 0),
        NSRange(location: 4, length: 2),
    ])
    func invalidSelectionRangesUseNativeInsertion(range: NSRange) {
        #expect(
            PairedDelimiterEditing.resolve(
                insertedText: "(",
                in: "word",
                selectedRange: range
            ) == .native
        )
    }
}
