import Testing
import SwiftUI
import AppKit
@testable import Alas

@Suite(.serialized)
@MainActor
struct AlasFieldTests {
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

    @Test func typingIntoFilteredFieldKeepsEveryCharacterAndCaretAtEnd() {
        let host = TypingHost()
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

        for character in "feature" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            pump()
        }

        #expect(editor.string == "nacho/feature")
        #expect(editor.selectedRange().location == (editor.string as NSString).length)
    }

    private struct TypingHost {
        var body: some View { Inner() }

        private struct Inner: View {
            @State private var text = "nacho/"
            var body: some View {
                AlasField(
                    text: $text,
                    monospaced: true,
                    focusOnAppear: true,
                    inputFilter: .branchName
                )
            }
        }
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
