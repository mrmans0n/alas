import AppKit
import Testing
@testable import Alas

@Suite("Paired delimiter code fences")
@MainActor
struct PairedDelimiterFenceTests {
    private func makeTextView(fencesEnabled: Bool = true) -> PairedDelimiterTextView {
        let textView = PairedDelimiterTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.markdownFencesEnabled = fencesEnabled
        return textView
    }

    private func type(_ characters: String, into textView: PairedDelimiterTextView) {
        for character in characters {
            textView.performKeyboardTextInsertion {
                textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    @Test("three backticks open an empty code box")
    func threeBackticksOpenBox() {
        let textView = makeTextView()
        type("```", into: textView)

        #expect(textView.string == "```\n\n```")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test("three backticks no longer leave a stray fourth")
    func noStrayFourthBacktick() {
        let textView = makeTextView()
        type("```", into: textView)

        #expect(!textView.string.contains("````"))
    }

    @Test("a fence opened mid-line starts on its own line")
    func fenceStartsOnOwnLine() {
        let textView = makeTextView()
        type("run```", into: textView)

        #expect(textView.string == "run\n```\n\n```")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    @Test("following text is pushed past the closing fence")
    func trailingTextGetsItsOwnLine() {
        let textView = makeTextView()
        textView.string = "tail"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("```", into: textView)

        #expect(textView.string == "```\n\n```\ntail")
    }

    @Test("three backticks over a selection fence it")
    func wrapsSelection() {
        let textView = makeTextView()
        textView.string = "value"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        type("```", into: textView)

        #expect(textView.string == "```\nvalue\n```")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 5))
    }

    @Test("backticks inside a block do not open a nested box")
    func noNestedBox() {
        let textView = makeTextView()
        textView.string = "```\n\n```"
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        type("```", into: textView)

        #expect(textView.string.hasPrefix("```\n"))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("expansion is a single undo group")
    func singleUndoGroup() throws {
        let textView = makeTextView()
        // NSTextView's undo manager comes from the responder chain, so the
        // view needs a window before typing or no undo actions get recorded.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        #expect(window.makeFirstResponder(textView))
        textView.allowsUndo = true
        type("```", into: textView)
        #expect(textView.string == "```\n\n```")

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(!textView.string.contains("\n"))
    }

    @Test("disabled by default, leaving existing pairing untouched")
    func disabledByDefault() {
        let textView = makeTextView(fencesEnabled: false)
        type("```", into: textView)

        #expect(textView.string == "````")
    }
}
