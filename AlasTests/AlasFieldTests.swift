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
    /// this field inside a `.sheet`, not a plain top-level window — first
    /// responder is acquired automatically via `focusOnAppear`, never by a
    /// manual `makeFirstResponder` call from the caller. Acquiring first
    /// responder selects all of the pre-filled text by default (AppKit's
    /// behavior); the field must move the caret to the end in that same pass so
    /// the very first keystroke appends instead of replacing the whole
    /// selection. A deferred (async) correction loses that race.
    private struct SheetHost: View {
        @Binding var text: String
        let theme: Theme
        var body: some View {
            Color.clear
                .frame(width: 300, height: 100)
                .sheet(isPresented: .constant(true)) {
                    AlasField(text: $text, monospaced: true, focusOnAppear: true, inputFilter: .branchName)
                        .environment(\.theme, theme)
                        .frame(width: 260)
                        .padding()
                }
        }
    }

    @Test func firstKeystrokeAfterAutomaticFocusAppendsRatherThanReplacesPrefilledText() {
        var text = "nacho/"
        let binding = Binding(get: { text }, set: { text = $0 })
        let controller = NSHostingController(rootView: SheetHost(text: binding, theme: currentTheme()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()

        // Poll in small increments rather than sleeping a fixed, generous
        // window before asserting: a long fixed pump would give the buggy
        // deferred (DispatchQueue.main.async) correction time to catch up
        // before this test ever looks at the selection, letting a regression
        // pass here by luck on a fast machine. Stop polling the instant the
        // editor exists, then assert immediately — before typing anything —
        // that the caret is already at the end, not mid-flight to it.
        var editor: NSTextView?
        for _ in 0..<200 {
            if let sheet = window.attachedSheet,
               let field = Self.firstTextField(in: sheet.contentView!),
               let currentEditor = field.currentEditor() as? NSTextView {
                editor = currentEditor
                break
            }
            pump(0.01)
        }
        let unwrappedEditor = try! #require(editor)

        #expect(unwrappedEditor.selectedRange() == NSRange(location: (unwrappedEditor.string as NSString).length, length: 0))

        for character in "feature" {
            unwrappedEditor.insertText(String(character), replacementRange: unwrappedEditor.selectedRange())
            pump()
        }

        #expect(unwrappedEditor.string == "nacho/feature")
        #expect(unwrappedEditor.selectedRange() == NSRange(location: (unwrappedEditor.string as NSString).length, length: 0))
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }
}
