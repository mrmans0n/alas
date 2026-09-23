import Testing
import SwiftUI
import AppKit
@testable import Alas

/// Regression tests for the new-worktree branch/stack name field: while the
/// user is editing, `updateNSView`'s edit-sync replaces the field editor's
/// text whenever the binding value diverges (issue attach seeding the name,
/// the gg availability probe carrying the typed branch into the stack field).
/// That replacement used to clamp the caret to the new length; combined with
/// a caret at the end of the old text it parked the caret one position short
/// of the end of a growing replacement — the reported "caret jumps to the
/// penultimate character" symptom (#1311, #1326, #1345, #1354 lineage).
@Suite(.serialized)
@MainActor
struct AlasFieldCaretSyncTests {
    init() {
        _ = NSApplication.shared
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func drainMainQueue() {
        // RunLoop.run(until:) does not reliably service the main dispatch
        // queue in test runners; drain it explicitly.
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    private final class NameModel: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }

    /// Mirrors the real call sites: an observing view re-renders on binding
    /// writes (the dialog body reads `activeName` for the preview/labels), so
    /// programmatic writes reach `updateNSView` mid-edit.
    private struct ObservedHost: View {
        @ObservedObject var model: NameModel
        var get: () -> String
        var set: (String) -> Void
        init(model: NameModel, get: (() -> String)? = nil, set: ((String) -> Void)? = nil) {
            self.model = model
            self.get = get ?? { model.text }
            self.set = set ?? { model.text = $0 }
        }
        var body: some View {
            AlasField(
                text: Binding(get: get, set: set),
                monospaced: true,
                disablesAutomaticTextSubstitutions: true
            )
        }
    }

    @Test func programmaticReplacementKeepsCaretAtEndWhenTypingAtEnd() throws {
        let model = NameModel("abc")
        let host = NSHostingController(rootView: ObservedHost(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 28),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host.view
        host.view.layoutSubtreeIfNeeded()
        pump()

        let field = try #require(Self.firstTextField(in: host.view))
        #expect(window.makeFirstResponder(field))
        pump()

        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump()
        #expect(model.text == "abcd")

        // External write that grows the content: the caret must land at the
        // end, not one position short — between the last two characters.
        model.text = "abcde"
        pump()
        #expect(editor.string == "abcde")
        #expect(editor.selectedRange() == NSRange(location: 5, length: 0))

        // The next keystroke must append, not insert mid-word.
        editor.insertText("f", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump()
        #expect(editor.string == "abcdef")
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))

        // External write that shrinks the content: caret stays at the end.
        model.text = "abc"
        pump()
        #expect(editor.string == "abc")
        #expect(editor.selectedRange() == NSRange(location: 3, length: 0))

        window.orderOut(nil)
    }

    /// A caret placed at "the end" via grapheme count (`stringValue.count`)
    /// lands inside any multi-unit UTF-16 character. `focusAndPlaceCaretAtEnd`
    /// must use UTF-16 length.
    @Test func focusCaretUsesUTF16Length() throws {
        let field = AlasNSTextFieldView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        field.stringValue = "a\u{1F600}"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = field

        #expect(field.focusAndPlaceCaretAtEnd())

        let editor = try! #require(field.currentEditor() as? NSTextView)
        // "a" is 1 unit, the emoji 2 → caret must sit at 3, not 2 (which
        // would split the surrogate pair and place the caret before it).
        #expect(editor.selectedRange() == NSRange(location: 3, length: 0))
    }
}
