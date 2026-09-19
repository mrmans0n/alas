import Foundation
import Testing
@testable import Alas

@Suite("ACP tool-call grouping")
struct ACPToolCallGroupingTests {
    private func tool(_ id: String, status: String = "completed") -> ACPMessage {
        .toolCall(.init(toolCallId: id, title: "Read \(id)", kind: "read", status: status))
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
        breakAfterIndex: Int? = nil
    ) -> [ACPTranscriptRenderRow] {
        let rows = ACPTranscriptVisibleRow.rows(
            messages: messages, visibleHead: 0, visibleTail: messages.count,
            stableId: { $0.stableId }
        )
        return ACPToolCallGrouping.fold(
            rows: rows, messages: messages,
            options: .init(enabled: enabled, breakAfterIndex: breakAfterIndex)
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

    @Test("a thinking row between tool calls splits the run")
    @MainActor
    func thoughtSplitsRun() {
        let thought = ACPMessage.thought(id: UUID(), messageId: "t1", StreamingText("hmm"))
        let folded = fold([tool("a"), tool("b"), thought, tool("c"), tool("d")])
        #expect(ids(folded) == ["tcg-tc-a", "acp-thought:t1", "tcg-tc-c"])
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
            tool("a"), tool("b", status: "failed"), tool("c", status: "error"),
        ])
        #expect(summary.count == 3)
        #expect(summary.failedCount == 2)
    }

    @Test("collapsed label pluralizes and appends the failure count")
    func collapsedLabel() {
        #expect(ACPToolCallGroupSummary(toolCalls: [tool("a"), tool("b")]).collapsedLabel == "Ran 2 tools")
        #expect(ACPToolCallGroupSummary(toolCalls: [tool("a")]).collapsedLabel == "Ran 1 tool")
        #expect(ACPToolCallGroupSummary(toolCalls: [
            tool("a"), tool("b", status: "failed"), tool("c"),
        ]).collapsedLabel == "Ran 3 tools · 1 failed")
    }

    @Test("expanded label offers to hide the bundle")
    func expandedLabel() {
        #expect(ACPToolCallGroupSummary(toolCalls: [tool("a"), tool("b"), tool("c")]).expandedLabel == "Hide 3 tools")
        #expect(ACPToolCallGroupSummary(toolCalls: [tool("a")]).expandedLabel == "Hide 1 tool")
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

    @Test("a stale plain member id that has since been bundled resolves to its group")
    func staleResolutionForBundledPlainId() {
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows)
        let resolution = ACPTranscriptScroller.Coordinator.resolveStaleRowId(
            "tc-b", lookup: lookup, groupingEnabled: true
        )
        #expect(resolution?.rowId == "tcg-tc-a")
        #expect(resolution?.assumeHeadGrowth == true)
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

    @Test("syncLineage on a never-expanded group is a no-op")
    func syncLineageNoOpWhenNeverExpanded() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        seeds.syncLineage(members: ["tc-a", "tc-b"])
        #expect(!seeds.isExpanded(members: ["tc-a", "tc-b"]))
    }
}
