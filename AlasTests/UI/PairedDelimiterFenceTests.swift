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

    @Test("a multi-line selection inside a block does not open a nested box either")
    func noNestedBoxAcrossMultilineSelection() {
        let textView = makeTextView()
        textView.string = "```\n\nfoo\n```"
        // Covers the blank body line's own newline plus "foo" — wrapping this
        // twice already leaves a bare, would-be-closing run one keystroke away.
        textView.setSelectedRange(NSRange(location: 4, length: 4))
        type("```", into: textView)

        #expect(textView.string == "```\n``\nfoo``\n```")
        #expect(textView.selectedRange() == NSRange(location: 6, length: 4))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("backticks that don't start a line are never swallowed")
    func midLineBackticksAreNotSwallowed() {
        let textView = makeTextView()
        // "x``" sits mid-line: no run starting there can ever parse as a
        // fence line, so the completing keystroke must land normally.
        textView.string = "```\nx``\n```"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        type("`", into: textView)

        #expect(textView.string == "```\nx````\n```")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("the swallow still applies inside a block opened with a wider fence")
    func noNestedBoxInsideWiderFence() {
        let textView = makeTextView()
        textView.string = "````\n\n````"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        type("```", into: textView)

        #expect(textView.string == "````\n``\n````")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a selection wrap can also corrupt the block via its right flank")
    func noNestedBoxFromRightFlankOfSelection() {
        let textView = makeTextView()
        // The left flank "xx``" is mid-line (safe on its own), but the right
        // flank "``" sits alone on its own line — bare and line-starting —
        // so completing it would still split the block. The guard has to
        // catch the right flank even though the left one is harmless.
        textView.string = "```\nxx``\n``\n```"
        textView.setSelectedRange(NSRange(location: 8, length: 1))
        type("`", into: textView)

        #expect(textView.string == "```\nxx``\n``\n```")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 1))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a selection flanked by mid-line backtick runs on both sides is left alone")
    func midLineFlanksOnBothSidesAreNotSwallowed() {
        let textView = makeTextView()
        // Both "xx``" and "``yy" are mid-line — a fence line can never form
        // on either side, so completing the wrap is safe and must not be
        // swallowed.
        textView.string = "```\nxx``Z``yy\n```"
        textView.setSelectedRange(NSRange(location: 8, length: 1))
        type("`", into: textView)

        #expect(textView.string == "```\nxx```Z```yy\n```")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 1))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a dangerous right flank is caught even when the left flank has no preceding backticks at all")
    func rightFlankDangerDoesNotDependOnLeftFlankBacktickCount() {
        let textView = makeTextView()
        // The selection is preceded by "\n" — zero backticks, not merely "not
        // exactly two" — so the left flank can never be mistaken for
        // dangerous. Only an independent check of the right flank ("``" alone
        // on its own line) catches this.
        textView.string = "```\nX\n``\n```"
        textView.setSelectedRange(NSRange(location: 4, length: 2))
        type("`", into: textView)

        #expect(textView.string == "```\nX\n``\n```")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 2))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a dangerous right flank is caught even when the selection starts outside any block")
    func rightFlankDangerDoesNotDependOnLeftFlankBlockContainment() {
        let textView = makeTextView()
        // The selection starts before the block even opens, so checking
        // block containment only at the selection's start would miss that
        // the selection's end — where the right flank actually sits — is
        // inside the block, flanked by a bare "``" line about to complete.
        textView.string = "X\n```\n``\n```"
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        type("`", into: textView)

        #expect(textView.string == "X\n```\n``\n```")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 6))
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
