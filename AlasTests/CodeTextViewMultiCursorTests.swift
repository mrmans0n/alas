import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct CodeTextViewMultiCursorTests {
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

    // MARK: - Cursor creation

    @Test func appendCursorAddsToSelectedRanges() {
        let textView = makeTextView("hello world")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.appendCursor(at: 6)
        #expect(textView.selectedRanges.count == 2)
    }

    @Test func appendSelectionAddsRange() {
        let textView = makeTextView("hello world")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.appendSelection(NSRange(location: 6, length: 5))
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
        #expect(ranges.contains(NSRange(location: 6, length: 5)))
    }

    // MARK: - Typing with multiple cursors

    @Test func typingInsertsAtAllCursors() {
        let textView = makeTextView("ab")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 1, length: 0)),
            NSValue(range: NSRange(location: 2, length: 0))
        ], affinity: .downstream, stillSelecting: false)

        textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "aXbX")
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
    }

    @Test func typingWithMultipleSelectionsReplacesEach() {
        let textView = makeTextView("hello world")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 5)),
            NSValue(range: NSRange(location: 6, length: 5))
        ], affinity: .downstream, stillSelecting: false)

        textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "X X")
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
    }

    // MARK: - Auto-pair with multi-cursor

    @Test func autoPairInsertsAtAllCursors() {
        let textView = makeTextView("ab")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 1, length: 0)),
            NSValue(range: NSRange(location: 2, length: 0))
        ], affinity: .downstream, stillSelecting: false)

        textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "a()b()")
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
    }

    @Test func autoPairWrapsSelections() {
        let textView = makeTextView("ab cd")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 2)),
            NSValue(range: NSRange(location: 3, length: 2))
        ], affinity: .downstream, stillSelecting: false)

        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "\"ab\" \"cd\"")
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
        let first = ranges.first(where: { $0.location == 1 })!
        #expect(first.length == 2)
        let second = ranges.first(where: { $0.location == 6 })!
        #expect(second.length == 2)
    }

    @Test func closingDelimiterStepsOverAllCursors() {
        let textView = makeTextView("()()")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 1, length: 0)),
            NSValue(range: NSRange(location: 3, length: 0))
        ], affinity: .downstream, stillSelecting: false)

        textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "()()")
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
        #expect(ranges.contains(NSRange(location: 2, length: 0)))
        #expect(ranges.contains(NSRange(location: 4, length: 0)))
    }

    // MARK: - Offset correctness

    @Test func earlierEditsShiftLaterCursors() {
        let textView = makeTextView("ab")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 0)),
            NSValue(range: NSRange(location: 1, length: 0))
        ], affinity: .downstream, stillSelecting: false)

        textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "XaXb")
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
        #expect(ranges.contains(NSRange(location: 1, length: 0)))
        #expect(ranges.contains(NSRange(location: 3, length: 0)))
    }

    // MARK: - Smart newline with multiple cursors

    @Test func multiCursorNewlinePreservesIndent() {
        let textView = makeTextView("    a\n    b")
        textView.indentationMode = .bracketAware
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 5, length: 0)),
            NSValue(range: NSRange(location: 11, length: 0))
        ], affinity: .downstream, stillSelecting: false)

        textView.insertNewline(nil)

        #expect(textView.string == "    a\n    \n    b\n    ")
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
    }

    @Test func multiCursorNewlineReplacesNonEmptyRanges() {
        let textView = makeTextView("hello world")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 5)),
            NSValue(range: NSRange(location: 6, length: 5))
        ], affinity: .downstream, stillSelecting: false)

        textView.insertNewline(nil)

        #expect(textView.string == "\n \n")
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
    }

    // MARK: - Split selection into lines

    @Test func splitSelectionIntoLinesCreatesPerLineCursors() {
        let textView = makeTextView("a\nb\nc")
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.splitSelectionIntoLines(nil)

        let ranges = textView.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 3)
        #expect(ranges[0] == NSRange(location: 0, length: 1))
        #expect(ranges[1] == NSRange(location: 2, length: 1))
        #expect(ranges[2] == NSRange(location: 4, length: 1))
    }

    // MARK: - Plain click clears multi-cursor

    @Test func plainClickCollapsesToSingleSelection() {
        let textView = makeTextView("hello world")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 0)),
            NSValue(range: NSRange(location: 6, length: 0))
        ], affinity: .downstream, stillSelecting: false)

        // Simulate a plain mouse-down by calling mouseDown with no modifiers
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 50, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        textView.mouseDown(with: event)

        #expect(textView.selectedRanges.count == 1)
    }

}
