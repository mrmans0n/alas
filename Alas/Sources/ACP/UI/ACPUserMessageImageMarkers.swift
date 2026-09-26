import Foundation

/// Splices a small inline-code tag into a user message's text at each image
/// attachment's captured position, so the transcript bubble shows *something*
/// where the image chip sat instead of an empty gap — image chips contribute
/// no text of their own (see `ACPInputField.Coordinator.extract`), and the
/// image itself renders separately as a thumbnail above the bubble.
enum ACPUserMessageImageMarkers {
    /// Returns `text` with a `` `🖼 …` `` marker inserted at each image
    /// attachment's `textOffset`. A single image gets an unnumbered
    /// `` `🖼 image` `` marker; two or more get `` `🖼 1` ``, `` `🖼 2` ``, …,
    /// numbered by position among ALL image attachments (in attachment-array
    /// order) — the same order `UserMessageRow` renders their thumbnails in,
    /// so a marker's number always matches its thumbnail.
    ///
    /// An image attachment with no `textOffset` (legacy rows, agent-echoed
    /// attachments, heuristic-restored queue items) contributes no marker,
    /// but still consumes a number so the remaining markers stay aligned
    /// with their thumbnails. `text` is returned unchanged when no image has
    /// a usable offset.
    static func displayText(
        text: String,
        attachments: [ACPMessage.Attachment],
        offsetAdjustment: Int = 0
    ) -> String {
        let images = attachments.enumerated().filter { $0.element.mimeType?.hasPrefix("image/") == true }
        guard !images.isEmpty else { return text }
        let chars = Array(text)
        let needsNumbering = images.count > 1
        // `offsetAdjustment` lets a caller that renders only part of the
        // message (a leading command's pill sits outside this text; only
        // its `rest` is passed here) re-anchor offsets captured against the
        // FULL message. An offset that lands before this slice starts — an
        // image attached before a leading command, whose offset is 0 in the
        // full message — clamps to the front of `rest` instead of being
        // dropped; the marker still shows, just no longer glued to a pill
        // it can't render next to.
        let markers: [(offset: Int, label: String)] = images.enumerated().compactMap { position, item in
            guard let offset = item.element.textOffset else { return nil }
            let clamped = min(max(offset + offsetAdjustment, 0), chars.count)
            let label = needsNumbering ? "🖼 \(position + 1)" : "🖼 image"
            return (clamped, label)
        }
        guard !markers.isEmpty else { return text }
        // Swift's sort is stable, so markers sharing an offset keep the
        // attachment order they were built in.
        let ordered = markers.sorted { $0.offset < $1.offset }
        var result = ""
        var cursor = 0
        for marker in ordered {
            append(String(chars[cursor..<marker.offset]), to: &result)
            append("`\(marker.label)`", to: &result)
            cursor = marker.offset
        }
        append(String(chars[cursor...]), to: &result)
        return result
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
