import Testing
import SwiftUI
import AppKit
@testable import Alas

@Suite(.serialized)
@MainActor
struct AlasFieldTests {
    init() {
        _ = NSApplication.shared
    }

    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func appKitFieldCanRenderDisabled() {
        let view = AlasField(
            text: .constant("test"),
            focusOnAppear: true,
            isEnabled: false
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()

        #expect(Self.firstTextField(in: controller.view)?.isEnabled == false)
    }

    @Test func nativeFieldKeepsLongInputOnOneScrollableLine() {
        let field = AlasNSTextFieldView()
        let cell = field.cell as! AlasNSTextFieldCell
        let editor = cell.setUpFieldEditorAttributes(NSTextView()) as! NSTextView

        #expect(field.lineBreakMode == .byClipping)
        #expect(editor.isHorizontallyResizable)
        #expect(!editor.isVerticallyResizable)
        #expect(editor.textContainer?.widthTracksTextView == false)
        #expect(editor.textContainer?.lineBreakMode == .byClipping)
        #expect(editor.textContainer?.maximumNumberOfLines == 1)
    }

    @Test func nativeFieldCanBecomeEditable() {
        let field = AlasNSTextFieldView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = field

        #expect(field.isEditable)
        #expect(field.isSelectable)
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)
    }

    @Test(arguments: ["", "nacho/"])
    func typingIntoBranchNameFieldKeepsEveryCharacterAndCaretAtEnd(prefix: String) {
        let host = TypingHost(initialText: prefix, inputPolicy: .gitBranchName)
        let controller = NSHostingController(rootView: host.body.environment(\.theme, currentTheme()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 28),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        pump()

        let field = try! #require(Self.firstTextField(in: controller.view))
        #expect(window.makeFirstResponder(field))
        pump()

        let editor = try! #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        var expected = prefix
        for character in "feature branch" {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: String(character), charactersIgnoringModifiers: String(character),
                isARepeat: false, keyCode: 0
            )!
            editor.keyDown(with: event)
            expected.append(character == " " ? "-" : character)
            #expect(editor.string == expected)
            #expect(editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0))
            pump()
            #expect(editor.string == expected)
            #expect(editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0))
        }
    }

    @Test func branchNameInputRejectsMiddleCharacterWithoutMovingCaret() throws {
        let controller = NSHostingController(
            rootView: TypingHost(initialText: "feature", inputPolicy: .gitBranchName)
                .body.environment(\.theme, currentTheme())
        )
        let window = NSWindow(contentViewController: controller)
        controller.view.layoutSubtreeIfNeeded()
        pump()
        let field = try #require(Self.firstTextField(in: controller.view))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))

        editor.insertText("?", replacementRange: editor.selectedRange())
        pump()
        #expect(editor.string == "feature")
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))

        editor.insertText("X", replacementRange: editor.selectedRange())
        pump()
        #expect(editor.string == "featXure")
        #expect(editor.selectedRange() == NSRange(location: 5, length: 0))

        let selection = NSRange(location: 4, length: 2)
        editor.setSelectedRange(selection)
        editor.insertText("~?", replacementRange: selection)
        pump()
        #expect(editor.string == "featXure")
        #expect(editor.selectedRange() == selection)
    }

    @Test(arguments: [
        ("one-old-tail", 4, "one-new-name-tail"),
        ("🎯-old-tail", 3, "🎯-new-name-tail"),
    ])
    func branchNamePasteKeepsSelectionReplacementCaretAcrossUndoAndRedo(
        original: String, location: Int, expected: String
    ) throws {
        let controller = NSHostingController(
            rootView: TypingHost(initialText: original, inputPolicy: .gitBranchName)
                .body.environment(\.theme, currentTheme())
        )
        let window = NSWindow(contentViewController: controller)
        controller.view.layoutSubtreeIfNeeded()
        pump()
        let field = try #require(Self.firstTextField(in: controller.view))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: location, length: 3))
        let undo = try #require(editor.undoManager)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("new name~", forType: .string)
        undo.beginUndoGrouping()
        #expect(editor.readSelection(from: pasteboard, type: .string))
        undo.endUndoGrouping()
        pump()

        #expect(editor.string == expected)
        #expect(editor.selectedRange() == NSRange(location: location + 8, length: 0))
        undo.undo()
        pump()
        #expect(editor.string == original)
        #expect(editor.selectedRange() == NSRange(location: location + 3, length: 0))
        undo.redo()
        pump()
        #expect(editor.string == expected)
        #expect(editor.selectedRange() == NSRange(location: location + 8, length: 0))
    }

    private struct TypingHost {
        var initialText = "nacho/"
        var inputPolicy: AlasFieldInputPolicy?
        @MainActor var body: some View { Inner(text: initialText, inputPolicy: inputPolicy) }

        private struct Inner: View {
            @State var text: String
            let inputPolicy: AlasFieldInputPolicy?
            var body: some View {
                AlasField(
                    text: $text,
                    monospaced: true,
                    focusOnAppear: true,
                    onSubmit: {},
                    disablesAutomaticTextSubstitutions: true,
                    inputPolicy: inputPolicy
                )
            }
        }
    }

    @Test func markedTextInBranchNameInputDoesNotUpdateBindingUntilCommit() throws {
        var text = "nacho/"
        let view = AlasField(
            text: Binding(get: { text }, set: { text = $0 }),
            monospaced: true,
            focusOnAppear: true,
            onSubmit: {},
            disablesAutomaticTextSubstitutions: true,
            inputPolicy: .gitBranchName
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        controller.view.layoutSubtreeIfNeeded()
        pump()
        let field = try #require(Self.firstTextField(in: controller.view))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 6, length: 0))

        editor.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        pump()
        #expect(editor.hasMarkedText())
        #expect(editor.string == "nacho/^")
        #expect(text == "nacho/")

        editor.insertText("ê", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump()
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "nacho/ê")
        #expect(text == "nacho/ê")

        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        editor.insertText("^", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump()
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "nacho/ê")
        #expect(text == "nacho/ê")
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test func disablesAutomaticTextSubstitutionsWhenRequested() throws {
        let field = AlasNSTextFieldView()
        field.disablesAutomaticTextSubstitutions = true
        let cell = try #require(field.cell as? AlasNSTextFieldCell)
        let editor = try #require(cell.setUpFieldEditorAttributes(NSTextView()) as? NSTextView)
        #expect(!editor.isAutomaticTextCompletionEnabled)
        #expect(editor.inlinePredictionType == .no)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
    }

    @Test func leavesAutomaticTextSubstitutionsUntouchedByDefault() throws {
        let field = AlasNSTextFieldView()
        let cell = try #require(field.cell as? AlasNSTextFieldCell)
        let untouched = NSTextView()
        let defaultReplacementSetting = untouched.isAutomaticTextReplacementEnabled
        let editor = try #require(cell.setUpFieldEditorAttributes(untouched) as? NSTextView)
        #expect(editor.isAutomaticTextReplacementEnabled == defaultReplacementSetting)
    }

    @Test func disablingSubstitutionsUsesAPrivateFieldEditorInsteadOfTheSharedOne() throws {
        let field = AlasNSTextFieldView()
        field.disablesAutomaticTextSubstitutions = true
        let cell = try #require(field.cell as? AlasNSTextFieldCell)
        let dummyControlView = NSView()
        let first = cell.fieldEditor(for: dummyControlView)
        let second = cell.fieldEditor(for: dummyControlView)
        #expect(first != nil)
        #expect(first === second)

        let plainField = AlasNSTextFieldView()
        let plainCell = try #require(plainField.cell as? AlasNSTextFieldCell)
        #expect(plainCell.fieldEditor(for: dummyControlView) == nil)
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Every real call site (`NewWorktreeDialog`, `WorkspaceDialogs`) presents
    /// `focusAndPlaceCaretAtEnd()` is the exact synchronous call `updateNSView`
    /// makes when `focusOnAppear` fires — no SwiftUI rendering, no
    /// `RunLoop.run(until:)` pumping, nothing between "focus acquired" and this
    /// assertion. That matters: `RunLoop.run(until:)` doesn't stop the instant
    /// something happens, it keeps draining ready sources for its whole
    /// window, so even a very short pump could let a deferred
    /// `DispatchQueue.main.async` correction run before the assertion — making
    /// a pump-based test pass against a regression by luck depending on
    /// scheduling. Calling the method directly and asserting on its return
    /// removes that ambiguity: acquiring first responder selects all of the
    /// field's pre-filled text by default (AppKit's behavior), and this must
    /// already be corrected to end-of-string by the time the call returns, or
    /// the very next keystroke would replace the whole selection instead of
    /// appending to it.
    @Test func focusAndPlaceCaretAtEndCorrectsSelectionBeforeReturning() {
        let field = AlasNSTextFieldView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        field.stringValue = "nacho/"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = field

        #expect(field.focusAndPlaceCaretAtEnd())

        let editor = try! #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))

        editor.insertText("feature", replacementRange: editor.selectedRange())
        #expect(editor.string == "nacho/feature")
        #expect(editor.selectedRange() == NSRange(location: 13, length: 0))
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }
}
