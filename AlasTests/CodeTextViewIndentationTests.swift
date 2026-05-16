import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct CodeTextViewIndentationTests {
    private func makeTextView(_ text: String = "", mode: IndentationMode = .bracketAware) -> CodeTextView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.indentationMode = mode
        return textView
    }

    @Test func newlinePreservesIndent() {
        let textView = makeTextView("    line")
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "    line\n    ")
        #expect(textView.selectedRange() == NSRange(location: 13, length: 0))
    }

    @Test func newlineIncreasesIndentAfterOpener() {
        let textView = makeTextView("    {")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "    {\n        ")
        #expect(textView.selectedRange() == NSRange(location: 14, length: 0))
    }

    @Test func newlineExpandsPair() {
        let textView = makeTextView("    {}")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "    {\n        \n    }")
        #expect(textView.selectedRange() == NSRange(location: 14, length: 0))
    }

    @Test func closingDelimiterDedent() {
        let textView = makeTextView("        ")
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "    }")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func closingDelimiterDedentOnWhitespaceBeforeExistingCloser() {
        let textView = makeTextView("    }")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "}")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func closingDelimiterDedentWithExistingCloserOnNextLine() {
        let textView = makeTextView("    {\n        \n    }")
        textView.setSelectedRange(NSRange(location: 14, length: 0))
        textView.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "    {\n    }\n    }")
        #expect(textView.selectedRange() == NSRange(location: 11, length: 0))
    }

    @Test func closingDelimiterStepOverStillWorks() {
        let textView = makeTextView("()")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func closingDelimiterNoDedentWhenLineHasContent() {
        let textView = makeTextView("    foo")
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "    foo}")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    @Test func autoPairStillWorksWithIndentation() {
        let textView = makeTextView()
        textView.insertText("{", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "{}")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func plainModeNoBracketIndent() {
        let textView = makeTextView("    {", mode: .plain)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "    {\n    ")
        #expect(textView.selectedRange() == NSRange(location: 10, length: 0))
    }

    @Test func newlineWithSelectionFallsBackToNormal() {
        let textView = makeTextView("hello world")
        textView.setSelectedRange(NSRange(location: 5, length: 6))
        textView.insertNewline(nil)
        #expect(textView.string == "hello\n")
    }
}
