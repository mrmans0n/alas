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
    private let spanById: [String: ClosedRange<Int>]

    init(rows: [ACPTranscriptRenderRow]) {
        var indexById: [String: Int] = [:]
        var rowIdByStableId: [String: String] = [:]
        var spanById: [String: ClosedRange<Int>] = [:]
        indexById.reserveCapacity(rows.count)
        rowIdByStableId.reserveCapacity(rows.count)
        for row in rows {
            switch row {
            case .message(let visible), .toolCallGroupMember(let visible, _):
                // An expanded bundle's member is indexed exactly like a
                // plain message row: its own id, its own single-message
                // span. That is what makes the scroller's geometry exact
                // for it, and what makes its row id survive expanding,
                // collapsing or disabling the setting.
                indexById[visible.stableId] = visible.index
                rowIdByStableId[visible.stableId] = visible.stableId
                spanById[visible.stableId] = visible.index...visible.index
            case .toolCallGroup(let group):
                indexById[group.id] = group.members[0].index
                spanById[group.id] = group.members[0].index...group.members[group.members.count - 1].index
                for member in group.members {
                    indexById[member.stableId] = member.index
                    rowIdByStableId[member.stableId] = group.id
                }
            case .toolCallGroupHeader(let group):
                // The header stands for no message of ITS OWN: the first
                // member follows as its own row and owns that index. So it
                // gets an anchor index (anchors and remaps still resolve
                // it) but deliberately NO span — see `localIndexSpan`.
                // Members are not registered here; each registers itself as
                // its own row above.
                indexById[group.id] = group.members[0].index
            }
        }
        self.indexById = indexById
        self.rowIdByStableId = rowIdByStableId
        self.spanById = spanById
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

    /// The transcript-index range `rowId` represents on screen: a single
    /// index for a plain message row (or one expanded bundle member), the
    /// full `[first, last]` member range for a COLLAPSED tool-call group.
    /// Lets a fractional position within the row's physical height (minimap
    /// drag, logical scrollbar) scale across however many messages the row
    /// actually stands for, instead of always treating one row as exactly
    /// one message.
    ///
    /// Nil means either an unknown row id or — for an expanded bundle's
    /// header — a row that represents no message at all and must therefore
    /// not advance the logical position as it scrolls past. The two are
    /// told apart by `transcriptIndex(for:)`, which still answers for the
    /// header; see `globalMessagePosition(at:)`.
    func localIndexSpan(forRowId rowId: String) -> ClosedRange<Int>? {
        spanById[rowId]
    }
}
