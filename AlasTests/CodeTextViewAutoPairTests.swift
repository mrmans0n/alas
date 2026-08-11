import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct CodeTextViewAutoPairTests {
    private func makeTextView(_ text: String = "") -> CodeTextView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return textView
    }

    @Test func openingDelimiterInsertsPairAndPlacesCursorBetween() {
        let textView = makeTextView()

        textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func openingDelimiterWrapsSelectedText() {
        let textView = makeTextView("value")
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\"value\"")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test func closingDelimiterStepsOverExistingCharacter() {
        let textView = makeTextView("()")
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func quoteStepsOverExistingQuote() {
        let textView = makeTextView("\"\"")
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\"\"")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func quoteStepsOverClosingQuoteAfterIdentifier() {
        let textView = makeTextView("\"foo\"")
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\"foo\"")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func quoteAfterIdentifierFallsBackToNormalTextInsertion() {
        let textView = makeTextView("word")

        textView.insertText("'", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "word'")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func quoteBeforeIdentifierFallsBackToNormalTextInsertion() {
        let textView = makeTextView("word")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\"word")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func escapedQuoteFallsBackToNormalTextInsertion() {
        let textView = makeTextView("\\")

        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\\\"")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func evenlyEscapedQuoteInsertsPair() {
        let textView = makeTextView("\\\\")

        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\\\\\"\"")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func multiCharacterInsertionFallsBackToNormalTextInsertion() {
        let textView = makeTextView()

        textView.insertText("paste", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "paste")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
    }
}
