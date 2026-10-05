import Foundation

/// Splices a small inline-code tag into a user message's text at each image
/// attachment's captured position, and a pasted-text marker in place of each
/// pasted span, so the transcript bubble shows *something*
/// where the image chip sat instead of an empty gap — image chips contribute
/// no text of their own (see `ACPInputField.Coordinator.extract`), and the
/// image itself renders separately as a thumbnail above the bubble.
enum ACPUserMessageImageMarkers {
    /// Returns `text` with a `` `🖼 …` `` marker inserted at each image
    /// attachment's `textOffset`, and each valid pasted span replaced by
    /// `ACPPastedTextChip.marker(label:)`. A single image gets an unnumbered
    /// `` `🖼 image` `` marker; two or more get `` `🖼 1` ``, `` `🖼 2` ``, …,
    /// numbered by position among ALL image attachments (in attachment-array
    /// order) — the same order `UserMessageRow` renders their thumbnails in.
    ///
    /// Image offsets are `Character` counts and are converted to UTF-16
    /// locations; pasted spans are already UTF-16. An image location that
    /// falls inside a span moves to the span's end. `offsetAdjustment`
    /// (characters) and `utf16OffsetAdjustment` (UTF-16 units) re-anchor
    /// offsets captured against the full message when the caller renders
    /// only part of it. An invalid span set is ignored as a whole. `text`
    /// is returned unchanged when there is nothing to splice.
    static func displayText(
        text: String,
        attachments: [ACPMessage.Attachment],
        pastedSpans: [ACPPastedTextSpan] = [],
        offsetAdjustment: Int = 0,
        utf16OffsetAdjustment: Int = 0
    ) -> String {
        let images = attachments.enumerated().filter { $0.element.mimeType?.hasPrefix("image/") == true }
        let spans = pastedSpans.isEmpty ? [] : reanchoredSpans(
            text: text, pastedSpans: pastedSpans, utf16OffsetAdjustment: utf16OffsetAdjustment
        )
        guard !images.isEmpty || !spans.isEmpty else { return text }

        struct Edit {
            let location: Int
            let length: Int
            let replacement: String
        }
        let source = text as NSString
        let needsNumbering = images.count > 1
        var edits: [Edit] = images.enumerated().compactMap { position, item in
            guard let offset = item.element.textOffset else { return nil }
            // An offset before this slice starts (an image attached before a
            // leading command) clamps to the front instead of being dropped.
            let index = text.index(text.startIndex, offsetBy: max(offset + offsetAdjustment, 0), limitedBy: text.endIndex)
                ?? text.endIndex
            var location = index.utf16Offset(in: text)
            if let span = spans.first(where: { $0.utf16Offset < location && location < NSMaxRange($0.utf16Range) }) {
                location = NSMaxRange(span.utf16Range)
            }
            let label = needsNumbering ? "🖼 \(position + 1)" : "🖼 image"
            return Edit(location: location, length: 0, replacement: "`\(label)`")
        }
        edits += spans.map { span in
            Edit(
                location: span.utf16Offset,
                length: span.utf16Length,
                replacement: ACPPastedTextChip.marker(label: ACPPastedTextPolicy.label(
                    ordinal: span.ordinal, content: source.substring(with: span.utf16Range)
                ))
            )
        }
        // Zero-length image inserts sort ahead of a span starting at the same
        // location. Swift's sort is stable, so images sharing an offset keep
        // the attachment order they were built in.
        edits.sort { ($0.location, $0.length) < ($1.location, $1.length) }
        var result = ""
        var cursor = 0
        // Typed text can carry the private-use delimiters too (they can be
        // pasted), so they are replaced here: only markers built below may
        // become chips.
        func typed(_ piece: String) -> String {
            guard !spans.isEmpty else { return piece }
            return piece
                .replacingOccurrences(of: "\u{E000}", with: "\u{FFFD}")
                .replacingOccurrences(of: "\u{E001}", with: "\u{FFFD}")
        }
        for edit in edits {
            append(typed(source.substring(with: NSRange(location: cursor, length: edit.location - cursor))), to: &result)
            append(edit.replacement, to: &result)
            cursor = edit.location + edit.length
        }
        append(typed(source.substring(from: cursor)), to: &result)
        return result
    }

    /// Shifts each span by `utf16OffsetAdjustment` and validates the set
    /// against `text`. An overflowing shift invalidates the whole set, the
    /// same as any other invalid span.
    private static func reanchoredSpans(
        text: String,
        pastedSpans: [ACPPastedTextSpan],
        utf16OffsetAdjustment: Int
    ) -> [ACPPastedTextSpan] {
        var shifted: [ACPPastedTextSpan] = []
        shifted.reserveCapacity(pastedSpans.count)
        for span in pastedSpans {
            let (offset, overflow) = span.utf16Offset.addingReportingOverflow(utf16OffsetAdjustment)
            if overflow { return [] }
            shifted.append(ACPPastedTextSpan(ordinal: span.ordinal, utf16Offset: offset, utf16Length: span.utf16Length))
        }
        return ACPPastedTextContents(text: text, spans: shifted)?.spans ?? []
    }

    /// Appends `piece` to `result`, inserting a single separating space
    /// first if `result` ends and `piece` begins with a backtick. Two
    /// backtick-delimited spans placed directly against each other — a
    /// marker next to pre-existing inline code in the original text, or two
    /// markers sharing an offset — form one contiguous run of backticks.
    /// Markdown's code-span rule matches a closer only to an opener of the
    /// SAME run length, so a 2-backtick run in the middle doesn't close
    /// either neighboring single-backtick span; the parser instead treats
    /// the whole stretch as one merged/corrupted span. The separating space
    /// keeps each backtick run isolated to its own span.
    private static func append(_ piece: String, to result: inout String) {
        guard !piece.isEmpty else { return }
        if result.hasSuffix("`"), piece.hasPrefix("`") {
            result += " "
        }
        result += piece
    }
}
