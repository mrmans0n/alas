import Foundation

/// Consecutive transcript work rendered as one expandable activity row.
/// The original messages remain available in transcript order.
struct ACPTranscriptToolCallGroup: Equatable {
    enum Kind: Equatable {
        case activity
        case completedTurn(duration: TimeInterval?)
    }

    static let idPrefix = "tcg-"

    /// How many trailing members an automatically expanded live group
    /// shows. The rest stay one click away, so a long turn doesn't grow the
    /// open run past the viewport.
    static let liveMemberLimit = 5

    /// In transcript order; never empty.
    let members: [ACPTranscriptVisibleRow]
    let kind: Kind
    /// The trailing run of a turn that is still running. Drives the
    /// "Exploring…/Running…" label and automatic expansion.
    let isLive: Bool

    init(
        members: [ACPTranscriptVisibleRow],
        kind: Kind = .activity,
        isLive: Bool = false
    ) {
        self.members = members
        self.kind = kind
        self.isLive = isLive
    }

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
/// disclosure toggle (`toolCallGroupHeader`) followed by one row per
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
        /// The final answer for the current (last) user turn once the session
        /// is idle. Nil while that turn is still live or blocked.
        var currentTurnAnswerIndex: Int? = nil
        /// Commentary rows before the newest agent update in the current turn.
        /// Carried in the cache key so late phase adoption can regroup them.
        var priorCurrentTurnCommentaryIndices: Set<Int> = []
        /// Whether the latest turn is still running; only then can a group be live.
        var isTurnActive: Bool = false
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

    /// The current turn's answer once it is safe to convert prior activity
    /// into a completed-work disclosure. Commentary is never an answer, and
    /// an active session keeps even final-answer prose in its streaming form.
    @MainActor
    static func currentTurnAnswerIndex(
        messages: [ACPMessage],
        currentTurnUserIndex: Int?,
        isTurnActive: Bool
    ) -> Int? {
        guard !isTurnActive,
              let currentTurnUserIndex,
              messages.indices.contains(currentTurnUserIndex),
              case .user = messages[currentTurnUserIndex],
              let candidate = (messages.index(after: currentTurnUserIndex)..<messages.endIndex)
              .reversed().first(where: { index in
                  if case .agent = messages[index] { return true }
                  return false
              }),
              case .agent(_, _, let buffer) = messages[candidate],
              buffer.phase != .commentary
        else { return nil }
        return candidate
    }

    /// Commentary updates superseded by a newer agent row in the current
    /// turn. Ordinary unphased/final-answer prose is never hidden here.
    @MainActor
    static func priorCurrentTurnCommentaryIndices(
        messages: [ACPMessage],
        currentTurnUserIndex: Int?,
        visibleRange: Range<Int>
    ) -> Set<Int> {
        guard let currentTurnUserIndex,
              messages.indices.contains(currentTurnUserIndex),
              let latestAgent = (messages.index(after: currentTurnUserIndex)..<messages.endIndex)
              .reversed().first(where: { index in
                  if case .agent = messages[index] { return true }
                  return false
              })
        else { return [] }
        let lower = max(currentTurnUserIndex + 1, visibleRange.lowerBound)
        let upper = min(messages.endIndex, visibleRange.upperBound, latestAgent)
        guard lower < upper else { return [] }

        return Set((lower..<upper).filter { index in
            guard case .agent(_, _, let buffer) = messages[index] else { return false }
            return buffer.phase == .commentary
        })
    }

    /// Whether a lone member of an `.activity` run reads better as a bare
    /// line than as a one-member disclosure. Tool calls and thoughts both
    /// already carry their own verb/label in their own row, so wrapping
    /// either alone in a group just hides one line behind a click — and for
    /// a thought specifically, an auto-expanded live group would otherwise
    /// show "Thinking" twice (the header, then the thought's own label).
    private static func isBareRowEligible(_ message: ACPMessage) -> Bool {
        switch message {
        case .toolCall, .thought: true
        default: false
        }
    }

    /// Thinking and ordinary tool calls — finished, running, or pending —
    /// share an activity group. Unknown statuses (e.g. a call awaiting
    /// permission), context compaction, subagents, file edits, and readable
    /// messages end the run so they remain visible outside the disclosure.
    static func isCollapsible(_ message: ACPMessage) -> Bool {
        if case .thought = message { return true }
        guard case .toolCall(let toolCall) = message,
              isFinished(status: toolCall.status)
                || toolCall.status == "in_progress" || toolCall.status == "pending",
              ACPContextCompaction(toolCall: toolCall) == nil,
              ACPSubagentRowDescriptor(toolCall: toolCall) == nil,
              ACPBackgroundTask(toolCall: toolCall) == nil
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
    @MainActor
    static func fold(
        rows: [ACPTranscriptVisibleRow],
        messages: [ACPMessage],
        options: Options,
        messageCreatedAt: (Int) -> Date? = { _ in nil },
        isExpanded: (ACPTranscriptToolCallGroup) -> Bool = { _ in false },
        memberLimit: (ACPTranscriptToolCallGroup) -> Int? = { _ in nil }
    ) -> [ACPTranscriptRenderRow] {
        guard options.enabled else { return rows.map(ACPTranscriptRenderRow.message) }

        let completedTurnKinds = completedTurnKinds(
            for: rows,
            in: messages,
            currentTurnAnswerIndex: options.currentTurnAnswerIndex,
            breakAfterIndex: options.breakAfterIndex,
            messageCreatedAt: messageCreatedAt
        )
        // The last row only makes a live group when nothing readable follows
        // it (plans never become rows, so they don't count).
        let liveTailIndex: Int? = {
            guard options.isTurnActive, let last = rows.last,
                  messages.indices.contains(last.index),
                  messages[(last.index + 1)...].allSatisfy({
                      if case .plan = $0 { return true }
                      return false
                  })
            else { return nil }
            return last.index
        }()
        var result: [ACPTranscriptRenderRow] = []
        result.reserveCapacity(rows.count)
        var run: [ACPTranscriptVisibleRow] = []
        var runKind: ACPTranscriptToolCallGroup.Kind?

        func flushRun() {
            if !run.isEmpty {
                let kind = runKind ?? .activity
                if kind == .activity, run.count == 1,
                   messages.indices.contains(run[0].index),
                   isBareRowEligible(messages[run[0].index]) {
                    // A lone call or thought reads better as its own
                    // one-line row than as a disclosure hiding a single line.
                    result.append(.message(run[0]))
                } else {
                    let group = ACPTranscriptToolCallGroup(
                        members: run,
                        kind: kind,
                        isLive: kind == .activity && run[run.count - 1].index == liveTailIndex
                    )
                    if isExpanded(group) {
                        result.append(.toolCallGroupHeader(group))
                        for member in group.members.suffix(memberLimit(group) ?? group.members.count) {
                            result.append(.toolCallGroupMember(member, groupId: group.id))
                        }
                    } else {
                        result.append(.toolCallGroup(group))
                    }
                }
            }
            run.removeAll(keepingCapacity: true)
            runKind = nil
        }

        for row in rows {
            let kind = completedTurnKinds[row.index]
                ?? (options.priorCurrentTurnCommentaryIndices.contains(row.index)
                    || (messages.indices.contains(row.index) && isCollapsible(messages[row.index]))
                    ? .activity : nil)
            let collapsible = messages.indices.contains(row.index)
                && kind != nil
            if collapsible {
                if !run.isEmpty, runKind != kind { flushRun() }
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
                runKind = kind
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

    /// Work belonging to historical turns. A following user message is the
    /// durable completion boundary available both live and after transcript
    /// restoration; the turn's last agent row remains readable as its answer.
    @MainActor
    private static func completedTurnKinds(
        for rows: [ACPTranscriptVisibleRow],
        in messages: [ACPMessage],
        currentTurnAnswerIndex: Int?,
        breakAfterIndex: Int?,
        messageCreatedAt: (Int) -> Date?
    ) -> [Int: ACPTranscriptToolCallGroup.Kind] {
        guard let firstVisible = rows.first?.index,
              let lastVisible = rows.last?.index,
              messages.indices.contains(firstVisible),
              messages.indices.contains(lastVisible)
        else { return [:] }

        let precedingUser = (messages.startIndex...firstVisible).reversed().first(where: {
            if case .user = messages[$0] { return true }
            return false
        })
        let firstVisibleUser = (firstVisible...lastVisible).first(where: {
            if case .user = messages[$0] { return true }
            return false
        })
        guard let firstUser = precedingUser ?? firstVisibleUser else { return [:] }

        let afterVisible = messages.index(after: lastVisible)
        let nextUser = (afterVisible..<messages.endIndex).first(where: { index in
            if case .user = messages[index] { return true }
            return false
        })
        let scanEnd = nextUser.map { messages.index(after: $0) } ?? messages.endIndex
        let userIndices = (firstUser..<scanEnd).filter {
            if case .user = messages[$0] { return true }
            return false
        }
        var result: [Int: ACPTranscriptToolCallGroup.Kind] = [:]

        /// Position of the first row whose message index is past `index`.
        func firstRow(after index: Int) -> Int {
            var low = rows.startIndex, high = rows.endIndex
            while low < high {
                let mid = (low + high) / 2
                if rows[mid].index > index { high = mid } else { low = mid + 1 }
            }
            return low
        }

        func record(user: Int, answer: Int) {
            guard user < answer, messages.indices.contains(answer) else { return }
            // Rows are in message order: look only at this turn's slice, so
            // recording every turn stays linear in the window.
            let lower = firstRow(after: user), upper = firstRow(after: answer - 1)
            guard lower < upper else { return }
            let memberIndices = rows[lower..<upper].map(\.index).filter { isCompletedTurnWork(messages[$0]) }
            guard !memberIndices.isEmpty else { return }
            // A turn can contain several runs separated by readable prose or
            // the fork divider. Show its total duration on the last run only.
            guard var lastRunStart = (user + 1..<answer).last(where: {
                isCompletedTurnWork(messages[$0])
            }) else { return }
            while lastRunStart > user + 1 {
                let previous = lastRunStart - 1
                if previous == breakAfterIndex { break }
                if case .plan = messages[previous] {
                    lastRunStart = previous
                } else if isCompletedTurnWork(messages[previous]) {
                    lastRunStart = previous
                } else {
                    break
                }
            }
            let start = messageCreatedAt(user)
            let end = messageCreatedAt(answer)
            let duration: TimeInterval? = if let start, let end {
                max(0, end.timeIntervalSince(start))
            } else {
                nil
            }
            let kind = ACPTranscriptToolCallGroup.Kind.completedTurn(duration: duration)
            for index in memberIndices {
                result[index] = index >= lastRunStart ? kind : .activity
            }
        }

        for pair in zip(userIndices, userIndices.dropFirst()) {
            let turnStart = pair.0 + 1
            let nextUser = pair.1
            guard turnStart < nextUser,
                  let answer = (turnStart..<nextUser).last(where: {
                      if case .agent = messages[$0] { return true }
                      return false
                  }),
                  turnStart < answer
            else { continue }
            record(user: pair.0, answer: answer)
        }
        if let latestUser = userIndices.last,
           let currentTurnAnswerIndex,
           currentTurnAnswerIndex > latestUser {
            record(user: latestUser, answer: currentTurnAnswerIndex)
        }
        return result
    }

    @MainActor
    private static func isCompletedTurnWork(_ message: ACPMessage) -> Bool {
        if isCollapsible(message) { return true }
        guard case .agent(_, _, let buffer) = message else { return false }
        return buffer.phase == .commentary
    }
}

/// Header facts for an activity or completed-work bundle.
struct ACPToolCallGroupSummary: Equatable {
    enum Verb: Equatable {
        case read, search, run, edit, other
    }

    struct VerbCount: Equatable {
        let verb: Verb
        var count: Int
    }

    let count: Int
    let failedCount: Int
    /// Members still running or waiting when this group is not itself the
    /// live tail (e.g. a parallel call that outlives the narration that
    /// followed it out of the group). The live-tail case already says so
    /// via `isLive`; this covers the rest.
    let runningCount: Int
    let kind: ACPTranscriptToolCallGroup.Kind
    let isLive: Bool
    /// In first-appearance order.
    let verbCounts: [VerbCount]

    init(
        toolCalls: [ACPMessage.ToolCall],
        kind: ACPTranscriptToolCallGroup.Kind = .activity,
        isLive: Bool = false
    ) {
        count = toolCalls.count
        failedCount = toolCalls.filter { Self.isFailed(status: $0.status) }.count
        runningCount = toolCalls.filter { $0.status == "in_progress" || $0.status == "pending" }.count
        self.kind = kind
        self.isLive = isLive
        var counts: [VerbCount] = []
        for toolCall in toolCalls {
            let verb = Self.verb(for: ACPToolCallPresentation.resolve(toolCall))
            if let index = counts.firstIndex(where: { $0.verb == verb }) {
                counts[index].count += 1
            } else {
                counts.append(VerbCount(verb: verb, count: 1))
            }
        }
        verbCounts = counts
    }

    /// Only "failed" can reach a bundle: "error" is not a terminal status
    /// per `ACPToolCallGrouping.isFinished`, so such a call is never a
    /// member in the first place.
    static func isFailed(status: String) -> Bool {
        status == "failed"
    }

    static func verb(for presentation: ACPToolCallPresentation) -> Verb {
        switch presentation.label {
        case "Read", "Viewed Image": .read
        case "Searched", "Find", "Web Search", "Opened Page": .search
        case "Ran": .run
        case "Edit": .edit
        default: .other
        }
    }

    /// Same text collapsed or expanded; the chevron carries the state.
    var label: String {
        let failure = failedCount > 0 ? " · \(failedCount) failed" : ""
        if isLive, count > 0 {
            return (isExploring ? "Exploring" : "Running") + " · \(count) so far" + failure
        }
        let counts = verbCounts.map(Self.phrase).joined(separator: ", ")
        let running = runningCount > 0 ? " · \(runningCount) running" : ""
        switch kind {
        case .activity:
            guard !counts.isEmpty else { return isLive ? "Thinking" : "Thought" }
            return counts.prefix(1).uppercased() + String(counts.dropFirst()) + running + failure
        case .completedTurn(let duration):
            return completedLabel(duration: duration) + (counts.isEmpty ? "" : " · " + counts) + running + failure
        }
    }

    var iconSystemName: String {
        if case .completedTurn = kind { return "clock" }
        guard count > 0 else { return "brain" }
        let exploring = verbCounts
            .filter { $0.verb == .read || $0.verb == .search }
            .reduce(0) { $0 + $1.count }
        return exploring * 2 >= count ? "magnifyingglass" : "terminal"
    }

    private var isExploring: Bool {
        verbCounts.allSatisfy { $0.verb == .read || $0.verb == .search }
    }

    private static func phrase(_ entry: VerbCount) -> String {
        let n = entry.count
        return switch entry.verb {
        case .read: "read \(n) \(n == 1 ? "file" : "files")"
        case .search: "searched \(n) \(n == 1 ? "time" : "times")"
        case .run: "ran \(n) \(n == 1 ? "command" : "commands")"
        case .edit: "edited \(n) \(n == 1 ? "file" : "files")"
        case .other: "used \(n) \(n == 1 ? "tool" : "tools")"
        }
    }

    private func completedLabel(duration: TimeInterval?) -> String {
        guard let duration else { return "Worked" }
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 { return "Worked for \(seconds)s" }
        if seconds < 3_600 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "Worked for \(minutes)m" : "Worked for \(minutes)m \(remainder)s"
        }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        return minutes == 0 ? "Worked for \(hours)h" : "Worked for \(hours)h \(minutes)m"
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

    /// Members of runs the user explicitly collapsed. Needed because a live
    /// run is expanded automatically; without this, collapsing it would be
    /// undone by the next render.
    private var collapsedMemberIds: Set<String> = []

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
            collapsedMemberIds.subtract(members)
        } else {
            // Clear every member sharing ANY lineage referenced by the
            // current members — not just the ones passed in — so a
            // collapse from a partially-windowed subset still invalidates
            // members currently outside the window that `syncLineage`
            // previously folded into the same run.
            let lineages = Set(members.compactMap { lineageByMemberId[$0] })
            if !lineages.isEmpty {
                lineageByMemberId = lineageByMemberId.filter { !lineages.contains($0.value) }
            }
            collapsedMemberIds.formUnion(members)
        }
        generation &+= 1
        onChange?()
    }

    /// Whether `group` should render expanded: the user's explicit choice
    /// when there is one, otherwise open only while it is the live tail.
    func isExpanded(_ group: ACPTranscriptToolCallGroup) -> Bool {
        let members = group.members.map(\.stableId)
        if isExpanded(members: members) { return true }
        if members.contains(where: collapsedMemberIds.contains) { return false }
        return group.isLive
    }

    /// Trailing members to tile for an expanded `group`, or nil for all.
    /// Only an automatically expanded live group is capped; expanding it
    /// explicitly (the header's "Show earlier") shows the whole run.
    func memberLimit(_ group: ACPTranscriptToolCallGroup) -> Int? {
        guard group.isLive, !isExpanded(members: group.members.map(\.stableId)) else { return nil }
        return ACPTranscriptToolCallGroup.liveMemberLimit
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

    /// Folds `members` into the collapsed override when any of them already
    /// carry it. Mirrors `syncLineage`'s handling of expansion: called on
    /// every render (not only at collapse time), so a live group that keeps
    /// growing at the tail stays collapsed even after the render window
    /// trims out the members the user originally collapsed — otherwise,
    /// once none of a group's currently-visible members are in
    /// `collapsedMemberIds`, `isExpanded(_:)` falls through to `isLive` and
    /// the group silently re-expands. A no-op when none of `members` is
    /// currently collapsed.
    func syncCollapsed(members: [String]) {
        guard members.contains(where: collapsedMemberIds.contains) else { return }
        collapsedMemberIds.formUnion(members)
    }
}
