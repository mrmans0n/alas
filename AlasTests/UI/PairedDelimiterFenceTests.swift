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

    @Test("inside a block opened with a wider fence, the third backtick lands unpaired")
    func thirdBacktickLandsUnpairedInsideWiderFence() {
        let textView = makeTextView()
        // Pairing the third keystroke would take the body line to four, the
        // opener's own width, and close it early. The bare keystroke stops at
        // three, which a four-wide block simply contains — so the author gets
        // the literal fence line they were typing.
        textView.string = "````\n\n````"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        type("```", into: textView)

        #expect(textView.string == "````\n```\n````")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
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

    @Test("a selection that starts inside a block and ends below it is caught too")
    func selectionLeavingABlockIsSwallowed() {
        let textView = makeTextView()
        // Mirror image of the "starts outside, ends inside" case: the
        // selection runs from the middle of the body, through the closing
        // fence, down to a bare "``" line under the block. Wrapping it
        // completes that line into a fence, closing the block early and
        // sweeping the trailing text into a second, unclosed one.
        textView.string = "```\nxx``\n```\n``\nZ"
        textView.setSelectedRange(NSRange(location: 8, length: 5))
        type("`", into: textView)

        #expect(textView.string == "```\nxx``\n```\n``\nZ")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 5))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a lone body backtick lands without its partner, because pairing would add two more")
    func caretRunOfOneLosesItsPartner() {
        let textView = makeTextView()
        // Only one backtick precedes the caret, but `.insertPair` writes two
        // characters, so pairing would land a full three-wide fence. Dropping
        // the partner leaves two, which is no fence at all.
        textView.string = "```\n`\n```"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        type("`", into: textView)

        #expect(textView.string == "```\n``\n```")
        #expect(textView.selectedRange() == NSRange(location: 6, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a three-backtick body line inside a four-wide block is caught")
    func caretRunOfThreeIsSwallowedInsideAWiderFence() {
        let textView = makeTextView()
        // The documenting-a-fence shape: a four-wide block whose body is a
        // three-backtick line. Auto-pairing would widen it to five, which
        // closes the four-wide opener early.
        textView.string = "````\n```\n````"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        type("`", into: textView)

        #expect(textView.string == "````\n```\n````")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a selection flanked by a three-backtick line inside a four-wide block is caught")
    func selectionFlankOfThreeIsSwallowedInsideAWiderFence() {
        let textView = makeTextView()
        // Same width collision from the selection path: wrapping takes the
        // body's three-backtick line to four, matching the opener.
        textView.string = "````\n```\nabc\n````"
        textView.setSelectedRange(NSRange(location: 8, length: 4))
        type("`", into: textView)

        #expect(textView.string == "````\n```\nabc\n````")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 4))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a body line that stays narrower than its opener is left alone")
    func runNarrowerThanTheOpenerIsNotSwallowed() {
        let textView = makeTextView()
        // Four backticks inside a five-wide block cannot close it, so this
        // keystroke is harmless and has to land.
        textView.string = "`````\n``\n`````"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        type("`", into: textView)

        #expect(textView.string == "`````\n````\n`````")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a body line that would reach its opener's width loses its partner")
    func runMatchingTheOpenerLosesItsPartner() {
        let textView = makeTextView()
        // One backtick further along than the case above: the pair would take
        // the run from three to five, exactly the opener's width, so it would
        // close. Unpaired it stops at four, one short, and the block survives.
        textView.string = "`````\n```\n`````"
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        type("`", into: textView)

        #expect(textView.string == "`````\n````\n`````")
        #expect(textView.selectedRange() == NSRange(location: 10, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a selection spanning two different blocks is caught")
    func selectionAcrossTwoBlocksIsSwallowed() {
        let textView = makeTextView()
        // The two flanks sit in different blocks — the left in the first, the
        // right in the second — so no single enclosing block explains the
        // damage: wrapping turns two blocks into three.
        textView.string = "```\n``\n```\n```\n``\n```"
        textView.setSelectedRange(NSRange(location: 6, length: 9))
        type("`", into: textView)

        #expect(textView.string == "```\n``\n```\n```\n``\n```")
        #expect(textView.selectedRange() == NSRange(location: 6, length: 9))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 2)
    }

    @Test("a run that continues into the selection is caught")
    func runMergingIntoTheSelectionIsSwallowed() {
        let textView = makeTextView()
        // The body line is "``" and the selection starts between the two, so
        // the wrap's opening backtick joins one on each side: a one-backtick
        // left flank still ends up a three-wide bare fence line. Counting
        // only the backticks before the selection sees two and stops.
        textView.string = "```\n``\nB\n```"
        textView.setSelectedRange(NSRange(location: 5, length: 3))
        type("`", into: textView)

        #expect(textView.string == "```\n``\nB\n```")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 3))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a run that continues out of the selection is caught")
    func runMergingOutOfTheSelectionIsSwallowed() {
        let textView = makeTextView()
        // Mirror of the above: the selection ends on the first of the body
        // line's two backticks, so the wrap's closing backtick lands between
        // them and the line still completes to three.
        textView.string = "```\nB\n``\n```"
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        type("`", into: textView)

        #expect(textView.string == "```\nB\n``\n```")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 3))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("a quote pairing onto a closing fence is caught too")
    func quotePairingOnAClosingFenceIsSwallowed() {
        let textView = makeTextView()
        // Nothing to do with backticks: pairing a quote onto the closing
        // fence line gives it an info string, and CommonMark only accepts a
        // closer whose info string is empty — so the block would lose its
        // closer and swallow the rest of the document. Note the block count
        // stays 1 either way; only the string tells the two apart.
        textView.string = "```\n\n```"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        type("\"", into: textView)

        #expect(textView.string == "```\n\n```")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).first?.closeFenceRange != nil)
    }

    @Test("a quote inside a block body pairs as usual")
    func quotePairingInsideABlockBodyIsUntouched() {
        let textView = makeTextView()
        // The counterweight to the test above: a body line can never be a
        // fence line, so ordinary pairing there has to keep working.
        textView.string = "```\n\n```"
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        type("\"", into: textView)

        #expect(textView.string == "```\n\"\"\n```")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }

    @Test("widening an opening fence past its closer is caught")
    func wideningAnOpenerPastItsCloserIsSwallowed() {
        let textView = makeTextView()
        // Pairing takes the opener to five and the bare keystroke to four;
        // either way the three-wide closer stops matching and the block runs
        // off the end of the document. The block count is 1 before and after,
        // so this only fails if the fingerprint notices the closer going away.
        textView.string = "```\nA\n```"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        type("`", into: textView)

        #expect(textView.string == "```\nA\n```")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).first?.closeFenceRange != nil)
    }

    @Test("an unclosed block can still be closed by typing")
    func unclosedBlockCanBeClosedByTyping() {
        let textView = makeTextView()
        // A block left open — by deleting a closer, or by pasting malformed
        // markdown. Typing its closing fence has to work: the caret sits
        // inside the block, so every keystroke goes through the collision
        // check, and refusing the one that finally closes it would leave the
        // block unclosable from the keyboard forever.
        textView.string = "```\nfoo\n"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        type("```", into: textView)

        #expect(textView.string == "```\nfoo\n```")
        #expect(textView.selectedRange() == NSRange(location: 11, length: 0))
        let blocks = MarkdownFenceEditing.blocks(in: textView.string)
        #expect(blocks.count == 1)
        #expect(blocks.first?.closeFenceRange != nil)
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
