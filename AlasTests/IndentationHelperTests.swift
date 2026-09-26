import Foundation
import Testing
@testable import Alas

struct IndentationHelperTests {
    // MARK: - Newline

    struct NewlineCase: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        let caret: Int
        let mode: IndentationMode
        let replacement: String
        let selectedLocationDelta: Int

        var testDescription: String { name }
    }

    static let newlineCases: [NewlineCase] = [
        // Plain mode only ever carries the current line's indent forward.
        NewlineCase(name: "plain preserves spaces indent", text: "    line", caret: 8, mode: .plain,
                    replacement: "\n    ", selectedLocationDelta: 5),
        NewlineCase(name: "plain adds no indent on empty line", text: "", caret: 0, mode: .plain,
                    replacement: "\n", selectedLocationDelta: 1),
        NewlineCase(name: "plain preserves tabs", text: "\tline", caret: 5, mode: .plain,
                    replacement: "\n\t", selectedLocationDelta: 2),
        NewlineCase(name: "plain does not expand a pair", text: "    {}", caret: 5, mode: .plain,
                    replacement: "\n    ", selectedLocationDelta: 5),
        NewlineCase(name: "plain does not indent after an opener", text: "    {", caret: 5, mode: .plain,
                    replacement: "\n    ", selectedLocationDelta: 5),
        // Bracket-aware mode indents after openers and expands pairs.
        NewlineCase(name: "bracket-aware preserves indent", text: "    line", caret: 8, mode: .bracketAware,
                    replacement: "\n    ", selectedLocationDelta: 5),
        NewlineCase(name: "bracket-aware indents after opener with trailing spaces", text: "    {   ", caret: 8,
                    mode: .bracketAware, replacement: "\n        ", selectedLocationDelta: 9),
        NewlineCase(name: "bracket-aware expands pair with trailing spaces", text: "    {   }", caret: 8,
                    mode: .bracketAware, replacement: "\n        \n    ", selectedLocationDelta: 9),
        NewlineCase(name: "bracket-aware indents after opener", text: "    {", caret: 5, mode: .bracketAware,
                    replacement: "\n        ", selectedLocationDelta: 9),
        NewlineCase(name: "bracket-aware indents after opener with tab", text: "\t{", caret: 2, mode: .bracketAware,
                    replacement: "\n\t\t", selectedLocationDelta: 3),
        NewlineCase(name: "bracket-aware expands braces", text: "    {}", caret: 5, mode: .bracketAware,
                    replacement: "\n        \n    ", selectedLocationDelta: 9),
        NewlineCase(name: "bracket-aware expands parentheses", text: "    ()", caret: 5, mode: .bracketAware,
                    replacement: "\n        \n    ", selectedLocationDelta: 9),
        NewlineCase(name: "bracket-aware expands brackets", text: "    []", caret: 5, mode: .bracketAware,
                    replacement: "\n        \n    ", selectedLocationDelta: 9),
        NewlineCase(name: "bracket-aware indents after unindented opener", text: "{", caret: 1, mode: .bracketAware,
                    replacement: "\n    ", selectedLocationDelta: 5),
        NewlineCase(name: "bracket-aware expands unindented pair", text: "{}", caret: 1, mode: .bracketAware,
                    replacement: "\n    \n", selectedLocationDelta: 5),
    ]

    @Test("Newline edit carries indentation for the mode", arguments: IndentationHelperTests.newlineCases)
    func newlineEdit(_ c: NewlineCase) throws {
        let edit = try #require(IndentationHelper.newlineEdit(
            in: c.text,
            selectedRange: NSRange(location: c.caret, length: 0),
            mode: c.mode
        ))
        #expect(edit.replacement == c.replacement)
        #expect(edit.selectedLocationDelta == c.selectedLocationDelta)
    }

    @Test func plainNewlineWithSelectionReturnsNil() {
        let edit = IndentationHelper.newlineEdit(
            in: "hello world",
            selectedRange: NSRange(location: 5, length: 6),
            mode: .plain
        )
        #expect(edit == nil)
    }

    // MARK: - Closing delimiter

    struct ClosingCase: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        let location: Int
        var length: Int = 0
        let delimiter: Character
        var mode: IndentationMode = .bracketAware

        var testDescription: String { name }
    }

    /// Cases that dedent: the whole whitespace prefix of the line is replaced.
    static let dedentCases: [(ClosingCase, String)] = [
        (ClosingCase(name: "brace on whitespace-only line", text: "        ", location: 8, delimiter: "}"), "    }"),
        (ClosingCase(name: "brace on tab-indented line", text: "\t\t", location: 2, delimiter: "}"), "\t}"),
        (ClosingCase(name: "parenthesis", text: "        ", location: 8, delimiter: ")"), "    )"),
        (ClosingCase(name: "bracket", text: "        ", location: 8, delimiter: "]"), "    ]"),
        (ClosingCase(name: "brace before a different character", text: "        x", location: 8, delimiter: "}"), "    }"),
    ]

    @Test("Closing delimiter dedents a whitespace-only line", arguments: IndentationHelperTests.dedentCases)
    func closingDelimiterDedents(_ c: ClosingCase, replacement: String) throws {
        let edit = try #require(IndentationHelper.closingDelimiterEdit(
            in: c.text,
            selectedRange: NSRange(location: c.location, length: c.length),
            delimiter: c.delimiter,
            mode: c.mode
        ))
        #expect(edit.replacementRange == NSRange(location: 0, length: c.location))
        #expect(edit.replacement == replacement)
        #expect(edit.selectedLocationDelta == replacement.count)
    }

    static let noDedentCases: [ClosingCase] = [
        ClosingCase(name: "line has content", text: "    foo", location: 7, delimiter: "}"),
        ClosingCase(name: "plain mode", text: "        ", location: 8, delimiter: "}", mode: .plain),
        ClosingCase(name: "already at minimum indent", text: "", location: 0, delimiter: "}"),
        ClosingCase(name: "non-empty selection", text: "        ", location: 2, length: 6, delimiter: "}"),
        ClosingCase(name: "steps over existing brace", text: "        }", location: 8, delimiter: "}"),
        ClosingCase(name: "steps over existing parenthesis", text: "        )", location: 8, delimiter: ")"),
    ]

    @Test("Closing delimiter produces no edit", arguments: IndentationHelperTests.noDedentCases)
    func closingDelimiterNoEdit(_ c: ClosingCase) {
        let edit = IndentationHelper.closingDelimiterEdit(
            in: c.text,
            selectedRange: NSRange(location: c.location, length: c.length),
            delimiter: c.delimiter,
            mode: c.mode
        )
        #expect(edit == nil)
    }

    // MARK: - Indent unit detection

    @Test("Indent unit detection", arguments: [
        ("\tfoo\n\t\tbar", "\t"),
        ("foo\nbar", "    "),
        ("  a\n  b\n    c", "  "),
        ("    a\n    b\n        c", "    "),
    ])
    func indentUnit(text: String, expected: String) {
        #expect(IndentationHelper.indentUnit(in: text) == expected)
    }
}
