import AppKit

extension ACPNSTextView {
    private var upstreamReferenceContext: (store: ACPUpstreamReferenceStore, host: CodeHostKind)? {
        guard let store = coordinator?.upstreamReferences, let host = store.hostKind else { return nil }
        return (store, host)
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
    /// resolves. The token ending at the caret is skipped, because the user
    /// may still be typing its digits.
    func chipUpstreamReferencesIfNeeded() {
        guard let textStorage, let context = upstreamReferenceContext else { return }
        let caret = selectedRange()
        let matches = ACPUpstreamReferenceDetector.references(in: textStorage.string, host: context.host)
            .filter { !(caret.length == 0 && NSMaxRange($0.range) == caret.location) }
        for match in matches.reversed() {
            let attributes = textStorage.attributes(at: match.range.location, effectiveRange: nil)
            replaceClearingUndo(
                range: match.range,
                with: ACPUpstreamReferenceChip.chip(
                    for: match.reference, host: context.host, store: context.store, attributes: attributes
                )
            )
            context.store.ensureLoaded(match.reference)
        }
    }
}
