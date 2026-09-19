import Foundation

/// A run of two or more consecutive, already-finished tool-call rows that the
/// transcript renders as one collapsed "Ran N tools" row instead of N cards.
struct ACPTranscriptToolCallGroup: Equatable {
    static let idPrefix = "tcg-"

    /// In transcript order; always at least `ACPToolCallGrouping.minimumRunLength`.
    let members: [ACPTranscriptVisibleRow]

    /// Derived from the first member so the id stays stable while the run
    /// grows at its tail: the reconciler then updates the mounted row in
    /// place (keeping its expanded state) instead of rebuilding it.
    var id: String { Self.idPrefix + members[0].stableId }

    /// Inverse of `id`: the first member's stable id, or nil when `rowId` is
    /// not a group id. Scroll anchors are remembered as message stable ids
    /// so they survive the bundle dissolving (setting toggled off, run
    /// split by a new message) — see `rememberCurrentAnchor`.
    static func firstMemberStableId(forGroupId rowId: String) -> String? {
        guard rowId.hasPrefix(idPrefix) else { return nil }
        return String(rowId.dropFirst(idPrefix.count))
    }
}

/// What the scroller actually tiles: either one transcript message or a
/// bundle of finished tool calls folded into a single row.
enum ACPTranscriptRenderRow: Equatable, Identifiable {
    case message(ACPTranscriptVisibleRow)
    case toolCallGroup(ACPTranscriptToolCallGroup)

    var id: String {
        switch self {
        case .message(let row): row.stableId
        case .toolCallGroup(let group): group.id
        }
    }
}

enum ACPToolCallGrouping {
    struct Options: Equatable {
        static let disabled = Options(enabled: false)

        var enabled: Bool
        /// Transcript index after which a run must end, so the fork divider
        /// (which follows the boundary row) never lands inside a bundle.
        var breakAfterIndex: Int? = nil
    }

    /// Runs shorter than this stay as plain cards.
    static let minimumRunLength = 2

    static func isFinished(status: String) -> Bool {
        switch status {
        case "in_progress", "running", "pending": false
        default: true
        }
    }

    /// Finished ordinary tool calls only. Active calls, context-compaction
    /// cards, file edits, and every other message kind end a run.
    static func isCollapsible(_ message: ACPMessage) -> Bool {
        guard case .toolCall(let toolCall) = message,
              isFinished(status: toolCall.status),
              ACPContextCompaction(toolCall: toolCall) == nil
        else { return false }
        return true
    }

    static func fold(
        rows: [ACPTranscriptVisibleRow],
        messages: [ACPMessage],
        options: Options
    ) -> [ACPTranscriptRenderRow] {
        guard options.enabled else { return rows.map(ACPTranscriptRenderRow.message) }

        var result: [ACPTranscriptRenderRow] = []
        result.reserveCapacity(rows.count)
        var run: [ACPTranscriptVisibleRow] = []

        func flushRun() {
            if run.count >= minimumRunLength {
                result.append(.toolCallGroup(ACPTranscriptToolCallGroup(members: run)))
            } else {
                result.append(contentsOf: run.map(ACPTranscriptRenderRow.message))
            }
            run.removeAll(keepingCapacity: true)
        }

        for row in rows {
            let collapsible = messages.indices.contains(row.index) && isCollapsible(messages[row.index])
            if collapsible {
                run.append(row)
                if row.index == options.breakAfterIndex { flushRun() }
            } else {
                flushRun()
                result.append(.message(row))
            }
        }
        flushRun()
        return result
    }
}

/// Header facts for a collapsed tool-call bundle.
struct ACPToolCallGroupSummary: Equatable {
    let count: Int
    let failedCount: Int

    init(toolCalls: [ACPMessage.ToolCall]) {
        count = toolCalls.count
        failedCount = toolCalls.filter { Self.isFailed(status: $0.status) }.count
    }

    static func isFailed(status: String) -> Bool {
        status == "failed" || status == "error"
    }

    var collapsedLabel: String {
        var label = "Ran \(count) \(count == 1 ? "tool" : "tools")"
        if failedCount > 0 { label += " · \(failedCount) failed" }
        return label
    }

    var expandedLabel: String {
        "Hide \(count) \(count == 1 ? "tool" : "tools")"
    }
}
