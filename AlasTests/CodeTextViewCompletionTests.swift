import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct CodeTextViewCompletionTests {
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

    @Test func completeCallsManualTriggerHandler() {
        let textView = makeTextView()
        var calls = 0
        textView.completionManualTriggerHandler = {
            calls += 1
        }

        textView.complete(nil)

        #expect(calls == 1)
    }

    @Test func insertTabRoutesAcceptSelectedAndDoesNotMutateTextWhenHandled() {
        let textView = makeTextView("let value = open")
        var actions: [CodeTextView.CompletionKeyAction] = []
        textView.completionKeyHandler = { action in
            actions.append(action)
            return true
        }

        textView.insertTab(nil)

        #expect(actions == [.acceptSelected])
        #expect(textView.string == "let value = open")
    }

    @Test func insertNewlineRoutesAcceptSelectedAndDoesNotMutateTextWhenHandled() {
        let textView = makeTextView("let value = open")
        var actions: [CodeTextView.CompletionKeyAction] = []
        textView.completionKeyHandler = { action in
            actions.append(action)
            return true
        }

        textView.insertNewline(nil)

        #expect(actions == [.acceptSelected])
        #expect(textView.string == "let value = open")
    }

    @Test("Return, Enter, and Tab accept the selected completion")
    func completionAcceptanceKeysRouteBeforeAppKitEditsText() throws {
        for (characters, keyCode) in [("\r", UInt16(36)), ("\r", UInt16(76)), ("\t", UInt16(48))] {
            let textView = makeTextView("let value = open")
            var actions: [CodeTextView.CompletionKeyAction] = []
            textView.completionKeyHandler = { action in
                actions.append(action)
                return true
            }

            textView.keyDown(with: try keyEvent(characters: characters, keyCode: keyCode))

            #expect(actions == [.acceptSelected])
            #expect(textView.string == "let value = open")
        }
    }

    @Test func cancelOperationRoutesDismiss() {
        let textView = makeTextView()
        var actions: [CodeTextView.CompletionKeyAction] = []
        textView.completionKeyHandler = { action in
            actions.append(action)
            return true
        }

        textView.cancelOperation(nil)

        #expect(actions == [.dismiss])
    }

    @Test func moveUpAndDownRouteSelectionMovement() {
        let textView = makeTextView("alpha\nbeta")
        var actions: [CodeTextView.CompletionKeyAction] = []
        textView.completionKeyHandler = { action in
            actions.append(action)
            return true
        }

        textView.moveUp(nil)
        textView.moveDown(nil)

        #expect(actions == [.moveSelection(-1), .moveSelection(1)])
    }

    @Test func applyCompletionEditsUsesOriginalBufferRangesAndSetsFinalSelection() {
        let textView = makeTextView("let value = op\n")
        textView.applyCompletionEdits([
            CompletionTextEdit(range: NSRange(location: 0, length: 0), replacementText: "import Foundation\n"),
            CompletionTextEdit(range: NSRange(location: 12, length: 2), replacementText: "openEditor")
        ], finalSelection: NSRange(location: 40, length: 0))

        #expect(textView.string == "import Foundation\nlet value = openEditor\n")
        #expect(textView.selectedRange() == NSRange(location: 40, length: 0))
    }

    @Test func applyCompletionEditsCoalescesCompletionChangeNotification() {
        let textView = makeTextView("let value = op\n")
        var changeCount = 0
        textView.completionChangeHandler = { _ in
            changeCount += 1
        }

        textView.applyCompletionEdits([
            CompletionTextEdit(range: NSRange(location: 0, length: 0), replacementText: "import Foundation\n"),
            CompletionTextEdit(range: NSRange(location: 12, length: 2), replacementText: "openEditor")
        ], finalSelection: NSRange(location: 40, length: 0))

        #expect(changeCount == 1)
    }

    @Test func selectionMoveDoesNotTriggerAutomaticCompletionChange() {
        let textView = makeTextView("let value = open")
        var changeCount = 0
        var selectionChangeCount = 0
        textView.completionChangeHandler = { _ in
            changeCount += 1
        }
        textView.completionSelectionChangeHandler = {
            selectionChangeCount += 1
        }

        textView.setSelectedRange(NSRange(location: 4, length: 0))

        #expect(changeCount == 0)
        #expect(selectionChangeCount == 1)
    }

    @Test func textEditWithProgrammaticSelectionTriggersOnlyTextChange() {
        let textView = makeTextView()
        var changeCount = 0
        var editRange: NSRange?
        var selectionChangeCount = 0
        textView.completionChangeHandler = { range in
            changeCount += 1
            editRange = range
        }
        textView.completionSelectionChangeHandler = {
            selectionChangeCount += 1
        }

        textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "()")
        #expect(changeCount == 1)
        #expect(editRange == NSRange(location: 0, length: 0))
        #expect(selectionChangeCount == 0)
    }

    @Test func completionAnchorAtEndOfTextIsAfterLastCharacter() throws {
        let textView = makeTextView("foo")
        textView.textContainerInset = .zero
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let beforeLast = try #require(textView.completionAnchorRect())
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let end = try #require(textView.completionAnchorRect())

        #expect(end.minX > beforeLast.minX)
    }

    @Test func completionAnchorAfterTrailingNewlineUsesEmptyFinalLine() throws {
        let textView = makeTextView("foo\n")
        textView.textContainerInset = .zero
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let firstLine = try #require(textView.completionAnchorRect())
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let finalLine = try #require(textView.completionAnchorRect())

        #expect(finalLine.minY > firstLine.minY)
        #expect(finalLine.minX <= firstLine.minX + 1)
    }

    private func keyEvent(characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
