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

    // MARK: - Add next occurrence

    @Test func cmdDSelectsWordAtCursorWhenSelectionIsEmpty() {
        let textView = makeTextView("foo bar foo")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let handled = textView.performKeyEquivalent(with: commandD())

        #expect(handled == true)
        #expect(selectedRanges(in: textView) == [NSRange(location: 0, length: 3)])
    }

    @Test func repeatedCmdDAddsNextOccurrence() {
        let textView = makeTextView("foo bar foo")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        _ = textView.performKeyEquivalent(with: commandD())
        _ = textView.performKeyEquivalent(with: commandD())

        #expect(selectedRanges(in: textView) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ])
    }

    @Test func cmdDWrapsAroundFromLastOccurrence() {
        let textView = makeTextView("foo bar foo")
        textView.setSelectedRange(NSRange(location: 8, length: 3))

        _ = textView.performKeyEquivalent(with: commandD())

        #expect(selectedRanges(in: textView) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ])
    }

    @Test func cmdDSkipsAlreadySelectedOccurrences() {
        let textView = makeTextView("foo foo foo")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 3)),
            NSValue(range: NSRange(location: 4, length: 3))
        ], affinity: .downstream, stillSelecting: false)

        _ = textView.performKeyEquivalent(with: commandD())

        #expect(selectedRanges(in: textView) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
            NSRange(location: 8, length: 3)
        ])
    }

    @Test func cmdDDoesNotDuplicateWhenAllOccurrencesAreSelected() {
        let textView = makeTextView("foo foo")
        textView.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 3)),
            NSValue(range: NSRange(location: 4, length: 3))
        ], affinity: .downstream, stillSelecting: false)

        _ = textView.performKeyEquivalent(with: commandD())

        #expect(selectedRanges(in: textView) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3)
        ])
    }

    @Test func cmdDIsCaseSensitive() {
        let textView = makeTextView("Foo foo Foo")
        textView.setSelectedRange(NSRange(location: 0, length: 3))

        _ = textView.performKeyEquivalent(with: commandD())

        #expect(selectedRanges(in: textView) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ])
    }

    @Test func nonCommandDIsNotHandledAsKeyEquivalent() {
        let textView = makeTextView("foo")

        let handled = textView.performKeyEquivalent(with: keyDWithoutCommand())

        #expect(handled == false)
    }

    // MARK: - Column selection

    @Test func columnSelectionCreatesRangeForEachVisualLine() throws {
        let textView = makeGeometryTextView("abcde\nfghij\nklmno")
        let start = try pointForCharacter(at: 1, in: textView)
        let end = try pointForCharacter(at: 15, in: textView)

        performColumnDrag(in: textView, from: start, to: end)

        #expect(selectedRanges(in: textView) == [
            NSRange(location: 1, length: 2),
            NSRange(location: 7, length: 2),
            NSRange(location: 13, length: 2)
        ])
    }

    @Test func columnSelectionReverseDragProducesSameRanges() throws {
        let textView = makeGeometryTextView("abcde\nfghij\nklmno")
        let start = try pointForCharacter(at: 15, in: textView)
        let end = try pointForCharacter(at: 1, in: textView)

        performColumnDrag(in: textView, from: start, to: end)

        #expect(selectedRanges(in: textView) == [
            NSRange(location: 1, length: 2),
            NSRange(location: 7, length: 2),
            NSRange(location: 13, length: 2)
        ])
    }

    @Test func columnSelectionUsesWrappedVisualLines() throws {
        let textView = makeGeometryTextView("abcdef ghijkl", width: 48)
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else {
            Issue.record("Missing TextKit components")
            return
        }
        layoutManager.ensureLayout(for: container)

        let glyphRange = layoutManager.glyphRange(for: container)
        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            lineCount += 1
        }
        #expect(lineCount > 1)

        let start = try pointForCharacter(at: 1, in: textView)
        let end = try pointForCharacter(at: 9, in: textView)
        performColumnDrag(in: textView, from: start, to: end)

        #expect(selectedRanges(in: textView).count > 1)
    }

    @Test func optionShiftDragBelowThresholdPreservesClickExtension() throws {
        let textView = makeGeometryTextView("abcde")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let start = try pointForCharacter(at: 4, in: textView)

        let end = NSPoint(x: start.x + 2, y: start.y + 1)
        textView.mouseDown(with: mouseEvent(.leftMouseDown, in: textView, at: start, modifiers: [.option, .shift]))
        textView.mouseDragged(with: mouseEvent(.leftMouseDragged, in: textView, at: end, modifiers: [.option, .shift]))
        textView.mouseUp(with: mouseEvent(.leftMouseUp, in: textView, at: end, modifiers: [.option, .shift]))

        #expect(selectedRanges(in: textView) == [NSRange(location: 1, length: 3)])
    }

    private func makeGeometryTextView(_ text: String, width: CGFloat = 800) -> CodeTextView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: 600))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600), textContainer: container)
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = .zero
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        layoutManager.ensureLayout(for: container)
        return textView
    }

    private func selectedRanges(in textView: CodeTextView) -> [NSRange] {
        textView.selectedRanges.map(\.rangeValue)
    }

    private func commandD() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        )!
    }

    private func keyDWithoutCommand() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        )!
    }

    private func mouseEvent(_ type: NSEvent.EventType, in textView: CodeTextView, at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: textView.convert(point, to: nil),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func performColumnDrag(in textView: CodeTextView, from start: NSPoint, to end: NSPoint) {
        textView.mouseDown(with: mouseEvent(.leftMouseDown, in: textView, at: start, modifiers: [.option, .shift]))
        textView.mouseDragged(with: mouseEvent(.leftMouseDragged, in: textView, at: end, modifiers: [.option, .shift]))
        textView.mouseUp(with: mouseEvent(.leftMouseUp, in: textView, at: end, modifiers: [.option, .shift]))
    }

    private func pointForCharacter(at location: Int, in textView: CodeTextView) throws -> NSPoint {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            Issue.record("Missing TextKit components")
            return .zero
        }

        layoutManager.ensureLayout(for: container)
        let nsLength = (textView.string as NSString).length
        let clamped = min(max(location, 0), nsLength)
        let glyphRange = layoutManager.glyphRange(for: container)
        var point: NSPoint?

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, stop in
            let charRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            guard clamped >= charRange.location, clamped <= NSMaxRange(charRange) else { return }

            let x: CGFloat
            if clamped == NSMaxRange(charRange) {
                x = usedRect.maxX
            } else {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: clamped)
                x = layoutManager.location(forGlyphAt: glyphIndex).x
            }
            point = NSPoint(
                x: textView.textContainerOrigin.x + x,
                y: textView.textContainerOrigin.y + usedRect.midY
            )
            stop.pointee = true
        }

        guard let point else {
            Issue.record("Could not resolve point for character \(location)")
            return .zero
        }
        return point
    }
}
