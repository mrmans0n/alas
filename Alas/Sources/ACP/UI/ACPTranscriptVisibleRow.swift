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
        // Replayed history can contain several snapshots of the same message.
        // Match the lookup's last-snapshot policy so the tiler receives one row
        // per identity, without changing the stored transcript.
        var seen = Set<String>()
        let rows: [ACPTranscriptVisibleRow] = (head..<tail).reversed().compactMap { index in
            let message = messages[index]
            if case .plan = message { return nil }
            let id = stableId(message)
            guard seen.insert(id).inserted else { return nil }
            return ACPTranscriptVisibleRow(index: index, stableId: id)
        }
        return rows.reversed()
    }
}

/// O(1) transcript-index lookup by row or stable id, built once per render
/// window and reused by scroll callbacks that need the mapping until the
/// window changes. A tool-call group id resolves to its first member's
/// index; a bundled member's own stable id still resolves to its index so
/// anchors recorded before the fold keep working.
struct ACPTranscriptVisibleRowLookup {
    private let indexById: [String: Int]
    private let rowIdByStableId: [String: String]

    init(rows: [ACPTranscriptRenderRow]) {
        var indexById: [String: Int] = [:]
        var rowIdByStableId: [String: String] = [:]
        indexById.reserveCapacity(rows.count)
        rowIdByStableId.reserveCapacity(rows.count)
        for row in rows {
            switch row {
            case .message(let visible):
                indexById[visible.stableId] = visible.index
                rowIdByStableId[visible.stableId] = visible.stableId
            case .toolCallGroup(let group):
                indexById[group.id] = group.members[0].index
                for member in group.members {
                    indexById[member.stableId] = member.index
                    rowIdByStableId[member.stableId] = group.id
                }
            }
        }
        self.indexById = indexById
        self.rowIdByStableId = rowIdByStableId
    }

    func transcriptIndex(for id: String?) -> Int? {
        guard let id else { return nil }
        return indexById[id]
    }

    /// The tiled row that displays `stableId`: the id itself for a plain
    /// message row, the enclosing group id for a bundled tool call, nil when
    /// the message is outside the render window.
    func rowId(forStableId stableId: String) -> String? {
        rowIdByStableId[stableId]
    }
}
