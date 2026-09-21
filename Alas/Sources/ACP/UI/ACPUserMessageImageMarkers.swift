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
    static func displayText(text: String, attachments: [ACPMessage.Attachment]) -> String {
        let images = attachments.enumerated().filter { $0.element.mimeType?.hasPrefix("image/") == true }
        guard !images.isEmpty else { return text }
        let chars = Array(text)
        let needsNumbering = images.count > 1
        let markers: [(offset: Int, label: String)] = images.enumerated().compactMap { position, item in
            guard let offset = item.element.textOffset else { return nil }
            let clamped = min(max(offset, 0), chars.count)
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
            result += String(chars[cursor..<marker.offset])
            result += "`\(marker.label)`"
            cursor = marker.offset
        }
        result += String(chars[cursor...])
        return result
    }
}
