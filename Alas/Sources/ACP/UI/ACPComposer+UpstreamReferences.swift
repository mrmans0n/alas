import AppKit

extension ACPNSTextView {
    private var upstreamReferenceContext: (store: ACPUpstreamReferenceStore, host: CodeHostKind)? {
        guard let store = coordinator?.upstreamReferences, let host = store.hostKind else { return nil }
        return (store, host)
    }

    /// When the typed whitespace completes a reference, returns the edit
    /// (range from the sigil to the caret, and the chip plus carried-over
    /// punctuation plus the typed whitespace) for `insertText` to apply in
    /// one step.
    func upstreamReferenceChipTarget(
        completing text: String,
        at range: NSRange
    ) -> (range: NSRange, replacement: NSAttributedString)? {
        guard let textStorage, let context = upstreamReferenceContext,
              let target = ACPUpstreamReferenceDetector.chipTarget(
                  completingWith: text, at: range, in: textStorage.string, host: context.host
              )
        else { return nil }
        let attributes = textStorage.attributes(at: target.match.range.location, effectiveRange: nil)
        let replacement = NSMutableAttributedString(attributedString: ACPUpstreamReferenceChip.chip(
            for: target.match.reference, host: context.host, store: context.store, attributes: attributes
        ))
        let tailStart = NSMaxRange(target.match.range)
        let tail = NSRange(location: tailStart, length: NSMaxRange(target.replaceRange) - tailStart)
        if tail.length > 0 {
            replacement.append(textStorage.attributedSubstring(from: tail))
        }
        replacement.append(NSAttributedString(string: text, attributes: typingAttributes))
        context.store.ensureLoaded(target.match.reference)
        return (target.replaceRange, replacement)
    }

    /// Chips references in a fragment about to replace `range`. The
    /// characters on either side of `range` decide whether the fragment's
    /// edges are boundaries, so `#12` pasted right after `abc` stays text.
    /// A pasted same-repository PR/MR/issue URL also becomes a chip. A paste
    /// landing inside an existing (possibly still-open) code span or fenced
    /// block in the surrounding text is skipped entirely, mirroring the
    /// keystroke path's check.
    @discardableResult
    func chipUpstreamReferences(in fragment: NSMutableAttributedString, replacing range: NSRange) -> Bool {
        guard let textStorage, let context = upstreamReferenceContext else { return false }
        let string = textStorage.string as NSString
        let prefix = string.substring(to: range.location) as NSString
        // `prefix` ends exactly at the paste point by construction, so a
        // code span still open there never satisfies `NSLocationInRange`
        // against its own end (any range this scan finds has
        // `NSMaxRange <= range.location`). Detect an open span at the caret
        // by comparing against the closed-spans-only scan instead: an extra
        // range only shows up when the trailing run was left open through
        // the caret.
        let closedRanges = ACPUpstreamReferenceDetector.codeRanges(in: prefix, unclosedRunsExtendToEnd: false)
        let rangesThroughCaret = ACPUpstreamReferenceDetector.codeRanges(in: prefix, unclosedRunsExtendToEnd: true)
        guard rangesThroughCaret.count <= closedRanges.count else { return false }
        let before: unichar? = range.location > 0 ? string.character(at: range.location - 1) : nil
        let after: unichar? = NSMaxRange(range) < string.length ? string.character(at: NSMaxRange(range)) : nil
        return ACPUpstreamReferenceChip.chipify(
            fragment, host: context.host, store: context.store,
            precededBy: before, followedBy: after, urlRemote: context.store.remote
        ) > 0
    }

    /// Chips references already sitting in the composer once the remote
    /// resolves or the message is about to send, each as an ordinary
    /// undoable edit. The token ending at the caret is skipped, because the
    /// user may still be typing its digits — unless `includingCaretToken`,
    /// which send passes since nothing more is coming. Skipped entirely
    /// while an IME composition is open: inserting over the marked text
    /// would commit it under the user, and send finishes the job anyway.
    func chipUpstreamReferencesIfNeeded(includingCaretToken: Bool = false) {
        guard let textStorage, let context = upstreamReferenceContext, !hasMarkedText() else { return }
        let matches = ACPUpstreamReferenceDetector.chippableMatches(
            in: textStorage.string, host: context.host, caret: includingCaretToken ? nil : selectedRange()
        )
        for match in matches.reversed() {
            let attributes = textStorage.attributes(at: match.range.location, effectiveRange: nil)
            replaceUndoably(
                range: match.range,
                with: ACPUpstreamReferenceChip.chip(
                    for: match.reference, host: context.host, store: context.store, attributes: attributes
                )
            )
            context.store.ensureLoaded(match.reference)
        }
    }
}
