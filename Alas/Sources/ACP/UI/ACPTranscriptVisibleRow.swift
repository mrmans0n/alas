import Foundation

/// One rendered transcript row: its index into `ACPTranscript.messages` and the
/// stable id used as its scroll anchor and SwiftUI identity.
struct ACPTranscriptVisibleRow: Identifiable, Equatable {
    let index: Int
    let stableId: String

    var id: String { stableId }

    /// Window-sliced, plan-filtered row list. The slice bounds first-paint cost
    /// on long transcripts; the filter drops `.plan` entries because the toolbar
    /// pill renders the current turn's plan instead of an inline card.
    static func rows(
        messages: [ACPMessage],
        visibleHead: Int,
        visibleTail: Int,
        stableId: (ACPMessage) -> String
    ) -> [ACPTranscriptVisibleRow] {
        let head = min(visibleHead, messages.count)
        let tail = max(head, min(visibleTail, messages.count))
        return (head..<tail).compactMap { index in
            let message = messages[index]
            if case .plan = message { return nil }
            return ACPTranscriptVisibleRow(index: index, stableId: stableId(message))
        }
    }
}
