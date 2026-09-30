import AppKit

/// Existing absolute paths typed, pasted or restored into the composer become
/// display-only chips. The message still carries the full path as plain text
/// (`ACPInputField.Coordinator.extract`), so the agent sees what was written.
extension ACPNSTextView {
    private var chipsAbsolutePaths: Bool {
        guard let root = coordinator?.worktreeRoot else { return false }
        return !root.isRemoteAlasPath
    }

    /// When the typed whitespace completes a path token that exists on disk,
    /// returns the edit (from the path's start to the caret; the chip, any
    /// trailing punctuation, then the typed whitespace) for `insertText` to
    /// apply in one step.
    func absolutePathChipTarget(
        completing text: String,
        at range: NSRange
    ) -> (range: NSRange, replacement: NSAttributedString)? {
        guard chipsAbsolutePaths, let textStorage, range.length == 0,
              text.count == 1, text.first?.isWhitespace == true
        else { return nil }
        let string = textStorage.string as NSString
        guard range.location <= string.length else { return nil }
        var start = range.location
        while start > 0, !Self.isWhitespace(string.character(at: start - 1)) { start -= 1 }
        guard start < range.location else { return nil }
        let token = string.substring(with: NSRange(location: start, length: range.location - start))
        guard let match = ACPAbsolutePathDetector.matches(in: token, followedBy: 0x20).first else { return nil }
        let matchRange = NSRange(location: start + match.range.location, length: match.range.length)
        guard !Self.codeRanges(in: textStorage.string, unclosedRunsExtendToEnd: true)
            .contains(where: { NSIntersectionRange($0, matchRange).length > 0 })
        else { return nil }
        let attributes = textStorage.attributes(at: matchRange.location, effectiveRange: nil)
        let replacement = NSMutableAttributedString(attributedString: ACPPathChip.chip(for: match.shifted(to: matchRange), attributes: attributes))
        let tail = NSRange(location: NSMaxRange(matchRange), length: range.location - NSMaxRange(matchRange))
        if tail.length > 0 {
            replacement.append(textStorage.attributedSubstring(from: tail))
        }
        replacement.append(NSAttributedString(string: text, attributes: typingAttributes))
        return (NSRange(location: matchRange.location, length: range.location - matchRange.location), replacement)
    }

    /// Chips paths in a fragment about to replace `range`. The characters on
    /// either side decide whether the fragment's edges are boundaries. A paste
    /// landing inside an open code span in the surrounding text is skipped.
    @discardableResult
    func chipAbsolutePaths(in fragment: NSMutableAttributedString, replacing range: NSRange) -> Bool {
        guard chipsAbsolutePaths, let textStorage else { return false }
        let string = textStorage.string as NSString
        let prefix = string.substring(to: range.location) as NSString
        let closed = ACPUpstreamReferenceDetector.codeRanges(in: prefix, unclosedRunsExtendToEnd: false)
        let open = ACPUpstreamReferenceDetector.codeRanges(in: prefix, unclosedRunsExtendToEnd: true)
        guard open.count <= closed.count else { return false }
        let before: unichar? = range.location > 0 ? string.character(at: range.location - 1) : nil
        let after: unichar? = NSMaxRange(range) < string.length ? string.character(at: NSMaxRange(range)) : nil
        let code = Self.codeRanges(in: fragment.string, unclosedRunsExtendToEnd: false)
        return ACPPathChip.chipify(fragment, precededBy: before, followedBy: after, excluding: { range in
            code.contains { NSIntersectionRange($0, range).length > 0 }
        }) > 0
    }

    /// Chips paths in a just-restored draft. A path ending the text is left
    /// alone: the user may have been mid-way through typing it.
    func chipAbsolutePathsInRestoredStorage() {
        guard chipsAbsolutePaths, let textStorage else { return }
        let code = Self.codeRanges(in: textStorage.string, unclosedRunsExtendToEnd: true)
        let end = textStorage.length
        ACPPathChip.chipify(textStorage, excluding: { range in
            NSMaxRange(range) == end || code.contains { NSIntersectionRange($0, range).length > 0 }
        })
    }

    private static func codeRanges(in text: String, unclosedRunsExtendToEnd: Bool) -> [NSRange] {
        MarkdownFenceEditing.blocks(in: text).map(\.outerRange)
            + ACPUpstreamReferenceDetector.codeRanges(in: text as NSString, unclosedRunsExtendToEnd: unclosedRunsExtendToEnd)
    }

    private static func isWhitespace(_ ch: unichar) -> Bool {
        Unicode.Scalar(ch).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
    }
}

private extension ACPAbsolutePathDetector.Match {
    func shifted(to range: NSRange) -> Self {
        Self(range: range, path: path, isDirectory: isDirectory)
    }
}
