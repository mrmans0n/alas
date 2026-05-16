import Foundation
import Testing
@testable import Alas

struct IndentationHelperTests {

    // MARK: - Newline plain mode

    @Test func plainNewlinePreservesIndent() {
        let edit = IndentationHelper.newlineEdit(
            in: "    line",
            selectedRange: NSRange(location: 8, length: 0),
            mode: .plain
        )
        #expect(edit != nil)
        #expect(edit?.replacement == "\n    ")
        #expect(edit?.selectedLocationDelta == 5)
    }

    @Test func plainNewlineNoIndentOnEmptyLine() {
        let edit = IndentationHelper.newlineEdit(
            in: "",
            selectedRange: NSRange(location: 0, length: 0),
            mode: .plain
        )
        #expect(edit != nil)
        #expect(edit?.replacement == "\n")
        #expect(edit?.selectedLocationDelta == 1)
    }

    @Test func plainNewlinePreservesTabs() {
        let edit = IndentationHelper.newlineEdit(
            in: "\tline",
            selectedRange: NSRange(location: 5, length: 0),
            mode: .plain
        )
        #expect(edit?.replacement == "\n\t")
        #expect(edit?.selectedLocationDelta == 2)
    }

    @Test func plainNewlineDoesNotExpandPair() {
        let edit = IndentationHelper.newlineEdit(
            in: "    {}",
            selectedRange: NSRange(location: 5, length: 0),
            mode: .plain
        )
        #expect(edit != nil)
        #expect(edit?.replacement == "\n    ")
    }

    @Test func plainNewlineDoesNotIndentAfterOpener() {
        let edit = IndentationHelper.newlineEdit(
            in: "    {",
            selectedRange: NSRange(location: 5, length: 0),
            mode: .plain
        )
        #expect(edit != nil)
        #expect(edit?.replacement == "\n    ")
    }

    @Test func plainNewlineWithSelectionReturnsNil() {
        let edit = IndentationHelper.newlineEdit(
            in: "hello world",
            selectedRange: NSRange(location: 5, length: 6),
            mode: .plain
        )
        #expect(edit == nil)
    }

    // MARK: - Newline bracket-aware mode

    @Test func bracketAwareNewlinePreservesIndent() {
        let edit = IndentationHelper.newlineEdit(
            in: "    line",
            selectedRange: NSRange(location: 8, length: 0),
            mode: .bracketAware
        )
        #expect(edit?.replacement == "\n    ")
        #expect(edit?.selectedLocationDelta == 5)
    }

    @Test func bracketAwareNewlineAfterOpener() {
        let edit = IndentationHelper.newlineEdit(
            in: "    {",
            selectedRange: NSRange(location: 5, length: 0),
            mode: .bracketAware
        )
        #expect(edit?.replacement == "\n        ")
        #expect(edit?.selectedLocationDelta == 9)
    }

    @Test func bracketAwareNewlineAfterOpenerWithTab() {
        let edit = IndentationHelper.newlineEdit(
            in: "\t{",
            selectedRange: NSRange(location: 2, length: 0),
            mode: .bracketAware
        )
        #expect(edit?.replacement == "\n\t\t")
        #expect(edit?.selectedLocationDelta == 3)
    }

    @Test func bracketAwareExpandsPair() {
        let edit = IndentationHelper.newlineEdit(
            in: "    {}",
            selectedRange: NSRange(location: 5, length: 0),
            mode: .bracketAware
        )
        #expect(edit?.replacement == "\n        \n    ")
        #expect(edit?.selectedLocationDelta == 9)
    }

    @Test func bracketAwareExpandsParenthesesPair() {
        let edit = IndentationHelper.newlineEdit(
            in: "    ()",
            selectedRange: NSRange(location: 5, length: 0),
            mode: .bracketAware
        )
        #expect(edit?.replacement == "\n        \n    ")
        #expect(edit?.selectedLocationDelta == 9)
    }

    @Test func bracketAwareExpandsBracketPair() {
        let edit = IndentationHelper.newlineEdit(
            in: "    []",
            selectedRange: NSRange(location: 5, length: 0),
            mode: .bracketAware
        )
        #expect(edit?.replacement == "\n        \n    ")
        #expect(edit?.selectedLocationDelta == 9)
    }

    @Test func bracketAwareNewlineAfterOpenerNoIndentOnEmpty() {
        let edit = IndentationHelper.newlineEdit(
            in: "{",
            selectedRange: NSRange(location: 1, length: 0),
            mode: .bracketAware
        )
        #expect(edit?.replacement == "\n    ")
        #expect(edit?.selectedLocationDelta == 5)
    }

    @Test func bracketAwareNewlineExpandsPairNoIndentOnEmpty() {
        let edit = IndentationHelper.newlineEdit(
            in: "{}",
            selectedRange: NSRange(location: 1, length: 0),
            mode: .bracketAware
        )
        #expect(edit?.replacement == "\n    \n")
        #expect(edit?.selectedLocationDelta == 5)
    }

    // MARK: - Closing delimiter

    @Test func closingDelimiterDedentOnWhitespaceOnlyLine() {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: "        ",
            selectedRange: NSRange(location: 8, length: 0),
            delimiter: "}",
            mode: .bracketAware
        )
        #expect(edit != nil)
        #expect(edit?.replacementRange == NSRange(location: 0, length: 8))
        #expect(edit?.replacement == "    }")
        #expect(edit?.selectedLocationDelta == 5)
    }

    @Test func closingDelimiterDedentWithTab() {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: "\t\t",
            selectedRange: NSRange(location: 2, length: 0),
            delimiter: "}",
            mode: .bracketAware
        )
        #expect(edit?.replacementRange == NSRange(location: 0, length: 2))
        #expect(edit?.replacement == "\t}")
        #expect(edit?.selectedLocationDelta == 2)
    }

    @Test func closingDelimiterNoDedentWhenLineHasContent() {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: "    foo",
            selectedRange: NSRange(location: 7, length: 0),
            delimiter: "}",
            mode: .bracketAware
        )
        #expect(edit == nil)
    }

    @Test func closingDelimiterNoDedentInPlainMode() {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: "        ",
            selectedRange: NSRange(location: 8, length: 0),
            delimiter: "}",
            mode: .plain
        )
        #expect(edit == nil)
    }

    @Test func closingDelimiterDedentParenthesis() {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: "        ",
            selectedRange: NSRange(location: 8, length: 0),
            delimiter: ")",
            mode: .bracketAware
        )
        #expect(edit?.replacement == "    )")
        #expect(edit?.selectedLocationDelta == 5)
    }

    @Test func closingDelimiterDedentBracket() {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: "        ",
            selectedRange: NSRange(location: 8, length: 0),
            delimiter: "]",
            mode: .bracketAware
        )
        #expect(edit?.replacement == "    ]")
        #expect(edit?.selectedLocationDelta == 5)
    }

    @Test func closingDelimiterNoDedentIfAlreadyMinIndent() {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: "",
            selectedRange: NSRange(location: 0, length: 0),
            delimiter: "}",
            mode: .bracketAware
        )
        #expect(edit == nil)
    }

    @Test func closingDelimiterNoDedentWithSelection() {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: "        ",
            selectedRange: NSRange(location: 2, length: 6),
            delimiter: "}",
            mode: .bracketAware
        )
        #expect(edit == nil)
    }

    // MARK: - Indent unit detection

    @Test func indentUnitDetectsTab() {
        let unit = IndentationHelper.indentUnit(in: "\tfoo\n\t\tbar")
        #expect(unit == "\t")
    }

    @Test func indentUnitDefaultsToFourSpaces() {
        let unit = IndentationHelper.indentUnit(in: "foo\nbar")
        #expect(unit == "    ")
    }

    @Test func indentUnitDetectsTwoSpaces() {
        let unit = IndentationHelper.indentUnit(in: "  a\n  b\n    c")
        #expect(unit == "  ")
    }

    @Test func indentUnitDetectsFourSpaces() {
        let unit = IndentationHelper.indentUnit(in: "    a\n    b\n        c")
        #expect(unit == "    ")
    }
}
