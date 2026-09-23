import Foundation
import Testing
@testable import Alas

@Suite("ACP tool-call grouping")
struct ACPToolCallGroupingTests {
    private func tool(_ id: String, status: String = "completed", name: String? = nil) -> ACPMessage {
        .toolCall(.init(toolCallId: id, title: "Read \(id)", kind: "read", status: status, name: name))
    }

    private func compaction(_ id: String) -> ACPMessage {
        .toolCall(.init(
            toolCallId: id, title: "Compacting context", kind: "context_compaction",
            status: "completed",
            metadata: AnyCodable(["contextCompaction": ["version": 1]])
        ))
    }

    private func fold(
        _ messages: [ACPMessage],
        enabled: Bool = true,
        breakAfterIndex: Int? = nil,
        expandAll: Bool = false
    ) -> [ACPTranscriptRenderRow] {
        let rows = ACPTranscriptVisibleRow.rows(
            messages: messages, visibleHead: 0, visibleTail: messages.count,
            stableId: { $0.stableId }
        )
        return ACPToolCallGrouping.fold(
            rows: rows, messages: messages,
            options: .init(enabled: enabled, breakAfterIndex: breakAfterIndex),
            isExpanded: { _ in expandAll }
        )
    }

    private func ids(_ rows: [ACPTranscriptRenderRow]) -> [String] { rows.map(\.id) }

    @Test("disabled grouping keeps every row as a plain message row")
    func disabledKeepsMessageRows() {
        let messages = [tool("a"), tool("b"), tool("c")]
        let folded = fold(messages, enabled: false)
        #expect(ids(folded) == ["tc-a", "tc-b", "tc-c"])
        #expect(folded.allSatisfy { if case .message = $0 { true } else { false } })
    }

    @Test("consecutive finished tool calls fold into one group")
    func consecutiveFinishedToolsFold() throws {
        let folded = fold([tool("a"), tool("b"), tool("c", status: "failed")])
        #expect(ids(folded) == ["tcg-tc-a"])
        guard case .toolCallGroup(let group) = try #require(folded.first) else {
            Issue.record("expected a tool-call group")
            return
        }
        #expect(group.members.map(\.stableId) == ["tc-a", "tc-b", "tc-c"])
        #expect(group.members.map(\.index) == [0, 1, 2])
    }

    @Test("consecutive tool calls sharing the same name still fold, even when retitled")
    func sameNameFoldsDespiteDifferentTitles() throws {
        let folded = fold([tool("a", name: "Bash"), tool("b", name: "Bash"), tool("c", name: "Bash")])
        #expect(ids(folded) == ["tcg-tc-a"])
        guard case .toolCallGroup(let group) = try #require(folded.first) else {
            Issue.record("expected a tool-call group")
            return
        }
        #expect(group.members.map(\.stableId) == ["tc-a", "tc-b", "tc-c"])
    }

    @Test("consecutive tool calls with different names share one activity group")
    func differentNamesShareTheRun() {
        let folded = fold([tool("a", name: "Bash"), tool("b", name: "Read"), tool("c", name: "Bash")])
        #expect(ids(folded) == ["tcg-tc-a"])
    }

    @Test("a nil name on either side never breaks the run, matching adapters that omit name")
    func missingNameNeverBreaksTheRun() {
        // One side (or both) lacking a name must behave exactly like today:
        // any consecutive finished calls fold, regardless of identity.
        let folded = fold([tool("a", name: "Bash"), tool("b"), tool("c", name: "Read")])
        #expect(ids(folded) == ["tcg-tc-a"])
    }

    @Test("a single finished tool call still folds into a one-member group")
    func singleFinishedToolFolds() throws {
        let before = ACPMessage.user(id: UUID(), messageId: "u1", text: "hi", attachments: [])
        let after = ACPMessage.user(id: UUID(), messageId: "u2", text: "thanks", attachments: [])
        let folded = fold([before, tool("a"), after])
        #expect(ids(folded) == ["acp-user:u1", "tcg-tc-a", "acp-user:u2"])
        guard case .toolCallGroup(let group) = try #require(folded.dropFirst().first) else {
            Issue.record("expected a tool-call group")
            return
        }
        #expect(group.members.map(\.stableId) == ["tc-a"])
    }

    @Test("an active tool call ends the run and stays visible after the group")
    func activeToolEndsRun() {
        let folded = fold([tool("a"), tool("b"), tool("c", status: "in_progress")])
        #expect(ids(folded) == ["tcg-tc-a", "tc-c"])
    }

    @Test("a pending tool call is treated as active")
    func pendingToolIsActive() {
        let folded = fold([tool("a"), tool("b"), tool("c", status: "pending"), tool("d")])
        #expect(ids(folded) == ["tcg-tc-a", "tc-c", "tcg-tc-d"])
    }

    @Test("agent text between tool calls splits the run")
    @MainActor
    func agentTextSplitsRun() {
        let agent = ACPMessage.agent(id: UUID(), messageId: "m1", StreamingText("text"))
        let folded = fold([tool("a"), tool("b"), agent, tool("c"), tool("d")])
        #expect(ids(folded) == ["tcg-tc-a", "acp-agent:m1", "tcg-tc-c"])
    }

    @Test("thinking between tool calls stays in the same activity group")
    @MainActor
    func thoughtSharesRun() {
        let thought = ACPMessage.thought(id: UUID(), messageId: "t1", StreamingText("hmm"))
        let folded = fold([tool("a"), tool("b"), thought, tool("c"), tool("d")])
        #expect(ids(folded) == ["tcg-tc-a"])
    }

    @Test("expanding mixed activity restores thinking and tools in their original order")
    @MainActor
    func expandedMixedActivityPreservesOrder() {
        let thought = ACPMessage.thought(id: UUID(), messageId: "t1", StreamingText("hmm"))
        let messages = [thought, tool("a", name: "Read"), tool("b", name: "Bash")]
        #expect(ids(fold(messages, expandAll: true)) == [
            "tcg-acp-thought:t1", "acp-thought:t1", "tc-a", "tc-b",
        ])
        #expect(ids(fold(messages, enabled: false)) == ["acp-thought:t1", "tc-a", "tc-b"])
    }

    @Test("thinking groups respect fork boundaries and visible progress messages")
    @MainActor
    func mixedActivityBoundaries() {
        let thought = ACPMessage.thought(id: UUID(), messageId: "t1", StreamingText("hmm"))
        let progress = ACPMessage.agent(id: UUID(), messageId: "p1", StreamingText("Tests pass"))
        #expect(ids(fold([thought, tool("a"), progress, tool("b")])) == [
            "tcg-acp-thought:t1", "acp-agent:p1", "tcg-tc-b",
        ])
        #expect(ids(fold([tool("a"), thought, tool("b")], breakAfterIndex: 1)) == [
            "tcg-tc-a", "tcg-tc-b",
        ])
    }

    @Test("consecutive thoughts occupy one expandable row")
    @MainActor
    func consecutiveThoughtsFold() {
        let messages = [
            ACPMessage.thought(id: UUID(), messageId: "t1", StreamingText("first")),
            ACPMessage.thought(id: UUID(), messageId: "t2", StreamingText("second")),
        ]
        #expect(ids(fold(messages)) == ["tcg-acp-thought:t1"])
        #expect(ids(fold(messages, expandAll: true)) == [
            "tcg-acp-thought:t1", "acp-thought:t1", "acp-thought:t2",
        ])
    }

    @Test("a file edit card stays outside the bundle and splits the run")
    func fileEditSplitsRun() {
        let editId = UUID()
        let edit = ACPMessage.fileEdit(id: editId, .init(path: "a.swift", added: 1, removed: 0))
        let folded = fold([tool("a"), tool("b"), edit, tool("c"), tool("d")])
        #expect(ids(folded) == ["tcg-tc-a", editId.uuidString, "tcg-tc-c"])
    }

    @Test("a context compaction card is never bundled")
    func compactionIsNeverBundled() {
        let folded = fold([tool("a"), tool("b"), compaction("cc"), tool("c"), tool("d")])
        #expect(ids(folded) == ["tcg-tc-a", "tc-cc", "tcg-tc-c"])
    }

    @Test("hidden plan messages do not split a run")
    func hiddenPlanDoesNotSplitRun() {
        let plan = ACPMessage.plan(id: UUID(), [.init(content: "x", status: "pending")])
        let folded = fold([tool("a"), plan, tool("b")])
        #expect(ids(folded) == ["tcg-tc-a"])
    }

    @Test("the run breaks after the fork boundary index")
    func breakAfterIndexSplitsRun() {
        let folded = fold([tool("a"), tool("b"), tool("c"), tool("d")], breakAfterIndex: 1)
        #expect(ids(folded) == ["tcg-tc-a", "tcg-tc-c"])
    }

    @Test("the run still breaks at the fork boundary when the boundary message has no row")
    func breakAfterIndexSplitsRunAcrossRowlessBoundary() {
        // The boundary message is a `.plan`, which never becomes a row: no
        // row's index equals `breakAfterIndex`, so only a "crossed the
        // boundary" check keeps inherited and post-fork calls apart.
        let plan = ACPMessage.plan(id: UUID(), [.init(content: "x", status: "pending")])
        let folded = fold([tool("a"), plan, tool("c"), tool("d")], breakAfterIndex: 1)
        #expect(ids(folded) == ["tcg-tc-a", "tcg-tc-c"])
    }

    @Test("a run that starts after the fork boundary is not split by it")
    func runStartingPastBoundaryIsNotSplit() {
        let user = ACPMessage.user(id: UUID(), messageId: "u1", text: "hi", attachments: [])
        let folded = fold([user, tool("b"), tool("c"), tool("d")], breakAfterIndex: 0)
        #expect(ids(folded) == ["acp-user:u1", "tcg-tc-b"])
    }

    @Test("an expanded run folds into a header row plus one row per member")
    func expandedRunEmitsHeaderAndMemberRows() {
        let folded = fold([tool("a"), tool("b"), tool("c")], expandAll: true)
        #expect(ids(folded) == ["tcg-tc-a", "tc-a", "tc-b", "tc-c"])
        guard case .toolCallGroupHeader = folded[0] else {
            Issue.record("expected a header row first")
            return
        }
        for row in folded.dropFirst() {
            guard case .toolCallGroupMember(_, let groupId) = row else {
                Issue.record("expected a member row, got \(row)")
                return
            }
            #expect(groupId == "tcg-tc-a")
        }
    }

    @Test("an expanded member's row id is the same one it has when collapsing is off entirely")
    func expandedMemberRowIdMatchesUngroupedRowId() {
        // This is the property the scroller relies on: expanding, collapsing
        // or switching the setting off never changes a member's row id, so a
        // scroll anchor on that card can never go stale.
        let messages = [tool("a"), tool("b"), tool("c")]
        let ungrouped = ids(fold(messages, enabled: false))
        let expandedMembers = ids(fold(messages, expandAll: true)).filter { $0 != "tcg-tc-a" }
        #expect(expandedMembers == ungrouped)
    }

    @Test("the header row keeps the collapsed bundle's id, so toggling updates it in place")
    func headerKeepsCollapsedRowId() {
        let messages = [tool("a"), tool("b")]
        #expect(ids(fold(messages)).first == "tcg-tc-a")
        #expect(ids(fold(messages, expandAll: true)).first == "tcg-tc-a")
    }

    @Test("the group id stays stable while the run grows at the tail")
    func groupIdStableAsRunGrows() {
        let before = fold([tool("a"), tool("b")])
        let after = fold([tool("a"), tool("b"), tool("c")])
        #expect(ids(before) == ids(after))
    }

    @Test("finished status excludes in-progress, running, and pending")
    func finishedStatus() {
        #expect(ACPToolCallGrouping.isFinished(status: "completed"))
        #expect(ACPToolCallGrouping.isFinished(status: "failed"))
        #expect(ACPToolCallGrouping.isFinished(status: "canceled"))
        #expect(ACPToolCallGrouping.isFinished(status: "cancelled"))
        #expect(!ACPToolCallGrouping.isFinished(status: "in_progress"))
        #expect(!ACPToolCallGrouping.isFinished(status: "running"))
        #expect(!ACPToolCallGrouping.isFinished(status: "pending"))
    }

    @Test("an unrecognized status is treated as unfinished, not folded away")
    func unrecognizedStatusIsUnfinished() {
        // Matches ACPSession's own final-status allowlist: an adapter-
        // specific status Alas doesn't yet recognize (e.g. a future
        // "awaiting_permission") must stay visible rather than being
        // silently hidden inside a collapsed bundle.
        #expect(!ACPToolCallGrouping.isFinished(status: "awaiting_permission"))
        #expect(!ACPToolCallGrouping.isFinished(status: "some_future_status"))
    }
}

@Suite("ACP tool-call group summary")
struct ACPToolCallGroupSummaryTests {
    private func tool(_ id: String, status: String = "completed") -> ACPMessage.ToolCall {
        .init(toolCallId: id, title: id, kind: "read", status: status)
    }

    @Test("counts members and failures")
    func countsMembersAndFailures() {
        let summary = ACPToolCallGroupSummary(toolCalls: [
            tool("a"), tool("b", status: "failed"), tool("c", status: "canceled"),
        ])
        #expect(summary.count == 3)
        #expect(summary.failedCount == 1)
    }

    @Test("only the terminal 'failed' status counts as a failure")
    func failedPredicateMatchesGroupingAllowlist() {
        // "error" is not a terminal status per `ACPToolCallGrouping.isFinished`,
        // so a call carrying it can never be a bundle member; counting it
        // here would be dead code that suggests otherwise.
        #expect(ACPToolCallGroupSummary.isFailed(status: "failed"))
        #expect(!ACPToolCallGroupSummary.isFailed(status: "error"))
        #expect(!ACPToolCallGroupSummary.isFailed(status: "canceled"))
        #expect(!ACPToolCallGroupSummary.isFailed(status: "completed"))
    }

    @Test("collapsed label pluralizes and appends the failure count")
    func collapsedLabel() {
        #expect(ACPToolCallGroupSummary(toolCalls: []).collapsedLabel == "Activity")
        #expect(ACPToolCallGroupSummary(toolCalls: [tool("a"), tool("b")]).collapsedLabel == "Activity · 2 tool calls")
        #expect(ACPToolCallGroupSummary(toolCalls: [tool("a")]).collapsedLabel == "Activity · 1 tool call")
        #expect(ACPToolCallGroupSummary(toolCalls: [
            tool("a"), tool("b", status: "failed"), tool("c"),
        ]).collapsedLabel == "Activity · 3 tool calls · 1 failed")
    }

    @Test("expanded label offers to hide the bundle and keeps the failure count")
    func expandedLabel() {
        #expect(ACPToolCallGroupSummary(toolCalls: []).expandedLabel == "Hide activity")
        #expect(ACPToolCallGroupSummary(toolCalls: [tool("a"), tool("b"), tool("c")]).expandedLabel == "Hide activity · 3 tool calls")
        #expect(ACPToolCallGroupSummary(toolCalls: [tool("a")]).expandedLabel == "Hide activity · 1 tool call")
        #expect(ACPToolCallGroupSummary(toolCalls: [
            tool("a"), tool("b", status: "failed"), tool("c"),
        ]).expandedLabel == "Hide activity · 3 tool calls · 1 failed")
    }
}

@MainActor
@Suite("ACP visible row lookup with groups")
struct ACPTranscriptVisibleRowLookupGroupTests {
    private let rows: [ACPTranscriptRenderRow] = [
        .message(ACPTranscriptVisibleRow(index: 0, stableId: "u")),
        .toolCallGroup(ACPTranscriptToolCallGroup(members: [
            ACPTranscriptVisibleRow(index: 1, stableId: "tc-a"),
            ACPTranscriptVisibleRow(index: 3, stableId: "tc-b"),
        ])),
        .message(ACPTranscriptVisibleRow(index: 4, stableId: "tc-c")),
    ]

    @Test("a group id resolves to its first member's transcript index")
    func groupIdResolvesToFirstMember() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.transcriptIndex(for: "tcg-tc-a") == 1)
    }

    @Test("member stable ids still resolve to their own transcript index")
    func memberIdsResolve() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.transcriptIndex(for: "tc-b") == 3)
        #expect(lookup.transcriptIndex(for: "tc-c") == 4)
        #expect(lookup.transcriptIndex(for: "missing") == nil)
    }

    @Test("a stale plain id absorbed as the collapsed group's last member does not assume head growth")
    func staleResolutionForBundledPlainIdAsLastMember() {
        // "tc-b" just finished at the live tail and folded into the bundle
        // above it as its newest member. Its row is gone; the bundle's row
        // is the same one-line "Ran N tools" header it was before, because a
        // COLLAPSED bundle's height never depends on how many calls it
        // holds. (An expanded bundle never gets here at all: its members
        // keep their own row ids.)
        //
        // Head growth means "the replacement row grew at its top to contain
        // my content, so measure from its bottom". Nothing here grew. Bottom-
        // relative restoration with the OLD card's height, clamped to the
        // NEW header's height, pins the viewport to within one line of the
        // header's bottom — i.e. jumps the reader up to wherever the bundle
        // began, which for a long run of tools is far above the tail. That
        // was the reported "transcript scrolls up when a tool call
        // collapses" bug. Tops must be aligned, exactly like any other row
        // that shrank in place.
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        let resolution = ACPTranscriptScroller.Coordinator.resolveStaleRowId(
            "tc-b", lookup: lookup, groupingEnabled: true
        )
        #expect(resolution?.rowId == "tcg-tc-a")
        #expect(resolution?.assumeHeadGrowth == false)
    }

    @Test("a stale plain id bundled as the group's first member does not assume head growth")
    func staleResolutionForBundledPlainIdAsFirstMember() {
        // Turning the setting on while parked on the first of a run of
        // finished calls: the bundle grew BELOW the anchored card, so
        // bottom-relative restoration would drag the viewport down by the
        // height of every later member. Top-relative is right here.
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        let resolution = ACPTranscriptScroller.Coordinator.resolveStaleRowId(
            "tc-a", lookup: lookup, groupingEnabled: true
        )
        #expect(resolution?.rowId == "tcg-tc-a")
        #expect(resolution?.assumeHeadGrowth == false)
    }

    @Test("a stale group id whose first member changed resolves via its old first member")
    func staleResolutionForRenamedGroupId() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        let resolution = ACPTranscriptScroller.Coordinator.resolveStaleRowId(
            "tcg-tc-a", lookup: lookup, groupingEnabled: true
        )
        #expect(resolution?.rowId == "tcg-tc-a")
        #expect(resolution?.assumeHeadGrowth == true)
    }

    @Test("a stale group id resolved while grouping is now disabled is not assumed to be head growth")
    func staleResolutionForDissolvedGroup() {
        // The user turned "Collapse finished tool calls" off while
        // scrolled inside an expanded bundle: the group id disappears
        // because grouping stopped entirely, not because content was
        // prepended at its head — a short collapsed group can become a
        // much taller plain tool card, so restoration must not assume the
        // new row grew at the top.
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        let resolution = ACPTranscriptScroller.Coordinator.resolveStaleRowId(
            "tcg-tc-a", lookup: lookup, groupingEnabled: false
        )
        #expect(resolution?.rowId == "tcg-tc-a")
        #expect(resolution?.assumeHeadGrowth == false)
    }

    @Test("a stale plain id that is still a plain row resolves to itself")
    func staleResolutionForUnchangedPlainId() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(ACPTranscriptScroller.Coordinator.resolveStaleRowId(
            "tc-c", lookup: lookup, groupingEnabled: true
        )?.rowId == "tc-c")
    }

    @Test("an unresolvable stale id returns nil")
    func staleResolutionForUnknownId() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(ACPTranscriptScroller.Coordinator.resolveStaleRowId("missing", lookup: lookup, groupingEnabled: true) == nil)
        #expect(ACPTranscriptScroller.Coordinator.resolveStaleRowId("tcg-missing", lookup: lookup, groupingEnabled: true) == nil)
    }

    @Test("row id for a bundled member is the group id; plain rows map to themselves")
    func rowIdForStableId() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.rowId(forStableId: "tc-b") == "tcg-tc-a")
        #expect(lookup.rowId(forStableId: "tc-c") == "tc-c")
        #expect(lookup.rowId(forStableId: "u") == "u")
        #expect(lookup.rowId(forStableId: "missing") == nil)
    }

    @Test("a group's local index span covers its first through last member")
    func groupLocalIndexSpan() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.localIndexSpan(forRowId: "tcg-tc-a") == 1...3)
    }

    @Test("a plain row's local index span is just its own index")
    func plainRowLocalIndexSpan() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.localIndexSpan(forRowId: "u") == 0...0)
        #expect(lookup.localIndexSpan(forRowId: "tc-c") == 4...4)
    }

    @Test("an unknown row id has no span")
    func unknownRowIdHasNoSpan() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.localIndexSpan(forRowId: "missing") == nil)
    }
}

/// The expanded bundle is where the collapsed design used to have to guess.
/// These cover the properties that replace the guessing: each member is its
/// own row, with its own single-message span and its own stable row id.
@MainActor
@Suite("ACP visible row lookup with an expanded group")
struct ACPTranscriptVisibleRowLookupExpandedGroupTests {
    private let group = ACPTranscriptToolCallGroup(members: [
        ACPTranscriptVisibleRow(index: 1, stableId: "tc-a"),
        ACPTranscriptVisibleRow(index: 2, stableId: "tc-b"),
        ACPTranscriptVisibleRow(index: 3, stableId: "tc-c"),
    ])

    private var rows: [ACPTranscriptRenderRow] {
        [.message(ACPTranscriptVisibleRow(index: 0, stableId: "u"))]
            + [.toolCallGroupHeader(group)]
            + group.members.map { .toolCallGroupMember($0, groupId: group.id) }
    }

    @Test("each expanded member spans exactly its own message")
    func memberSpansOneMessage() {
        // This is what makes window compaction exact: the row under the
        // viewport names one message, instead of a fraction across the
        // whole bundle's member count.
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.localIndexSpan(forRowId: "tc-a") == 1...1)
        #expect(lookup.localIndexSpan(forRowId: "tc-b") == 2...2)
        #expect(lookup.localIndexSpan(forRowId: "tc-c") == 3...3)
    }

    @Test("an expanded member's row is itself, not the bundle")
    func memberResolvesToItsOwnRow() {
        // With the member tiled as its own row, an anchor on it stays valid
        // through expand/collapse/disable — there is no stale id to remap.
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.rowId(forStableId: "tc-b") == "tc-b")
        #expect(lookup.transcriptIndex(for: "tc-b") == 2)
    }

    @Test("the header has an anchor index but no logical span of its own")
    func headerHasAnchorIndexButNoSpan() {
        // The header represents no message: its first member follows as its
        // own row and owns that index. If the header also claimed the span,
        // the logical position would advance by one while scrolling the
        // header and then jump backward on entering that member row.
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.transcriptIndex(for: group.id) == 1)
        #expect(lookup.localIndexSpan(forRowId: group.id) == nil)
        // The first member still owns it.
        #expect(lookup.localIndexSpan(forRowId: "tc-a") == 1...1)
    }

    @Test("a stale expanded-bundle header resolves to its member card without assuming head growth")
    func staleExpandedHeaderResolvesTopRelative() {
        // Two expanded runs merge when the active call between them
        // finishes: the later run's header id disappears, because the
        // merged bundle is keyed by the FIRST run's first member. The
        // reader was parked on that vanished header.
        //
        // It decodes to its old first member, which is now tiled as its own
        // card. A header is short and a tool card can be many viewports
        // tall, so restoring bottom-relative (head growth) would drop the
        // viewport to the bottom of that card; tops must be aligned.
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        let staleHeaderId = ACPTranscriptToolCallGroup.idPrefix + "tc-b"
        let resolution = ACPTranscriptScroller.Coordinator.resolveStaleRowId(
            staleHeaderId, lookup: lookup, groupingEnabled: true
        )
        #expect(resolution?.rowId == "tc-b")
        #expect(resolution?.assumeHeadGrowth == false)
    }

    @Test("a middle member absorbed into a merged expanded group needs no stale remap")
    func middleMemberNeedsNoStaleRemap() {
        // The "preserve middle-member anchors during group merges" case:
        // the bridging call keeps its own row id on both sides of the
        // merge, so resolveStaleRowId is never consulted for it.
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        #expect(lookup.rowId(forStableId: "tc-b") == "tc-b")
        #expect(ACPTranscriptScroller.Coordinator.resolveStaleRowId(
            "tc-b", lookup: lookup, groupingEnabled: true
        )?.rowId == "tc-b")
    }
}

@MainActor
@Suite("ACP minimap fraction across a group's span")
struct ACPMinimapGroupSpanTests {
    @Test("a single-message row (span of one) advances by exactly one unit")
    func singleMessageSpanAdvancesByOne() {
        #expect(ACPTranscriptScroller.Coordinator.globalMessagePosition(
            rowFraction: 0, globalIndexSpan: 5...5
        ) == 5)
        #expect(ACPTranscriptScroller.Coordinator.globalMessagePosition(
            rowFraction: 0.5, globalIndexSpan: 5...5
        ) == 5.5)
        #expect(ACPTranscriptScroller.Coordinator.globalMessagePosition(
            rowFraction: 1, globalIndexSpan: 5...5
        ) == 6)
    }

    @Test("a grouped row (span of several) advances proportionally across its full span")
    func groupedRowSpanAdvancesAcrossFullSpan() {
        #expect(ACPTranscriptScroller.Coordinator.globalMessagePosition(
            rowFraction: 0, globalIndexSpan: 10...19
        ) == 10)
        #expect(ACPTranscriptScroller.Coordinator.globalMessagePosition(
            rowFraction: 0.5, globalIndexSpan: 10...19
        ) == 15)
        #expect(ACPTranscriptScroller.Coordinator.globalMessagePosition(
            rowFraction: 1, globalIndexSpan: 10...19
        ) == 20)
    }

    @Test("the row fraction is clamped to 0...1")
    func rowFractionIsClamped() {
        #expect(ACPTranscriptScroller.Coordinator.globalMessagePosition(
            rowFraction: -0.2, globalIndexSpan: 10...19
        ) == 10)
        #expect(ACPTranscriptScroller.Coordinator.globalMessagePosition(
            rowFraction: 1.4, globalIndexSpan: 10...19
        ) == 20)
    }

    @Test("a target at the group's first member lands at the row's top")
    func targetAtFirstMemberLandsAtTop() {
        #expect(ACPTranscriptScroller.Coordinator.rowFraction(
            forGlobalMessagePosition: 10, globalIndexSpan: 10...19
        ) == 0)
    }

    @Test("a target mid-way through the group lands mid-way down the row")
    func targetMidGroupLandsMidRow() {
        #expect(ACPTranscriptScroller.Coordinator.rowFraction(
            forGlobalMessagePosition: 15, globalIndexSpan: 10...19
        ) == 0.5)
    }

    @Test("a target at the group's last member lands near the row's bottom")
    func targetAtLastMemberLandsNearBottom() {
        #expect(ACPTranscriptScroller.Coordinator.rowFraction(
            forGlobalMessagePosition: 19, globalIndexSpan: 10...19
        ) == 0.9)
    }

    @Test("the row fraction for a single-message row (span of one) is unaffected")
    func singleMessageRowFractionUnaffected() {
        let fraction = ACPTranscriptScroller.Coordinator.rowFraction(
            forGlobalMessagePosition: 5.3, globalIndexSpan: 5...5
        )
        #expect(abs(fraction - 0.3) < 0.0001)
    }

    @Test("an out-of-range target clamps to the row's bounds")
    func outOfRangeTargetClamps() {
        #expect(ACPTranscriptScroller.Coordinator.rowFraction(
            forGlobalMessagePosition: 5, globalIndexSpan: 10...19
        ) == 0)
        #expect(ACPTranscriptScroller.Coordinator.rowFraction(
            forGlobalMessagePosition: 25, globalIndexSpan: 10...19
        ) == 1)
    }

    @Test("rowFraction is the inverse of globalMessagePosition")
    func rowFractionIsInverseOfGlobalMessagePosition() {
        let span = 10...19
        for rawFraction in stride(from: CGFloat(0), through: CGFloat(1), by: CGFloat(0.1)) {
            let position = ACPTranscriptScroller.Coordinator.globalMessagePosition(
                rowFraction: rawFraction, globalIndexSpan: span
            )
            let roundTripped = ACPTranscriptScroller.Coordinator.rowFraction(
                forGlobalMessagePosition: position, globalIndexSpan: span
            )
            #expect(abs(roundTripped - rawFraction) < 0.0001)
        }
    }
}

@MainActor
@Suite("ACP tool-call group expansion seeds")
struct ACPToolCallGroupExpansionSeedsTests {
    @Test("a group is not expanded until one of its members is recorded")
    func notExpandedInitially() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        #expect(!seeds.isExpanded(members: ["tc-a", "tc-b"]))
    }

    @Test("recording expansion for any current member marks the group expanded")
    func recordingAnyMemberMarksExpanded() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        seeds.setExpanded(true, members: ["tc-a", "tc-b"])
        #expect(seeds.isExpanded(members: ["tc-a", "tc-b"]))
    }

    @Test("a regrouped bundle sharing at least one prior member is still reported expanded")
    func regroupedBundleStaysExpanded() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        seeds.setExpanded(true, members: ["tc-a", "tc-b"])
        // Backfill revealed an older adjacent call ("tc-z"), which becomes
        // the new first member and would change the group's row id — the
        // seed should still recognize this as the same logical bundle.
        #expect(seeds.isExpanded(members: ["tc-z", "tc-a", "tc-b"]))
    }

    @Test("an unrelated bundle sharing no members is not expanded")
    func unrelatedBundleIsNotExpanded() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        seeds.setExpanded(true, members: ["tc-a", "tc-b"])
        #expect(!seeds.isExpanded(members: ["tc-x", "tc-y"]))
    }

    @Test("collapsing removes every current member from the seed set")
    func collapsingRemovesMembers() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        seeds.setExpanded(true, members: ["tc-a", "tc-b"])
        seeds.setExpanded(false, members: ["tc-a", "tc-b"])
        #expect(!seeds.isExpanded(members: ["tc-a", "tc-b"]))
    }

    /// Regression test for the Codex finding: bare member-id overlap cannot
    /// distinguish "the same still-expanded run growing" from "a collapsed
    /// run reassembling from members some of which still carry a stale seed
    /// from before the window trimmed them out." `syncLineage` folds
    /// currently-visible members into whichever lineage is already present
    /// among them on every render (not just at expand/collapse time), so a
    /// LATER collapse — from any visible subset — clears every member that
    /// was ever part of the same expand session, not just the ones passed
    /// to that specific `setExpanded(false, ...)` call.
    @Test("collapsing clears the whole lineage, including members outside the current window")
    func collapsingClearsWholeLineageAcrossWindowTrim() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        // Expand the full run, then sync as backfill/trimming keeps the
        // window changing while it stays expanded — folding every member
        // that has ever been visible into the same lineage.
        seeds.setExpanded(true, members: ["tc-5", "tc-10", "tc-20"])
        seeds.syncLineage(members: ["tc-5", "tc-10", "tc-20"])

        // The window trims to only the tail; the user collapses from what's
        // currently visible.
        seeds.setExpanded(false, members: ["tc-10", "tc-20"])

        // Backfill later re-reveals tc-5, rejoining the same logical run —
        // it must not silently re-expand from a stale seed.
        #expect(!seeds.isExpanded(members: ["tc-5", "tc-10", "tc-20"]))
        #expect(!seeds.isExpanded(members: ["tc-5"]))
    }

    @Test("syncLineage folds a newly joined member into an already-expanded run's lineage")
    func syncLineageFoldsNewMemberIntoExistingLineage() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        seeds.setExpanded(true, members: ["tc-a", "tc-b"])
        // "tc-z" joined the run (e.g. backfill) but was never itself passed
        // to setExpanded.
        seeds.syncLineage(members: ["tc-z", "tc-a", "tc-b"])
        // Collapsing from a subset that no longer includes the original
        // members still clears "tc-z" too, since syncLineage folded it in.
        seeds.setExpanded(false, members: ["tc-z"])
        #expect(!seeds.isExpanded(members: ["tc-z", "tc-a", "tc-b"]))
    }

    /// Regression test for the Codex finding: when two independently
    /// expanded runs merge (the unfinished call that used to separate them
    /// completes), `syncLineage` must reassign every member of the
    /// discarded lineage — including ones outside the current window — to
    /// the surviving lineage, not just the currently-visible members.
    @Test("syncLineage merges a second lineage's hidden members too, not just the visible ones")
    func syncLineageMergesHiddenMembersOfDiscardedLineage() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        // Two runs, independently expanded — two distinct lineages.
        seeds.setExpanded(true, members: ["tc-a", "tc-b"])
        seeds.setExpanded(true, members: ["tc-x", "tc-y"])

        // The runs merge: the currently visible members span both, but
        // "tc-y" has scrolled out of the window and is NOT passed here.
        seeds.syncLineage(members: ["tc-a", "tc-b", "tc-x"])

        // Collapsing from what's visible now only sees one lineage among
        // its own members and clears that one.
        seeds.setExpanded(false, members: ["tc-a", "tc-b", "tc-x"])

        // "tc-y" must not still carry the discarded lineage: if it does,
        // revealing it again later would make it look expanded on its own.
        #expect(!seeds.isExpanded(members: ["tc-y"]))
    }

    @Test("syncLineage on a never-expanded group is a no-op")
    func syncLineageNoOpWhenNeverExpanded() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        seeds.syncLineage(members: ["tc-a", "tc-b"])
        #expect(!seeds.isExpanded(members: ["tc-a", "tc-b"]))
    }

    @Test("every setExpanded notifies onChange, so the owner can rebuild specs")
    func setExpandedNotifiesOnChange() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        var changes = 0
        seeds.onChange = { changes += 1 }
        seeds.setExpanded(true, members: ["tc-a"])
        seeds.setExpanded(false, members: ["tc-a"])
        #expect(changes == 2)
    }

    @Test("syncLineage does not notify onChange")
    func syncLineageDoesNotNotify() {
        // Called from inside spec building on every render; re-entering
        // `update(host:)` from there would loop.
        let seeds = ACPToolCallGroupExpansionSeeds()
        seeds.setExpanded(true, members: ["tc-a"])
        var changes = 0
        seeds.onChange = { changes += 1 }
        seeds.syncLineage(members: ["tc-a", "tc-b"])
        #expect(changes == 0)
    }
}
