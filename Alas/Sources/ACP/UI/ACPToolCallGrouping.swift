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

/// What the scroller actually tiles.
///
/// A COLLAPSED bundle is one row standing in for all its members
/// (`toolCallGroup`). An EXPANDED bundle is a header row carrying the
/// "Hide N tools" toggle (`toolCallGroupHeader`) followed by one row per
/// member (`toolCallGroupMember`) — deliberately NOT one tall row with the
/// cards nested inside it.
///
/// Giving each expanded member its own tiled row is what makes the
/// scroller's geometry exact rather than estimated: the member has a real
/// measured frame, its own index span of exactly one message, and a row id
/// (its own stable id) identical to the one it would have if collapsing
/// were switched off entirely. So window compaction can name the member
/// actually under the viewport, and expanding, collapsing or disabling the
/// setting never leaves a scroll anchor pointing at a row id that no longer
/// exists. With the members nested inside a single row instead, none of
/// that information exists and every one of those operations has to guess
/// from a fraction of the bundle's total height.
enum ACPTranscriptRenderRow: Equatable, Identifiable {
    case message(ACPTranscriptVisibleRow)
    case toolCallGroup(ACPTranscriptToolCallGroup)
    case toolCallGroupHeader(ACPTranscriptToolCallGroup)
    case toolCallGroupMember(ACPTranscriptVisibleRow, groupId: String)

    /// The header deliberately shares the collapsed bundle's id: toggling
    /// expansion then updates that one row in place (its token carries the
    /// expanded flag) while the member rows are inserted or removed around
    /// it, so the toggle never invalidates the bundle's own scroll anchor.
    var id: String {
        switch self {
        case .message(let row): row.stableId
        case .toolCallGroup(let group): group.id
        case .toolCallGroupHeader(let group): group.id
        case .toolCallGroupMember(let row, _): row.stableId
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
    /// collapsed bundle. Delegates to the session's own terminal-status
    /// predicate so the two can never drift; `ACPToolCallCard` likewise
    /// deliberately renders unknown statuses.
    static func isFinished(status: String) -> Bool {
        ACPSession.isFinalStatus(status)
    }

    /// Finished ordinary tool calls only. Active calls, context-compaction
    /// cards, subagent rows, file edits, and every other message kind end a
    /// run. A subagent row is excluded even when its child has finished:
    /// folding a whole child transcript into "Ran N tools" would bury it.
    static func isCollapsible(_ message: ACPMessage) -> Bool {
        guard case .toolCall(let toolCall) = message,
              isFinished(status: toolCall.status),
              ACPContextCompaction(toolCall: toolCall) == nil,
              ACPSubagentRowDescriptor(toolCall: toolCall) == nil
        else { return false }
        return true
    }

    /// `isExpanded` decides, per assembled run, whether the bundle is
    /// emitted as one collapsed row or as a header row plus one row per
    /// member. Expansion therefore shapes the ROW LIST itself, not just how
    /// a row draws — that is the whole point of the design (see
    /// `ACPTranscriptRenderRow`). Callers that memoize the result must
    /// include the expansion state in their cache key; `ACPVisibleRowsCache`
    /// does this via `ACPToolCallGroupExpansionSeeds.generation`.
    static func fold(
        rows: [ACPTranscriptVisibleRow],
        messages: [ACPMessage],
        options: Options,
        isExpanded: (ACPTranscriptToolCallGroup) -> Bool = { _ in false }
    ) -> [ACPTranscriptRenderRow] {
        guard options.enabled else { return rows.map(ACPTranscriptRenderRow.message) }

        var result: [ACPTranscriptRenderRow] = []
        result.reserveCapacity(rows.count)
        var run: [ACPTranscriptVisibleRow] = []

        func flushRun() {
            if !run.isEmpty {
                let group = ACPTranscriptToolCallGroup(members: run)
                if isExpanded(group) {
                    result.append(.toolCallGroupHeader(group))
                    for member in group.members {
                        result.append(.toolCallGroupMember(member, groupId: group.id))
                    }
                } else {
                    result.append(.toolCallGroup(group))
                }
            }
            run.removeAll(keepingCapacity: true)
        }

        for row in rows {
            let collapsible = messages.indices.contains(row.index) && isCollapsible(messages[row.index])
            if collapsible {
                // A run that began at or before the fork boundary must not
                // continue past it. Checking "crossed" rather than only
                // "landed exactly on" it matters when the boundary message
                // itself never becomes a row (a `.plan`, or a replayed
                // duplicate deduped away): no row carries that index, so an
                // equality check alone would let inherited and post-fork
                // calls fuse into one bundle.
                if let boundary = options.breakAfterIndex, let first = run.first,
                   first.index <= boundary, row.index > boundary {
                    flushRun()
                }
                // A run only breaks on a stable-name MISMATCH — both sides
                // must actually carry a `name` for this to fire. Adapters
                // that omit it (nil on both sides) keep today's permissive
                // behavior: any consecutive finished calls fold together.
                if let last = run.last,
                   let lastName = toolCallName(for: last, in: messages),
                   let candidateName = toolCallName(for: row, in: messages),
                   lastName != candidateName {
                    flushRun()
                }
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

    private static func toolCallName(for row: ACPTranscriptVisibleRow, in messages: [ACPMessage]) -> String? {
        guard messages.indices.contains(row.index), case .toolCall(let toolCall) = messages[row.index] else {
            return nil
        }
        return toolCall.nonEmptyName
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

    /// Only "failed" can reach a bundle: "error" is not a terminal status
    /// per `ACPToolCallGrouping.isFinished`, so such a call is never a
    /// member in the first place.
    static func isFailed(status: String) -> Bool {
        status == "failed"
    }

    var collapsedLabel: String {
        "Ran \(count) \(count == 1 ? "tool" : "tools")" + failureSuffix
    }

    /// Keeps the failure count visible while open: it's the reason a reader
    /// most likely expanded the bundle in the first place.
    var expandedLabel: String {
        "Hide \(count) \(count == 1 ? "tool" : "tools")" + failureSuffix
    }

    private var failureSuffix: String {
        failedCount > 0 ? " · \(failedCount) failed" : ""
    }
}

/// The single source of truth for which tool-call bundles are expanded,
/// keyed by member stable ids rather than by a bundle's own row id.
///
/// A group's row id is derived from its first member (see
/// `ACPTranscriptToolCallGroup.id`), which stays fixed while a run grows at
/// its tail (the common case: watching a live turn run through more tools)
/// but changes when history backfill reveals an earlier, adjacent finished
/// call that becomes the new first member. Keying by the same message
/// stable ids the scroll anchor already uses keeps the bundle open across
/// that regroup, and means two unrelated bundles that land in the same
/// structural position after a logical-scrollbar jump never inherit each
/// other's state: they share no member ids.
///
/// The row itself holds no expanded state of its own: `toolCallGroupSpec`
/// reads this store, folds the answer into the row's equality token, and
/// the row's toggle writes back here and requests a fresh update (via
/// `onChange`). One owner, so a mounted row and the store can never
/// disagree — which they would if the row cached a copy, since the hosting
/// pool keeps a mounted row's SwiftUI state across in-place content updates
/// while the store can move on independently (a regroup re-tagging
/// members, a collapse elsewhere invalidating a shared lineage).
@MainActor
final class ACPToolCallGroupExpansionSeeds {
    /// Fired after every `setExpanded`, so the owning Coordinator can
    /// rebuild the row list without this store having to know about
    /// SwiftUI or the scroller.
    var onChange: (() -> Void)?

    /// Bumped on every `setExpanded`. Expansion decides whether a bundle
    /// folds into one row or a header plus per-member rows, so anything
    /// memoizing the folded row list has to invalidate when it changes;
    /// a counter is the cheapest key for that (see `ACPVisibleRowsCache`).
    /// `syncLineage` deliberately does NOT bump it: it only re-tags members
    /// of a run that is already expanded, which cannot change the row list.
    private(set) var generation: UInt64 = 0

    /// Every member ever recorded as part of an expanded run, tagged with
    /// that run's lineage. Bare member-id overlap alone can't tell "the
    /// same still-expanded run growing" apart from "a collapsed run
    /// reassembling from members some of which still carry a stale tag
    /// from before the render window trimmed them out" — both look
    /// identical from membership alone, since a member can leave and later
    /// re-enter the window without ever being explicitly collapsed. A
    /// lineage id, freshly minted per expand action and explicitly
    /// invalidated by collapse (see `setExpanded`), disambiguates the two.
    private var lineageByMemberId: [String: UUID] = [:]

    func isExpanded(members: [String]) -> Bool {
        members.contains { lineageByMemberId[$0] != nil }
    }

    func setExpanded(_ expanded: Bool, members: [String]) {
        if expanded {
            // Reuse an existing lineage if any current member already
            // carries one (this run growing while still expanded);
            // otherwise this is a fresh expand action.
            let lineage = members.compactMap { lineageByMemberId[$0] }.first ?? UUID()
            for member in members { lineageByMemberId[member] = lineage }
        } else {
            // Clear every member sharing ANY lineage referenced by the
            // current members — not just the ones passed in — so a
            // collapse from a partially-windowed subset still invalidates
            // members currently outside the window that `syncLineage`
            // previously folded into the same run.
            let lineages = Set(members.compactMap { lineageByMemberId[$0] })
            guard !lineages.isEmpty else { return }
            lineageByMemberId = lineageByMemberId.filter { !lineages.contains($0.value) }
        }
        generation &+= 1
        onChange?()
    }

    /// Whether `group` should render expanded. Convenience over
    /// `isExpanded(members:)` for the fold, which works in whole groups.
    func isExpanded(_ group: ACPTranscriptToolCallGroup) -> Bool {
        isExpanded(members: group.members.map(\.stableId))
    }

    /// Folds `members` into whichever lineage is already present among
    /// them, if any. Called on every render of an expanded group (not only
    /// at expand/collapse time) so a member newly revealed by backfill, or
    /// a member that was never itself passed to `setExpanded`, still gets
    /// tagged — keeping a later collapse correct regardless of which
    /// subset of the run happens to be visible when the user triggers it.
    /// A no-op when none of `members` carries a lineage yet.
    ///
    /// When `members` spans TWO previously separate lineages — two
    /// independently expanded runs joining because the unfinished call that
    /// used to separate them completed — every entry anywhere in the store
    /// still carrying the discarded lineage is rewritten to the surviving
    /// one, not just the currently-visible members. Rewriting only the
    /// visible ones would let a hidden member of the discarded lineage keep
    /// its stale tag; a later collapse of the merged bundle (which only
    /// clears lineages referenced by ITS OWN currently-visible members,
    /// see `setExpanded`) would then miss it, and revealing it again later
    /// would make it look expanded on its own.
    func syncLineage(members: [String]) {
        let lineagesInOrder = members.compactMap { lineageByMemberId[$0] }
        guard let canonical = lineagesInOrder.first else { return }
        let lineages = Set(lineagesInOrder)
        if lineages.count > 1 {
            for (member, lineage) in lineageByMemberId where lineages.contains(lineage) {
                lineageByMemberId[member] = canonical
            }
        }
        for member in members { lineageByMemberId[member] = canonical }
    }
}
