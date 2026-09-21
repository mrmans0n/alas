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

    @Test func fieldWithLeadingIconRendersWithoutCrashing() {
        let view = AlasField(
            text: .constant("test"),
            placeholder: "Placeholder",
            leadingIcon: "magnifyingglass"
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }

    @Test func fieldWithoutLeadingIconRendersWithoutCrashing() {
        let view = AlasField(text: .constant("test"))
            .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
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
    func typingIntoFilteredFieldKeepsEveryCharacterAndCaretAtEnd(prefix: String) {
        let host = TypingHost(initialText: prefix)
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
        for character in "feature-branch" {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: String(character), charactersIgnoringModifiers: String(character),
                isARepeat: false, keyCode: 0
            )!
            editor.keyDown(with: event)
            expected.append(character)
            #expect(editor.string == expected)
            #expect(editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0))
            pump()
            #expect(editor.string == expected)
            #expect(editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0))
        }
    }

    private struct TypingHost {
        var initialText = "nacho/"
        @MainActor var body: some View { Inner(text: initialText) }

        private struct Inner: View {
            @State var text: String
            var body: some View {
                AlasField(
                    text: $text,
                    monospaced: true,
                    focusOnAppear: true,
                    onSubmit: {},
                    inputFilter: .branchName
                )
            }
        }
    }

    @Test func filteredFieldDisablesAutomaticWordChanges() throws {
        let field = AlasNSTextFieldView()
        field.inputFilter = .branchName
        let cell = try #require(field.cell as? AlasNSTextFieldCell)
        let editor = try #require(cell.setUpFieldEditorAttributes(NSTextView()) as? NSTextView)
        #expect(!editor.isAutomaticTextCompletionEnabled)
        #expect(editor.inlinePredictionType == .no)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
    }

    @Test func filteredPasteAndCompositionKeepTheirCaret() {
        let editor = GitRefNameFieldEditor()
        editor.inputFilter = .branchName
        editor.string = "nacho/"
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.insertText("new name/", replacementRange: editor.selectedRange())
        #expect(editor.string == "nacho/newname")
        #expect(editor.selectedRange() == NSRange(location: 13, length: 0))

        editor.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())
        #expect(editor.string == "nacho/newname^")
        editor.insertText("ê", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "nacho/newnameê")
        #expect(!editor.hasMarkedText())
        #expect(editor.selectedRange() == NSRange(location: 14, length: 0))

        editor.setSelectedRange(NSRange(location: 6, length: 3))
        editor.insertText("old", replacementRange: editor.selectedRange())
        #expect(editor.string == "nacho/oldnameê")
        #expect(editor.selectedRange() == NSRange(location: 9, length: 0))

        editor.string = "feature"
        editor.setSelectedRange(NSRange(location: 0, length: 7))
        editor.insertText("fea ture", replacementRange: editor.selectedRange())
        #expect(editor.string == "feature")
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test func rejectingCharacterInMiddleKeepsNextInsertionAtCaret() throws {
        let controller = NSHostingController(rootView: TypingHost().body.environment(\.theme, currentTheme()))
        let window = NSWindow(contentViewController: controller)
        controller.view.layoutSubtreeIfNeeded()
        pump()
        let field = try #require(Self.firstTextField(in: controller.view))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.insertText("feature", replacementRange: editor.selectedRange())
        pump()
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.insertText("?", replacementRange: editor.selectedRange())
        pump()
        #expect(editor.string == "nacho/feature")
        #expect(editor.selectedRange() == NSRange(location: 9, length: 0))
        editor.insertText("s", replacementRange: editor.selectedRange())
        pump()
        #expect(editor.string == "nacho/feasture")
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
