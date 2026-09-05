import AppKit
import SwiftUI

class PairedDelimiterTextView: NSTextView {
    private var bypassesPairedDelimiterResolution = false
    private var appliesPairedDelimiterResolutionForKeyboardInput = false
    /// Text that the in-flight marked composition swallowed, kept so a dead-key
    /// delimiter can still wrap the selection the user had before pressing it.
    private var selectionReplacedByMarkedText: NSAttributedString?
    /// Opt-in triple-backtick handling. Off by default so surfaces that are
    /// not markdown — the shell startup script editors — keep plain pairing.
    var markdownFencesEnabled = false
    /// Set by the owning representable when fences are enabled; drives both
    /// text styling and the box drawn in `drawBackground(in:)`.
    var markdownCodeBlockStyle: MarkdownCodeBlockStyle?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isAutomaticQuoteSubstitutionEnabled = false
    }

    /// Full-width rects covering each fenced block, in view coordinates.
    ///
    /// The `.backgroundColor` attribute is not used for this: it paints behind
    /// glyphs only, so a code block would get a ragged right edge instead of a
    /// box. These views are TextKit 1, so the layout manager gives us the
    /// bounding rect directly.
    func codeBlockBackgroundRects() -> [NSRect] {
        guard markdownFencesEnabled,
              let layoutManager,
              let textContainer
        else { return [] }

        let full = NSRange(location: 0, length: (string as NSString).length)
        let padding = textContainer.lineFragmentPadding

        return MarkdownFenceEditing.blocks(in: string).compactMap { block in
            let range = NSIntersectionRange(block.outerRange, full)
            guard range.length > 0 else { return nil }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return nil }
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x = textContainerInset.width + padding
            rect.size.width = textContainer.size.width - padding * 2
            rect.origin.y += textContainerInset.height
            return rect.insetBy(dx: 0, dy: -2)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let style = markdownCodeBlockStyle else { return }
        for box in codeBlockBackgroundRects() where box.intersects(rect) {
            let path = NSBezierPath(
                roundedRect: box.insetBy(dx: style.borderWidth / 2, dy: style.borderWidth / 2),
                xRadius: style.cornerRadius,
                yRadius: style.cornerRadius
            )
            style.backgroundColor.setFill()
            path.fill()
            style.borderColor.setStroke()
            path.lineWidth = style.borderWidth
            path.stroke()
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() {
            let replaced = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            selectionReplacedByMarkedText = textStorage.flatMap { storage in
                replaced.length > 0 && Self.isValid(replaced, in: storage)
                    ? storage.attributedSubstring(from: replaced)
                    : nil
            }
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let replacedSelection = selectionReplacedByMarkedText
        selectionReplacedByMarkedText = nil

        guard !bypassesPairedDelimiterResolution,
              appliesPairedDelimiterResolutionForKeyboardInput,
              let insertedText = Self.plainText(from: insertString)
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        if hasMarkedText() {
            commitMarkedText(
                insertString,
                insertedText: insertedText,
                replacementRange: replacementRange,
                replacedSelection: replacedSelection
            )
            return
        }

        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange

        if markdownFencesEnabled {
            switch MarkdownFenceEditing.resolve(
                insertedText: insertedText,
                in: string,
                selectedRange: range
            ) {
            case .openBlock:
                // The two backticks already in the storage plus this keystroke
                // become the whole block — and so does any closer that auto-
                // pairing parked after the caret, or it survives as a stray
                // backtick below the box.
                let trailing = MarkdownFenceEditing.trailingBacktickRun(at: range.location, in: string)
                insertFencedBlock(
                    replacing: NSRange(location: range.location - 2, length: 2 + trailing),
                    body: NSAttributedString()
                )
                return
            case .wrapSelection:
                // The selection is carried through as attributed text, not as a
                // `String`: a mention or image chip is a single U+FFFC whose
                // whole meaning lives in its attributes, so flattening it here
                // would leave an inert glyph behind in the box.
                guard let textStorage, Self.isValid(range, in: textStorage) else {
                    super.insertText(insertString, replacementRange: replacementRange)
                    return
                }
                insertFencedBlock(
                    replacing: NSRange(location: range.location - 2, length: range.length + 4),
                    body: textStorage.attributedSubstring(from: range)
                )
                return
            case .none:
                // `MarkdownFenceEditing.resolve` returns `.none` here on
                // purpose — its contract is to fall through to plain pairing
                // for anything it doesn't recognize, including a delimiter
                // that lands on or inside an existing block. But
                // `PairedDelimiterEditing` has no notion of fences, so the
                // partner it adds on the user's behalf can re-cut the
                // document's blocks — see `fenceCollisionOutcome`.
                switch Self.fenceCollisionOutcome(
                    insertedText: insertedText,
                    in: string,
                    range: range
                ) {
                case .pair:
                    break
                case .insertLiterally:
                    super.insertText(insertString, replacementRange: replacementRange)
                    return
                case .swallow:
                    return
                }
            }
        }

        switch PairedDelimiterEditing.resolve(insertedText: insertedText, in: string, selectedRange: range) {
        case let .wrap(opening, closing):
            guard let textStorage, Self.isValid(range, in: textStorage) else {
                super.insertText(insertString, replacementRange: replacementRange)
                return
            }

            let replacement = NSMutableAttributedString(
                string: String(opening),
                attributes: typingAttributes
            )
            replacement.append(textStorage.attributedSubstring(from: range))
            replacement.append(NSAttributedString(
                string: String(closing),
                attributes: typingAttributes
            ))
            super.insertText(replacement, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + 1, length: range.length))

        case let .insertPair(opening, closing):
            let replacement = NSAttributedString(
                string: String(opening) + String(closing),
                attributes: typingAttributes
            )
            super.insertText(replacement, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + 1, length: 0))

        case .stepOver:
            setSelectedRange(NSRange(location: range.location + 1, length: 0))

        case .native:
            super.insertText(insertString, replacementRange: replacementRange)
        }
    }

    func fencedBlockRange(containing location: Int) -> FencedBlock? {
        guard markdownFencesEnabled else { return nil }
        return MarkdownFenceEditing.block(containing: location, in: string)
    }

    /// What to do with a delimiter keystroke `MarkdownFenceEditing` declined
    /// to handle, once the damage `PairedDelimiterEditing`'s pairing would do
    /// to the document's fences is accounted for.
    private enum FenceCollisionOutcome {
        /// Nothing at risk — let `PairedDelimiterEditing` resolve normally.
        case pair
        /// Pairing would re-cut the document; the bare keystroke won't. Insert
        /// the typed character on its own, without its partner.
        case insertLiterally
        /// Even the bare keystroke re-cuts the document.
        case swallow
    }

    /// How to handle a delimiter landing at `range` in `text` — one
    /// `MarkdownFenceEditing` declined to handle, most commonly because it's
    /// on or inside an existing block.
    ///
    /// `text` is the document the keystroke lands in. On the ordinary keyboard
    /// path that is the live storage; on the dead-key commit path it is the
    /// pre-composition document `PairedDelimiterEditing.preCompositionContext`
    /// reconstructs, because the storage still holds the marked text.
    ///
    /// `PairedDelimiterEditing` knows nothing about fences. It answers a
    /// delimiter by putting *more* than the typed character into the storage:
    /// `.insertPair` writes two, `.wrap` writes one against each end of the
    /// selection. That extra partner is what extends a backtick run far
    /// enough to read as a fence line, or drops a quote into a closing
    /// fence's info string where CommonMark then refuses to see a closer —
    /// either way the document gets re-cut behind the author's back.
    ///
    /// Rather than restating the fence grammar here — line starts, indent
    /// tolerance, info strings, how wide a run must be to close its opener —
    /// in a form that has to be kept in step with the parser, this asks the
    /// parser: apply the exact edit `PairedDelimiterEditing` would apply, and
    /// compare the fenced blocks that come back against the ones already on
    /// screen. Every position the edit touches is covered at once, because
    /// the comparison is over the whole document, and the check holds for any
    /// delimiter rather than only for backticks.
    ///
    /// The two halves of the edit are judged by different standards, because
    /// they have different authors. The partner character is the editor's own
    /// doing, so it has to leave the fences *exactly* as it found them. The
    /// typed character is the author's, so it only has to leave the blocks
    /// that are already closed alone — finishing a block that was left open
    /// is the author completing their own fence, and refusing it would make
    /// an unclosed block impossible to close by typing.
    ///
    /// Falling back to the bare character is offered only from a caret.
    /// `PairedDelimiterEditing.wrap` is the only resolution a selection gets,
    /// and its unpadded equivalent is AppKit's plain overtype — which deletes
    /// the selection, newlines and all. That is both destructive and outside
    /// what `fenceStructure(of:)` can reason about, so a selection whose wrap
    /// would re-cut the document is refused rather than downgraded.
    private static func fenceCollisionOutcome(
        insertedText: String,
        in text: String,
        range: NSRange
    ) -> FenceCollisionOutcome {
        let ns = text as NSString
        guard isValid(range, in: ns),
              // Fence lines are built out of backticks, and nothing on this
              // path ever deletes a character, so a document with no fence in
              // it cannot grow one from a keystroke that isn't a backtick.
              insertedText.contains("`" as Character)
                  || ns.range(of: narrowestFence).location != NSNotFound,
              let padded = pairedDelimiterPaddedResult(of: insertedText, in: text, at: range)
        else { return .pair }

        let current = fenceStructure(of: text)
        guard fenceStructure(of: padded) != current else { return .pair }

        guard range.length == 0 else { return .swallow }
        let literal = fenceStructure(of: ns.replacingCharacters(in: range, with: insertedText))
        return preservesFences(literal, from: current) ? .insertLiterally : .swallow
    }

    /// The narrowest backtick run CommonMark will read as a fence, and so the
    /// shortest substring a document must contain to have any fence at all.
    private static let narrowestFence = String(
        repeating: "`",
        count: MarkdownFenceEditing.minimumFenceLength
    )

    /// Whether `edited` still fences the document the way `current` does:
    /// the same blocks, each opening on the line it opened on, and no block
    /// that was closed losing or moving its closer. A block left *unclosed*
    /// may gain a closer — see `fenceCollisionOutcome` for why that one
    /// direction of change is the author's prerogative.
    private static func preservesFences(
        _ edited: [FencedBlockLines],
        from current: [FencedBlockLines]
    ) -> Bool {
        edited.count == current.count
            && zip(current, edited).allSatisfy { was, now in
                was.open == now.open && (was.close == nil || was.close == now.close)
            }
    }

    /// `text` as `PairedDelimiterEditing` would leave it, or `nil` when the
    /// resolution adds nothing beyond the typed character.
    ///
    /// `.stepOver` writes nothing at all, and `.native` writes exactly the
    /// character the user pressed. Neither is this method's business: a
    /// `.native` insertion *can* still disturb a fence — dropping a literal
    /// backtick into an info string kills the line it lands on, as in
    /// `` "``` swift" `` — but there is no partner character to blame it on,
    /// so the only options would be to honour it or to eat a keystroke the
    /// author deliberately typed. `fenceCollisionOutcome` honours it, and
    /// reaches for the same shape itself as a fallback.
    private static func pairedDelimiterPaddedResult(
        of insertedText: String,
        in text: String,
        at range: NSRange
    ) -> String? {
        let ns = text as NSString
        guard isValid(range, in: ns) else { return nil }

        switch PairedDelimiterEditing.resolve(
            insertedText: insertedText,
            in: text,
            selectedRange: range
        ) {
        case let .wrap(opening, closing):
            return ns.replacingCharacters(
                in: range,
                with: String(opening) + ns.substring(with: range) + String(closing)
            )
        case let .insertPair(opening, closing):
            return ns.replacingCharacters(in: range, with: String(opening) + String(closing))
        case .stepOver, .native:
            return nil
        }
    }

    /// Where every fenced block begins and ends, in line numbers.
    ///
    /// Line numbers rather than character offsets, so that two fingerprints
    /// taken either side of an edit compare directly without any offset
    /// arithmetic. Openers and closers pin the whole structure: everything
    /// else `blocks(in:)` reports (bodies, outer ranges, info strings)
    /// follows from which lines fence which.
    ///
    /// That comparison assumes the edit between the two fingerprints leaves
    /// every line's number alone. It holds for the edits
    /// `fenceCollisionOutcome` weighs: each inserts one or two delimiters and
    /// deletes nothing, so no line terminator is created or destroyed —
    /// unless the caller hands over a `replacementRange` that splits a CRLF,
    /// which AppKit does not do because it reports carets and selections on
    /// composed-character-sequence boundaries. Were that assumption ever
    /// broken, the lines below the split would renumber and the two
    /// fingerprints would compare unequal: a keystroke needlessly refused,
    /// never a corruption let through.
    private static func fenceStructure(of text: String) -> [FencedBlockLines] {
        let ns = text as NSString
        var lineStarts: [Int] = []
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            guard lineRange.length > 0 else { break }
            lineStarts.append(lineRange.location)
            location = NSMaxRange(lineRange)
        }

        func lineNumber(of offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            var line = 0
            while low <= high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= offset {
                    line = middle
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            return line
        }

        return MarkdownFenceEditing.blocks(in: text).map { block in
            FencedBlockLines(
                open: lineNumber(of: block.openFenceRange.location),
                close: block.closeFenceRange.map { lineNumber(of: $0.location) }
            )
        }
    }

    /// One fenced block reduced to the lines its fences sit on, the unit
    /// `fenceStructure(of:)` compares. `close` is `nil` for a block that runs
    /// to the end of the document unclosed.
    private struct FencedBlockLines: Equatable {
        var open: Int
        var close: Int?
    }

    /// Replace `replaced` with a complete fenced block wrapping `body`, adding
    /// the newlines needed to keep both fences on lines of their own, and leave
    /// the selection on the body.
    ///
    /// `body` is attributed rather than plain text because the selection being
    /// fenced can hold a mention or image chip — an `NSTextAttachment` whose
    /// identity is entirely in its attributes — and rebuilding the block from a
    /// `String` would silently reduce that chip to a placeholder glyph.
    private func insertFencedBlock(replacing replaced: NSRange, body: NSAttributedString) {
        guard let textStorage, Self.isValid(replaced, in: textStorage) else { return }
        let expansion = Self.fencedBlockExpansion(
            replacing: replaced,
            body: body.string as NSString,
            in: string as NSString
        )

        undoManager?.beginUndoGrouping()
        performNativeTextInsertion {
            super.insertText(
                expansion.replacement(body: body, attributes: typingAttributes),
                replacementRange: replaced
            )
        }
        undoManager?.endUndoGrouping()

        setSelectedRange(NSRange(location: expansion.bodyStart, length: body.length))
    }

    /// The fence text a block expands to around its body, plus the offset the
    /// body will start at once installed.
    ///
    /// The fences themselves are plain text — nothing about them can carry an
    /// attachment — so they are built from `typingAttributes`. The body is
    /// spliced in exactly as captured, which is what keeps a fenced chip a chip.
    private struct FencedBlockExpansion {
        /// Everything written before the body: a separating newline when the
        /// opener needs a line of its own, the opening fence, and its terminator.
        var prefix: String
        /// Everything written after it: the body's own terminator when it lacks
        /// one, the closing fence, and a separating newline when the text below
        /// needs a line of its own.
        var suffix: String
        var bodyStart: Int

        func replacement(
            body: NSAttributedString,
            attributes: [NSAttributedString.Key: Any]
        ) -> NSAttributedString {
            let result = NSMutableAttributedString(string: prefix, attributes: attributes)
            result.append(body)
            result.append(NSAttributedString(string: suffix, attributes: attributes))
            return result
        }
    }

    /// How a fenced block expands around `body` when it replaces `replaced` in
    /// `text`.
    ///
    /// Split out of `insertFencedBlock` so the dead-key commit path can build
    /// the identical expansion from the pre-composition document rather than
    /// from live storage, which still holds the marked text.
    private static func fencedBlockExpansion(
        replacing replaced: NSRange,
        body: NSString,
        in text: NSString
    ) -> FencedBlockExpansion {
        let needsLeadingNewline = replaced.location > 0
            && text.character(at: replaced.location - 1) != 0x0A
        let suffixLocation = NSMaxRange(replaced)
        let needsTrailingNewline = suffixLocation < text.length
            && text.character(at: suffixLocation) != 0x0A
        let leading = needsLeadingNewline ? "\n" : ""
        let trailing = needsTrailingNewline ? "\n" : ""
        // Selecting whole lines takes the last one's terminator along, so the
        // body already ends on a line of its own. Adding another newline there
        // would push a blank line the author never typed into their own content.
        let separator = endsWithLineTerminator(body) ? "" : "\n"

        return FencedBlockExpansion(
            prefix: leading + "```\n",
            suffix: separator + "```" + trailing,
            // "```\n" is four characters past the leading newline, if any.
            bodyStart: replaced.location + (leading as NSString).length + 4
        )
    }

    /// Whether `body` already ends on a line of its own. Recognizes the same
    /// terminators `MarkdownFenceEditing.trimmingLineTerminator` strips, so a
    /// CRLF selection is judged the way the fence parser judges it.
    private static func endsWithLineTerminator(_ body: NSString) -> Bool {
        guard body.length > 0 else { return false }
        let last = body.character(at: body.length - 1)
        return last == 0x0A || last == 0x0D
    }

    override func unmarkText() {
        selectionReplacedByMarkedText = nil
        super.unmarkText()
    }

    /// Handles the keystroke that commits a marked composition. Only a
    /// single-character commit that matches the marked text itself is treated as
    /// a dead-key delimiter — an accented result (`"` then `o` → `ö`) or a
    /// multi-character IME candidate falls through to native insertion.
    private func commitMarkedText(
        _ insertString: Any,
        insertedText: String,
        replacementRange: NSRange,
        replacedSelection: NSAttributedString?
    ) {
        let marked = markedRange()
        let nsString = string as NSString
        guard insertedText.count == 1,
              Self.isValid(marked, in: nsString),
              marked.length > 0,
              nsString.substring(with: marked) == insertedText,
              let context = PairedDelimiterEditing.preCompositionContext(
                  text: string,
                  markedRange: marked,
                  replacedSelection: replacedSelection?.string ?? ""
              )
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        // Dead-key layouts route the third backtick through here, so fence
        // expansion and the collision guard have to be consulted on this path
        // too — against the pre-composition document, since the marked text is
        // still sitting in the storage.
        if markdownFencesEnabled {
            switch MarkdownFenceEditing.resolve(
                insertedText: insertedText,
                in: context.text,
                selectedRange: context.selectedRange
            ) {
            case .openBlock:
                let trailing = MarkdownFenceEditing.trailingBacktickRun(
                    at: context.selectedRange.location,
                    in: context.text
                )
                commitFencedBlock(
                    replacing: NSRange(
                        location: context.selectedRange.location - 2,
                        length: 2 + trailing
                    ),
                    body: NSAttributedString(),
                    context: context,
                    markedRange: marked
                )
                return
            case .wrapSelection:
                // `replacedSelection` is exactly what the composition swallowed
                // — the attributed text `preCompositionContext` put back at
                // `context.selectedRange` — so it is the body, chips and all.
                // Anything else would flatten a fenced mention into a glyph.
                let body = replacedSelection ?? NSAttributedString(
                    string: (context.text as NSString).substring(with: context.selectedRange),
                    attributes: typingAttributes
                )
                commitFencedBlock(
                    replacing: NSRange(
                        location: context.selectedRange.location - 2,
                        length: context.selectedRange.length + 4
                    ),
                    body: body,
                    context: context,
                    markedRange: marked
                )
                return
            case .none:
                switch Self.fenceCollisionOutcome(
                    insertedText: insertedText,
                    in: context.text,
                    range: context.selectedRange
                ) {
                case .pair:
                    break
                case .insertLiterally:
                    replaceMarkedText(
                        with: NSAttributedString(
                            string: insertedText,
                            attributes: typingAttributes
                        ),
                        markedRange: marked
                    )
                    setSelectedRange(NSRange(
                        location: marked.location + (insertedText as NSString).length,
                        length: 0
                    ))
                    return
                case .swallow:
                    // The normal path simply drops the keystroke. Here the
                    // composition already ate whatever the selection held, so
                    // "no visible change" means putting that back.
                    replaceMarkedText(
                        with: replacedSelection
                            ?? NSAttributedString(string: "", attributes: typingAttributes),
                        markedRange: marked
                    )
                    setSelectedRange(NSRange(
                        location: marked.location,
                        length: context.selectedRange.length
                    ))
                    return
                }
            }
        }

        switch PairedDelimiterEditing.resolve(
            insertedText: insertedText,
            in: context.text,
            selectedRange: context.selectedRange
        ) {
        case let .wrap(opening, closing):
            let replacement = NSMutableAttributedString(
                string: String(opening),
                attributes: typingAttributes
            )
            if let replacedSelection {
                replacement.append(replacedSelection)
            }
            replacement.append(NSAttributedString(
                string: String(closing),
                attributes: typingAttributes
            ))
            replaceMarkedText(with: replacement, markedRange: marked)
            setSelectedRange(NSRange(
                location: marked.location + 1,
                length: context.selectedRange.length
            ))

        case let .insertPair(opening, closing):
            replaceMarkedText(
                with: NSAttributedString(
                    string: String(opening) + String(closing),
                    attributes: typingAttributes
                ),
                markedRange: marked
            )
            setSelectedRange(NSRange(location: marked.location + 1, length: 0))

        case .stepOver:
            replaceMarkedText(
                with: NSAttributedString(string: "", attributes: typingAttributes),
                markedRange: marked
            )
            setSelectedRange(NSRange(location: marked.location + 1, length: 0))

        case .native:
            super.insertText(insertString, replacementRange: replacementRange)
        }
    }

    /// Expands a fenced block from a dead-key commit, the counterpart of
    /// `insertFencedBlock` for the marked-text path.
    ///
    /// `replaced` is in the pre-composition document's coordinates, the ones
    /// `MarkdownFenceEditing` answered in. Live storage differs from that
    /// document in exactly one way — the composition swapped the selection for
    /// the marked text — and that swap happens inside `replaced`, so the
    /// equivalent live range keeps the same start and trades one length for
    /// the other. Replacing it wholesale leaves the same bytes the ordinary
    /// keyboard path would have produced.
    private func commitFencedBlock(
        replacing replaced: NSRange,
        body: NSAttributedString,
        context: (text: String, selectedRange: NSRange),
        markedRange: NSRange
    ) {
        let ns = context.text as NSString
        let live = NSRange(
            location: replaced.location,
            length: replaced.length - context.selectedRange.length + markedRange.length
        )
        guard Self.isValid(replaced, in: ns),
              let textStorage,
              Self.isValid(live, in: textStorage)
        else { return }

        let expansion = Self.fencedBlockExpansion(
            replacing: replaced,
            body: body.string as NSString,
            in: ns
        )

        undoManager?.beginUndoGrouping()
        replaceMarkedText(
            with: expansion.replacement(body: body, attributes: typingAttributes),
            markedRange: live
        )
        undoManager?.endUndoGrouping()

        setSelectedRange(NSRange(location: expansion.bodyStart, length: body.length))
    }

    /// `NSTextView.unmarkText()` finalizes the composition by re-inserting the
    /// marked characters through `insertText`, so the whole replacement has to
    /// run with pairing suppressed or the placeholder pairs with itself.
    ///
    /// `markedRange` is the range the replacement is written over. It is the
    /// marked range itself for a plain pairing commit, and a range containing
    /// it when a fence expansion also rewrites the characters around the
    /// composition.
    private func replaceMarkedText(with replacement: NSAttributedString, markedRange: NSRange) {
        performNativeTextInsertion {
            unmarkText()
            super.insertText(replacement, replacementRange: markedRange)
        }
    }

    override func keyDown(with event: NSEvent) {
        performKeyboardTextInsertion {
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        performNativeTextInsertion {
            super.paste(sender)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        performNativeTextInsertion {
            super.pasteAsPlainText(sender)
        }
    }

    override func pasteAsRichText(_ sender: Any?) {
        performNativeTextInsertion {
            super.pasteAsRichText(sender)
        }
    }

    func performKeyboardTextInsertion(_ insert: () -> Void) {
        appliesPairedDelimiterResolutionForKeyboardInput = true
        defer { appliesPairedDelimiterResolutionForKeyboardInput = false }
        insert()
    }

    func performNativeTextInsertion(_ insert: () -> Void) {
        bypassesPairedDelimiterResolution = true
        defer { bypassesPairedDelimiterResolution = false }
        insert()
    }

    private static func plainText(from value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private static func isValid(_ range: NSRange, in storage: NSTextStorage) -> Bool {
        isValid(range, length: storage.length)
    }

    private static func isValid(_ range: NSRange, in string: NSString) -> Bool {
        isValid(range, length: string.length)
    }

    private static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }
}

struct PairedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var textColor: NSColor
    var isEnabled: Bool
    var isBordered: Bool
    var isBezeled: Bool
    var drawsBackground: Bool
    var bezelStyle: NSTextField.BezelStyle?
    var focusRingType: NSFocusRingType
    var isFocused: Binding<Bool>?
    var onSubmit: (() -> Void)?

    init(
        text: Binding<String>,
        placeholder: String = "",
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        textColor: NSColor = .labelColor,
        isEnabled: Bool = true,
        isBordered: Bool = false,
        isBezeled: Bool = false,
        drawsBackground: Bool = false,
        bezelStyle: NSTextField.BezelStyle? = nil,
        focusRingType: NSFocusRingType = .default,
        isFocused: Binding<Bool>? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.font = font
        self.textColor = textColor
        self.isEnabled = isEnabled
        self.isBordered = isBordered
        self.isBezeled = isBezeled
        self.drawsBackground = drawsBackground
        self.bezelStyle = bezelStyle
        self.focusRingType = focusRingType
        self.isFocused = isFocused
        self.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PairedTextFieldBackingView {
        let field = PairedTextFieldBackingView()
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.onWindowChanged = { [weak coordinator = context.coordinator, weak field] in
            guard let field else { return }
            coordinator?.synchronizeFocus(for: field)
        }
        applyConfiguration(to: field, coordinator: context.coordinator)
        return field
    }

    func updateNSView(_ field: PairedTextFieldBackingView, context: Context) {
        context.coordinator.parent = self
        applyConfiguration(to: field, coordinator: context.coordinator)
        context.coordinator.synchronizeFocus(for: field)
    }

    static func dismantleNSView(_ field: PairedTextFieldBackingView, coordinator: Coordinator) {
        let window = field.window
        let editor = field.currentEditor()
        field.onWindowChanged = nil
        field.delegate = nil
        field.target = nil
        if let editor, window?.firstResponder === editor {
            window?.makeFirstResponder(nil)
        }
    }

    private func applyConfiguration(to field: NSTextField, coordinator: Coordinator) {
        field.placeholderString = placeholder
        field.font = font
        field.textColor = textColor
        field.isBordered = isBordered
        field.isBezeled = isBezeled
        field.drawsBackground = drawsBackground
        field.focusRingType = focusRingType
        if let bezelStyle {
            field.bezelStyle = bezelStyle
        }
        field.isEnabled = isEnabled
        field.isEditable = isEnabled
        field.isSelectable = isEnabled

        let fieldEditor = coordinator.fieldEditor(for: field)
        if field.stringValue != text {
            field.stringValue = text
        }
        if let fieldEditor, fieldEditor.string != text {
            let selection = fieldEditor.selectedRange()
            fieldEditor.string = text
            fieldEditor.setSelectedRange(Self.clamped(selection, in: text))
        }
        fieldEditor?.font = font
        fieldEditor?.textColor = textColor
    }

    private static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PairedTextField

        init(_ parent: PairedTextField) {
            self.parent = parent
        }

        @objc func submit(_ sender: NSTextField) {
            updateText(sender.stringValue)
            parent.onSubmit?()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            updateText(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            updateFocus(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            updateFocus(false)
        }

        func synchronizeFocus(for field: NSTextField) {
            guard let binding = parent.isFocused, let window = field.window else { return }
            let editor = fieldEditor(for: field)
            let ownsFocus = window.firstResponder === field || window.firstResponder === editor
            let wantsFocus = binding.wrappedValue && parent.isEnabled

            if wantsFocus, !ownsFocus {
                window.makeFirstResponder(field)
            } else if !wantsFocus, ownsFocus {
                window.makeFirstResponder(nil)
            }
        }

        func fieldEditor(for field: NSTextField) -> NSTextView? {
            field.currentEditor() as? NSTextView
        }

        private func updateText(_ value: String) {
            if parent.text != value {
                parent.text = value
            }
        }

        private func updateFocus(_ value: Bool) {
            if let binding = parent.isFocused, binding.wrappedValue != value {
                binding.wrappedValue = value
            }
        }
    }
}

struct PairedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var isEnabled: Bool
    var isFocused: Binding<Bool>?
    var textContainerInset: NSSize
    var placeholder: String?
    var codeBlockStyle: MarkdownCodeBlockStyle?

    init(
        text: Binding<String>,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        textColor: NSColor = .labelColor,
        isEnabled: Bool = true,
        isFocused: Binding<Bool>? = nil,
        textContainerInset: NSSize = .zero,
        placeholder: String? = nil,
        codeBlockStyle: MarkdownCodeBlockStyle? = nil
    ) {
        _text = text
        self.font = font
        self.textColor = textColor
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.textContainerInset = textContainerInset
        self.placeholder = placeholder
        self.codeBlockStyle = codeBlockStyle
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = makeBackingView()
        textView.delegate = context.coordinator
        if let backingView = textView as? PairedTextEditorBackingView {
            backingView.onWindowChanged = { [weak coordinator = context.coordinator, weak backingView] in
                guard let backingView else { return }
                coordinator?.synchronizeFocus(for: backingView)
            }
        }
        context.coordinator.textView = textView
        return scrollView
    }

    /// Test seam: builds the scroll view and its backing text view without a
    /// SwiftUI `Context`, which cannot be constructed outside a live view
    /// update. Coordinator wiring (delegate, window callback, back-reference)
    /// is left to `makeNSView(context:)`.
    func makeBackingView() -> (NSScrollView, PairedDelimiterTextView) {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = PairedTextEditorBackingView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        synchronizeLayout(of: textView, in: scrollView)
        applyConfiguration(to: textView)
        return (scrollView, textView)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PairedDelimiterTextView else { return }
        synchronizeLayout(of: textView, in: scrollView)
        applyConfiguration(to: textView)
        context.coordinator.synchronizeFocus(for: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? PairedTextEditorBackingView else { return }
        let window = textView.window
        textView.onWindowChanged = nil
        textView.delegate = nil
        coordinator.textView = nil
        if window?.firstResponder === textView {
            window?.makeFirstResponder(nil)
        }
    }

    private func applyConfiguration(to textView: PairedDelimiterTextView) {
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(Self.clamped(selection, in: text))
        }
        textView.font = font
        textView.textColor = textColor
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.textContainerInset = textContainerInset
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.markdownFencesEnabled = codeBlockStyle != nil
        textView.markdownCodeBlockStyle = codeBlockStyle
        // `textView.string = text` above discards every attribute, so the
        // restyle has to run on each sync, not only on textDidChange.
        if let codeBlockStyle, let storage = textView.textStorage {
            MarkdownCodeBlockStyler.restyle(storage, in: nil, style: codeBlockStyle)
            textView.needsDisplay = true
        }
    }

    /// Test seam: forwards to the private `applyConfiguration(to:)` so tests
    /// can drive configuration without a SwiftUI `Context`.
    func applyConfigurationForTesting(to textView: PairedDelimiterTextView) {
        applyConfiguration(to: textView)
    }

    private func synchronizeLayout(of textView: PairedDelimiterTextView, in scrollView: NSScrollView) {
        let viewport = scrollView.contentView.bounds.size
        let width = max(viewport.width, scrollView.contentSize.width)
        let viewportHeight = max(viewport.height, scrollView.contentSize.height)
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        let contentHeight = Self.laidOutContentHeight(of: textView)
        let height = max(viewportHeight, contentHeight)
        textView.minSize = NSSize(width: 0, height: height)
        textView.frame.size = NSSize(
            width: width,
            height: height
        )
    }

    private static func laidOutContentHeight(of textView: PairedDelimiterTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return 0 }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return ceil(usedRect.height + textView.textContainerInset.height * 2)
    }

    private static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PairedTextEditor
        weak var textView: PairedDelimiterTextView?

        init(_ parent: PairedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  parent.text != textView.string
            else { return }
            parent.text = textView.string
            if let style = parent.codeBlockStyle, let storage = textView.textStorage {
                MarkdownCodeBlockStyler.restyle(storage, in: nil, style: style)
                textView.needsDisplay = true
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            updateFocus(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            updateFocus(false)
        }

        func synchronizeFocus(for textView: NSTextView) {
            guard let binding = parent.isFocused, let window = textView.window else { return }
            let ownsFocus = window.firstResponder === textView
            let wantsFocus = binding.wrappedValue && parent.isEnabled

            if wantsFocus, !ownsFocus {
                window.makeFirstResponder(textView)
            } else if !wantsFocus, ownsFocus {
                window.makeFirstResponder(nil)
            }
        }

        private func updateFocus(_ value: Bool) {
            if let binding = parent.isFocused, binding.wrappedValue != value {
                binding.wrappedValue = value
            }
        }
    }
}

final class PairedTextFieldBackingView: NSTextField {
    var onWindowChanged: (() -> Void)?

    /// AppKit never routes a should-change-text callback to an `NSTextField`
    /// delegate, so delimiter pairing has to live in the field editor itself.
    override class var cellClass: AnyClass? {
        get { PairedTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }
}

final class PairedTextFieldCell: NSTextFieldCell {
    private lazy var pairedFieldEditor: PairedDelimiterTextView = {
        let editor = PairedDelimiterTextView()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        pairedFieldEditor
    }
}

private final class PairedTextEditorBackingView: PairedDelimiterTextView {
    var onWindowChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }
}
