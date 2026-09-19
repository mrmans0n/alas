import Foundation

/// A run of one or more consecutive, already-finished tool-call rows that the
/// transcript renders as one collapsed "Ran N tools" row instead of N cards —
/// including a lone finished call, so every tool call is one click away
/// instead of always taking up a full card.
struct ACPTranscriptToolCallGroup: Equatable {
    static let idPrefix = "tcg-"

    /// In transcript order; never empty.
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

    /// An explicit allowlist, not a blocklist: an adapter-specific status
    /// Alas doesn't yet recognize (e.g. a future "awaiting_permission")
    /// must stay visible rather than being silently folded into a
    /// collapsed bundle. Mirrors `ACPSession.isFinalStatus`'s own allowlist
    /// (private to that file, so duplicated here rather than shared) and
    /// `ACPToolCallCard`'s deliberate choice to render unknown statuses.
    static func isFinished(status: String) -> Bool {
        switch status {
        case "completed", "failed", "canceled", "cancelled": true
        default: false
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
            if !run.isEmpty {
                result.append(.toolCallGroup(ACPTranscriptToolCallGroup(members: run)))
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

/// Persists which tool-call bundles are expanded, keyed by member stable ids
/// rather than by a bundle's own row id.
///
/// A group's row id is derived from its first member (see
/// `ACPTranscriptToolCallGroup.id`), which stays fixed while a run grows at
/// its tail (the common case: watching a live turn run through more tools)
/// but changes when history backfill reveals an earlier, adjacent finished
/// call that becomes the new first member. A changed row id makes the
/// reconciler treat the bundle as a brand-new row, discarding its
/// `@State`-held expanded flag.
///
/// Seeding a freshly (re)mounted row's initial state from this store —
/// keyed by the same message stable ids the scroll anchor already uses —
/// keeps the bundle open across that regroup. Keying by member id rather
/// than by a fixed placeholder row id also means two unrelated bundles that
/// happen to land in the same structural position after a logical-scrollbar
/// jump never inherit each other's expanded state: they share no member ids.
@MainActor
final class ACPToolCallGroupExpansionSeeds {
    private var expandedMemberIds: Set<String> = []

    func isExpanded(members: [String]) -> Bool {
        members.contains { expandedMemberIds.contains($0) }
    }

    func setExpanded(_ expanded: Bool, members: [String]) {
        if expanded {
            expandedMemberIds.formUnion(members)
        } else {
            expandedMemberIds.subtract(members)
        }
    }
}
