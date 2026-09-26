import AppKit
import Testing
@testable import Alas

/// One keystroke scenario: seed the view, type, then check the document.
/// Optional expectations are only asserted when set.
struct PairedDelimiterFenceCase: Sendable, CustomTestStringConvertible {
    enum CloserCheck: Sendable {
        case unchecked
        /// The first block must still have a closing fence.
        case firstBlock
        /// The last block must still have a closing fence.
        case lastBlock
    }

    let name: String
    /// Seed text; `nil` leaves the fresh view untouched.
    var text: String? = nil
    var selection: (location: Int, length: Int)? = nil
    let typed: String
    let expectedText: String
    var expectedSelection: (location: Int, length: Int)? = nil
    var blockCount: Int? = nil
    var closer: CloserCheck = .unchecked
    /// Substring the first block's body must contain.
    var bodyContains: String? = nil

    var testDescription: String { name }
}

extension PairedDelimiterFenceCase {
    /// Keystrokes that open a new box or wrap a selection in one.
    static let expansions: [PairedDelimiterFenceCase] = [
        PairedDelimiterFenceCase(
            name: "three backticks open an empty code box",
            typed: "```", expectedText: "```\n\n```", expectedSelection: (4, 0)
        ),
        PairedDelimiterFenceCase(
            name: "a fence opened mid-line starts on its own line",
            typed: "run```", expectedText: "run\n```\n\n```", expectedSelection: (8, 0)
        ),
        PairedDelimiterFenceCase(
            name: "a fence opened after more than three leading spaces still starts on its own line",
            text: "    ", selection: (4, 0),
            typed: "```", expectedText: "    \n```\n\n```", expectedSelection: (9, 0)
        ),
        PairedDelimiterFenceCase(
            name: "following text is pushed past the closing fence",
            text: "tail", selection: (0, 0),
            typed: "```", expectedText: "```\n\n```\ntail"
        ),
        // Also the regression guard for the embedded-run width fix: nothing
        // about it may widen the fence for a body that never risked closing
        // it early.
        PairedDelimiterFenceCase(
            name: "three backticks over a selection fence it",
            text: "value", selection: (0, 5),
            typed: "```", expectedText: "```\nvalue\n```", expectedSelection: (4, 5)
        ),
        PairedDelimiterFenceCase(
            name: "wrapping a selection after leading spaces keeps that indentation on both fences",
            text: "  value", selection: (2, 5),
            typed: "```", expectedText: "  ```\nvalue\n  ```", expectedSelection: (6, 5)
        ),
        // Selecting a whole line takes its terminator with it, so the body
        // already ends on a line of its own. The expansion must not add a
        // second newline and push a blank line into the author's content.
        PairedDelimiterFenceCase(
            name: "wrapping whole lines does not add a blank line before the closer",
            text: "value\nmore", selection: (0, 6),
            typed: "```", expectedText: "```\nvalue\n```\nmore", expectedSelection: (4, 6)
        ),
        PairedDelimiterFenceCase(
            name: "wrapping several whole lines keeps exactly one newline before the closer",
            text: "one\ntwo\n", selection: (0, 8),
            typed: "```", expectedText: "```\none\ntwo\n```", expectedSelection: (4, 8)
        ),
        // Counterweight to the marker tests: the span this keystroke rewrites
        // is the two backticks on the first line, which the block below never
        // touches. It has to still expand — and leave the block alone.
        PairedDelimiterFenceCase(
            name: "two backticks on the line above a block still open their own box",
            text: "``\n\n```\nx\n```", selection: (2, 0),
            typed: "`", expectedText: "```\n\n```\n\n```\nx\n```", expectedSelection: (4, 0),
            blockCount: 2, closer: .lastBlock
        ),
        // A block left open — by deleting a closer, or by pasting malformed
        // markdown. Typing its closing fence has to work: the caret sits
        // inside the block, so every keystroke goes through the collision
        // check, and refusing the one that finally closes it would leave the
        // block unclosable from the keyboard forever.
        PairedDelimiterFenceCase(
            name: "an unclosed block can still be closed by typing",
            text: "```\nfoo\n", selection: (8, 0),
            typed: "```", expectedText: "```\nfoo\n```", expectedSelection: (11, 0),
            blockCount: 1, closer: .firstBlock
        ),
        // The exact Codex repro: the selected body is itself nothing but a
        // bare three-backtick run. Relocated onto its own line by the
        // expansion's leading newline, a hardcoded three-wide fence would read
        // that run as its own closer — closing the box one line early and
        // leaving the real closer to open a second, unclosed block.
        PairedDelimiterFenceCase(
            name: "wrapping a selection that begins with a bare backtick run widens the fence instead of corrupting it",
            text: "prefix ```", selection: (7, 3),
            typed: "```", expectedText: "prefix \n````\n```\n````", expectedSelection: (13, 3),
            blockCount: 1, closer: .firstBlock, bodyContains: "```"
        ),
        // Four backticks in the body would still close a hardcoded four-wide
        // fence early; the wrapping fence has to beat whatever is inside it.
        PairedDelimiterFenceCase(
            name: "an embedded fence run wider than three backticks still gets a wider wrapping fence",
            text: "prefix ````", selection: (7, 4),
            typed: "```", expectedText: "prefix \n`````\n````\n`````", expectedSelection: (14, 4),
            blockCount: 1, closer: .firstBlock, bodyContains: "````"
        ),
    ]

    /// Keystrokes at or inside an existing block that must not corrupt it.
    static let existingBlockEdits: [PairedDelimiterFenceCase] = [
        // Covers the blank body line's own newline plus "foo" — wrapping this
        // twice already leaves a bare, would-be-closing run one keystroke away.
        PairedDelimiterFenceCase(
            name: "a multi-line selection inside a block does not open a nested box either",
            text: "```\n\nfoo\n```", selection: (4, 4),
            typed: "```", expectedText: "```\n``\nfoo``\n```", expectedSelection: (6, 4),
            blockCount: 1
        ),
        // Click between the second and third backtick of the closing fence
        // and type another. Two backticks precede the caret and the position
        // is outside the block's interior — a fence's marker is not its
        // interior — so the expansion used to rewrite the closer itself into
        // a fresh empty block and leave the opener unclosed. Nothing about
        // the block may move; the keystroke is a plain step-over.
        PairedDelimiterFenceCase(
            name: "a caret inside a closing fence's own backticks does not open a box",
            text: "```\ncode\n```", selection: (11, 0),
            typed: "`", expectedText: "```\ncode\n```", expectedSelection: (12, 0),
            blockCount: 1, closer: .firstBlock
        ),
        // The same gap at the other marker. Here the damage was worse: the
        // opener was replaced by a whole empty block, pushing the body out of
        // the box entirely and leaving the old closer to open a second one.
        PairedDelimiterFenceCase(
            name: "a caret inside an opening fence's own backticks does not open a box",
            text: "```\ncode\n```", selection: (2, 0),
            typed: "`", expectedText: "```\ncode\n```", expectedSelection: (3, 0),
            blockCount: 1
        ),
        // Four-wide fences, caret two backticks into the closer with two more
        // to its right, so the run the expansion would consume covers the
        // whole marker.
        PairedDelimiterFenceCase(
            name: "a caret inside a wider fence's marker does not open a box",
            text: "````\ncode\n````", selection: (12, 0),
            typed: "`", expectedText: "````\ncode\n````", expectedSelection: (13, 0),
            blockCount: 1
        ),
        // The closer's leading spaces sit outside `outerRange`, so only the
        // marker's own backticks stand between this caret and the block.
        PairedDelimiterFenceCase(
            name: "a caret inside an indented closer's marker does not open a box",
            text: "```\nc\n  ```", selection: (10, 0),
            typed: "`", expectedText: "```\nc\n  ```", expectedSelection: (11, 0),
            blockCount: 1, closer: .firstBlock
        ),
        // "x``" sits mid-line: no run starting there can ever parse as a
        // fence line, so the completing keystroke must land normally.
        PairedDelimiterFenceCase(
            name: "backticks that don't start a line are never swallowed",
            text: "```\nx``\n```", selection: (7, 0),
            typed: "`", expectedText: "```\nx````\n```", expectedSelection: (8, 0),
            blockCount: 1
        ),
        // Pairing the third keystroke would take the body line to four, the
        // opener's own width, and close it early. The bare keystroke stops at
        // three, which a four-wide block simply contains — so the author gets
        // the literal fence line they were typing.
        PairedDelimiterFenceCase(
            name: "inside a block opened with a wider fence, the third backtick lands unpaired",
            text: "````\n\n````", selection: (5, 0),
            typed: "```", expectedText: "````\n```\n````", expectedSelection: (8, 0),
            blockCount: 1
        ),
        // The left flank "xx``" is mid-line (safe on its own), but the right
        // flank "``" sits alone on its own line — bare and line-starting —
        // so completing it would still split the block. The guard has to
        // catch the right flank even though the left one is harmless.
        PairedDelimiterFenceCase(
            name: "a selection wrap can also corrupt the block via its right flank",
            text: "```\nxx``\n``\n```", selection: (8, 1),
            typed: "`", expectedText: "```\nxx``\n``\n```", expectedSelection: (8, 1),
            blockCount: 1
        ),
        // Both "xx``" and "``yy" are mid-line — a fence line can never form
        // on either side, so completing the wrap is safe and must not be
        // swallowed.
        PairedDelimiterFenceCase(
            name: "a selection flanked by mid-line backtick runs on both sides is left alone",
            text: "```\nxx``Z``yy\n```", selection: (8, 1),
            typed: "`", expectedText: "```\nxx```Z```yy\n```", expectedSelection: (9, 1),
            blockCount: 1
        ),
        // The selection is preceded by "\n" — zero backticks, not merely "not
        // exactly two" — so the left flank can never be mistaken for
        // dangerous. Only an independent check of the right flank ("``" alone
        // on its own line) catches this.
        PairedDelimiterFenceCase(
            name: "a dangerous right flank is caught even when the left flank has no preceding backticks at all",
            text: "```\nX\n``\n```", selection: (4, 2),
            typed: "`", expectedText: "```\nX\n``\n```", expectedSelection: (4, 2),
            blockCount: 1
        ),
        // The selection starts before the block even opens, so checking
        // block containment only at the selection's start would miss that
        // the selection's end — where the right flank actually sits — is
        // inside the block, flanked by a bare "``" line about to complete.
        PairedDelimiterFenceCase(
            name: "a dangerous right flank is caught even when the selection starts outside any block",
            text: "X\n```\n``\n```", selection: (0, 6),
            typed: "`", expectedText: "X\n```\n``\n```", expectedSelection: (0, 6),
            blockCount: 1
        ),
        // Mirror image of the "starts outside, ends inside" case: the
        // selection runs from the middle of the body, through the closing
        // fence, down to a bare "``" line under the block. Wrapping it
        // completes that line into a fence, closing the block early and
        // sweeping the trailing text into a second, unclosed one.
        PairedDelimiterFenceCase(
            name: "a selection that starts inside a block and ends below it is caught too",
            text: "```\nxx``\n```\n``\nZ", selection: (8, 5),
            typed: "`", expectedText: "```\nxx``\n```\n``\nZ", expectedSelection: (8, 5),
            blockCount: 1
        ),
        // The selection starts at 2 — ahead of the block, which only opens at
        // 4 — so no single position of it is inside the block, yet it runs
        // through the opener and into the body. Wrapping would fold that
        // opener into a new outer fence and re-cut the document.
        PairedDelimiterFenceCase(
            name: "a selection reaching into a block from outside is not wrapped into a box",
            text: "``A\n```\nb``\n```", selection: (2, 7),
            typed: "`", expectedText: "``A\n```\nb``\n```", expectedSelection: (2, 7),
            blockCount: 1
        ),
        // Both endpoints sit outside the block — before its opener and after
        // its closer — but the block itself is entirely inside the selection,
        // so wrapping would sweep both of its fence lines into the new one.
        PairedDelimiterFenceCase(
            name: "a selection that swallows a whole block is not wrapped into a box",
            text: "``\n```\ncode\n```\n``", selection: (2, 14),
            typed: "`", expectedText: "``\n```\ncode\n```\n``", expectedSelection: (2, 14),
            blockCount: 1
        ),
        // Only one backtick precedes the caret, but `.insertPair` writes two
        // characters, so pairing would land a full three-wide fence. Dropping
        // the partner leaves two, which is no fence at all.
        PairedDelimiterFenceCase(
            name: "a lone body backtick lands without its partner, because pairing would add two more",
            text: "```\n`\n```", selection: (5, 0),
            typed: "`", expectedText: "```\n``\n```", expectedSelection: (6, 0),
            blockCount: 1
        ),
        // The documenting-a-fence shape: a four-wide block whose body is a
        // three-backtick line. Auto-pairing would widen it to five, which
        // closes the four-wide opener early.
        PairedDelimiterFenceCase(
            name: "a three-backtick body line inside a four-wide block is caught",
            text: "````\n```\n````", selection: (8, 0),
            typed: "`", expectedText: "````\n```\n````", expectedSelection: (8, 0),
            blockCount: 1
        ),
        // Same width collision from the selection path: wrapping takes the
        // body's three-backtick line to four, matching the opener.
        PairedDelimiterFenceCase(
            name: "a selection flanked by a three-backtick line inside a four-wide block is caught",
            text: "````\n```\nabc\n````", selection: (8, 4),
            typed: "`", expectedText: "````\n```\nabc\n````", expectedSelection: (8, 4),
            blockCount: 1
        ),
        // Four backticks inside a five-wide block cannot close it, so this
        // keystroke is harmless and has to land.
        PairedDelimiterFenceCase(
            name: "a body line that stays narrower than its opener is left alone",
            text: "`````\n``\n`````", selection: (8, 0),
            typed: "`", expectedText: "`````\n````\n`````", expectedSelection: (9, 0),
            blockCount: 1
        ),
        // One backtick further along than the case above: the pair would take
        // the run from three to five, exactly the opener's width, so it would
        // close. Unpaired it stops at four, one short, and the block survives.
        PairedDelimiterFenceCase(
            name: "a body line that would reach its opener's width loses its partner",
            text: "`````\n```\n`````", selection: (9, 0),
            typed: "`", expectedText: "`````\n````\n`````", expectedSelection: (10, 0),
            blockCount: 1
        ),
        // The two flanks sit in different blocks — the left in the first, the
        // right in the second — so no single enclosing block explains the
        // damage: wrapping turns two blocks into three.
        PairedDelimiterFenceCase(
            name: "a selection spanning two different blocks is caught",
            text: "```\n``\n```\n```\n``\n```", selection: (6, 9),
            typed: "`", expectedText: "```\n``\n```\n```\n``\n```", expectedSelection: (6, 9),
            blockCount: 2
        ),
        // The body line is "``" and the selection starts between the two, so
        // the wrap's opening backtick joins one on each side: a one-backtick
        // left flank still ends up a three-wide bare fence line. Counting
        // only the backticks before the selection sees two and stops.
        PairedDelimiterFenceCase(
            name: "a run that continues into the selection is caught",
            text: "```\n``\nB\n```", selection: (5, 3),
            typed: "`", expectedText: "```\n``\nB\n```", expectedSelection: (5, 3),
            blockCount: 1
        ),
        // Mirror of the above: the selection ends on the first of the body
        // line's two backticks, so the wrap's closing backtick lands between
        // them and the line still completes to three.
        PairedDelimiterFenceCase(
            name: "a run that continues out of the selection is caught",
            text: "```\nB\n``\n```", selection: (4, 3),
            typed: "`", expectedText: "```\nB\n``\n```", expectedSelection: (4, 3),
            blockCount: 1
        ),
        // Nothing to do with backticks: pairing a quote onto the closing
        // fence line gives it an info string, and CommonMark only accepts a
        // closer whose info string is empty — so the block would lose its
        // closer and swallow the rest of the document. Note the block count
        // stays 1 either way; only the string tells the two apart.
        PairedDelimiterFenceCase(
            name: "a quote pairing onto a closing fence is caught too",
            text: "```\n\n```", selection: (8, 0),
            typed: "\"", expectedText: "```\n\n```", expectedSelection: (8, 0),
            closer: .firstBlock
        ),
        // The counterweight to the case above: a body line can never be a
        // fence line, so ordinary pairing there has to keep working.
        PairedDelimiterFenceCase(
            name: "a quote inside a block body pairs as usual",
            text: "```\n\n```", selection: (4, 0),
            typed: "\"", expectedText: "```\n\"\"\n```", expectedSelection: (5, 0),
            blockCount: 1
        ),
        // Pairing takes the opener to five and the bare keystroke to four;
        // either way the three-wide closer stops matching and the block runs
        // off the end of the document. The block count is 1 before and after,
        // so this only fails if the fingerprint notices the closer going away.
        PairedDelimiterFenceCase(
            name: "widening an opening fence past its closer is caught",
            text: "```\nA\n```", selection: (3, 0),
            typed: "`", expectedText: "```\nA\n```", expectedSelection: (3, 0),
            closer: .firstBlock
        ),
    ]
}

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

    private func verify(_ c: PairedDelimiterFenceCase) {
        let textView = makeTextView()
        if let text = c.text {
            textView.string = text
        }
        if let selection = c.selection {
            textView.setSelectedRange(NSRange(location: selection.location, length: selection.length))
        }
        type(c.typed, into: textView)

        #expect(textView.string == c.expectedText)
        if let selection = c.expectedSelection {
            #expect(textView.selectedRange() == NSRange(location: selection.location, length: selection.length))
        }
        let blocks = MarkdownFenceEditing.blocks(in: textView.string)
        if let blockCount = c.blockCount {
            #expect(blocks.count == blockCount)
        }
        switch c.closer {
        case .unchecked:
            break
        case .firstBlock:
            #expect(blocks.first?.closeFenceRange != nil)
        case .lastBlock:
            #expect(blocks.last?.closeFenceRange != nil)
        }
        if let bodyContains = c.bodyContains, let block = blocks.first {
            let bodyText = (textView.string as NSString).substring(with: block.bodyRange)
            #expect(bodyText.contains(bodyContains))
        }
    }

    @Test("Typing a fence opens or wraps a box", arguments: PairedDelimiterFenceCase.expansions)
    func fenceExpansion(_ c: PairedDelimiterFenceCase) {
        verify(c)
    }

    @Test("Typing at or inside an existing block keeps it intact", arguments: PairedDelimiterFenceCase.existingBlockEdits)
    func existingBlockEdit(_ c: PairedDelimiterFenceCase) {
        verify(c)
    }

    @Test("three backticks no longer leave a stray fourth")
    func noStrayFourthBacktick() {
        let textView = makeTextView()
        type("```", into: textView)

        #expect(!textView.string.contains("````"))
    }

    @Test("a fence opened after up to three leading spaces keeps that indentation",
        arguments: [1, 2, 3])
    func fencePreservesLeadingIndent(spaceCount: Int) {
        let textView = makeTextView()
        let indent = String(repeating: " ", count: spaceCount)
        textView.string = indent
        textView.setSelectedRange(NSRange(location: spaceCount, length: 0))
        type("```", into: textView)

        #expect(textView.string == "\(indent)```\n\n\(indent)```")
        #expect(textView.selectedRange() == NSRange(location: spaceCount + 4, length: 0))
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

    // MARK: - Wrapping a selection whose own body contains a backtick run

    @Test("an embedded fence run at the start of a longer, multi-line body still widens the fence")
    func wrapsMultiLineSelectionBeginningWithEmbeddedFenceRun() {
        let textView = makeTextView()
        // Same failure mode, but the body doesn't end at the embedded run —
        // there is real content on the lines after it, which the fix must
        // carry through untouched rather than truncating at the run.
        let body = "```\nmore\nlines"
        textView.string = "prefix " + body
        textView.setSelectedRange(NSRange(location: 7, length: (body as NSString).length))
        type("```", into: textView)

        let blocks = MarkdownFenceEditing.blocks(in: textView.string)
        #expect(blocks.count == 1)
        #expect(blocks.first?.closeFenceRange != nil)
        if let block = blocks.first {
            let bodyText = (textView.string as NSString).substring(with: block.bodyRange)
            #expect(bodyText.contains(body))
        }
    }

    @Test("a body that is itself a complete, closed fenced block is never handed to the width fix at all")
    func selectingAWholeNestedBlockNeverReachesTheExpansion() {
        let textView = makeTextView()
        // A tempting fourth scenario for the width fix would be a body that is
        // itself a whole, valid, narrower fenced block — "```\nx\n```" — to
        // prove it nests as inert content once the wrapping fence is wider.
        // It never gets there: the block's own closer sits right after a real
        // newline that already exists in the document before this keystroke
        // ever lands, so `MarkdownFenceEditing.blocks(in:)` already registers
        // it — as at least an unclosed opener, if nothing else — and
        // `resolve`'s pre-edit disjointness guard (from the *previous* round
        // of this fix) refuses `.wrapSelection` outright before
        // `fencedBlockExpansion` runs at all. The keystroke falls back to
        // plain character pairing instead, which only ever widens the
        // existing block's own fence in place — never a second, corrupting
        // block. This is the guard the width fix is additive to, not a
        // scenario the width fix itself has to handle.
        let body = "```\nx\n```"
        textView.string = "prefix " + body
        textView.setSelectedRange(NSRange(location: 7, length: (body as NSString).length))
        type("```", into: textView)

        // Never reaching `.wrapSelection` at all means this keystroke can
        // only ever widen the pre-existing block's own fence in place, via
        // plain character pairing — so the original body content ("x") is
        // untouched, and there is still exactly one block, not two.
        #expect(textView.string.contains("x"))
        #expect(MarkdownFenceEditing.blocks(in: textView.string).count == 1)
    }
}
