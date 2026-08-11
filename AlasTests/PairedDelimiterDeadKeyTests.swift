import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Layouts such as "U.S. International – PC" map `"`, `'` and `` ` `` to dead
/// keys. Those never reach `insertText` directly: the first keystroke installs
/// marked text (replacing any selection), and the commit keystroke inserts the
/// literal delimiter while the marked text is still in the storage.
@Suite(.serialized)
@MainActor
struct PairedDelimiterDeadKeyTests {
    // MARK: - Pre-composition context

    @Test func preCompositionContextRestoresCaret() throws {
        let context = try #require(PairedDelimiterEditing.preCompositionContext(
            text: "ab\"cd",
            markedRange: NSRange(location: 2, length: 1),
            replacedSelection: ""
        ))

        #expect(context.text == "abcd")
        #expect(context.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test func preCompositionContextRestoresReplacedSelection() throws {
        let context = try #require(PairedDelimiterEditing.preCompositionContext(
            text: "a\"d",
            markedRange: NSRange(location: 1, length: 1),
            replacedSelection: "bc"
        ))

        #expect(context.text == "abcd")
        #expect(context.selectedRange == NSRange(location: 1, length: 2))
    }

    @Test func preCompositionContextRejectsOutOfBoundsMarkedRange() {
        #expect(PairedDelimiterEditing.preCompositionContext(
            text: "ab",
            markedRange: NSRange(location: 2, length: 1),
            replacedSelection: ""
        ) == nil)
        #expect(PairedDelimiterEditing.preCompositionContext(
            text: "ab",
            markedRange: NSRange(location: NSNotFound, length: 0),
            replacedSelection: ""
        ) == nil)
    }

    // MARK: - PairedDelimiterTextView

    @Test func deadKeyCommitInsertsPairInEmptyDocument() {
        for delimiter in ["\"", "'", "`"] {
            let textView = makePairedTextView()
            commitDeadKey(delimiter, in: textView)

            #expect(textView.string == delimiter + delimiter)
            #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        }
    }

    @Test func deadKeyCommitWrapsSelectionConsumedByComposition() {
        for delimiter in ["\"", "'", "`"] {
            let textView = makePairedTextView(text: "value")
            textView.setSelectedRange(NSRange(location: 0, length: 5))
            commitDeadKey(delimiter, in: textView)

            #expect(textView.string == "\(delimiter)value\(delimiter)")
            #expect(textView.selectedRange() == NSRange(location: 1, length: 5))
        }
    }

    @Test func deadKeyCommitPreservesAttributesOfWrappedSelection() {
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: "value",
            attributes: [.toolTip: "keep-me"]
        ))
        let textView = makePairedTextView(storage: storage)
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        commitDeadKey("`", in: textView)

        #expect(textView.string == "`value`")
        #expect(textView.textStorage?.attribute(.toolTip, at: 1, effectiveRange: nil) as? String == "keep-me")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test func deadKeyCommitStepsOverExistingCloser() {
        let textView = makePairedTextView(text: "\"\"")
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        commitDeadKey("\"", in: textView)

        #expect(textView.string == "\"\"")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func deadKeyCommitAfterIdentifierStaysNative() {
        let textView = makePairedTextView(text: "don")
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        commitDeadKey("'", in: textView)

        #expect(textView.string == "don'")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test func accentedCompositionStillReplacesMarkedText() {
        let textView = makePairedTextView()
        textView.setMarkedText(
            "\"",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        textView.performKeyboardTextInsertion {
            textView.insertText("ö", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "ö")
        #expect(!textView.hasMarkedText())
    }

    @Test func accentedCompositionOverSelectionReplacesIt() {
        let textView = makePairedTextView(text: "value")
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        textView.setMarkedText(
            "\"",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        textView.performKeyboardTextInsertion {
            textView.insertText("ö", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "ö")
    }

    @Test func multiCharacterCandidateCommitDoesNotPair() {
        let textView = makePairedTextView()
        textView.setMarkedText(
            "candidate",
            selectedRange: NSRange(location: 9, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        textView.performKeyboardTextInsertion {
            textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "(")
    }

    @Test func deadKeyCommitOutsideKeyboardInputStaysNative() {
        let textView = makePairedTextView()
        textView.setMarkedText(
            "\"",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\"")
    }

    @Test func staleReplacedSelectionDoesNotLeakIntoLaterInput() {
        let textView = makePairedTextView(text: "value")
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        commitDeadKey("`", in: textView)
        #expect(textView.string == "`value`")

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        commitDeadKey("`", in: textView)

        #expect(textView.string == "`value```")
    }

    // MARK: - CodeTextView

    @Test func codeEditorDeadKeyCommitInsertsPair() {
        let textView = makeCodeTextView()

        textView.setMarkedText(
            "\"",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\"\"")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func codeEditorDeadKeyCommitWrapsSelection() {
        let textView = makeCodeTextView("value")
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.setMarkedText(
            "`",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "`value`")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test func codeEditorAccentedCompositionStillReplacesMarkedText() {
        let textView = makeCodeTextView()

        textView.setMarkedText(
            "\"",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText("ö", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "ö")
    }

    // MARK: - Helpers

    private func commitDeadKey(_ delimiter: String, in textView: PairedDelimiterTextView) {
        textView.setMarkedText(
            delimiter,
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.performKeyboardTextInsertion {
            textView.insertText(delimiter, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func makePairedTextView(text: String = "") -> PairedDelimiterTextView {
        makePairedTextView(storage: NSTextStorage(string: text))
    }

    private func makePairedTextView(storage: NSTextStorage) -> PairedDelimiterTextView {
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: 400))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = PairedDelimiterTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            textContainer: container
        )
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        return textView
    }

    private func makeCodeTextView(_ text: String = "") -> CodeTextView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return textView
    }
}
