# Activity Fold Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tool activity in ACP transcripts read as calm, semantic groups ("Read 2 files, ran 1 command") with light one-line members, running calls inline, and auto-expand while live.

**Architecture:** Evolve the existing fold pipeline — `ACPToolCallGrouping.fold` → header + per-member render rows → scroller tiling. Rules change in the fold, labels in `ACPToolCallGroupSummary`, auto-expansion in `ACPToolCallGroupExpansionSeeds`, visuals in `ACPToolCallGroupHeaderRow` and `ACPToolCallCard`. No new files; one file pair (absorb animation) is deleted.

**Tech Stack:** Swift 5.9+, SwiftUI on macOS, Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-27-activity-fold-design.md`

## Global Constraints

- Code, comments, and UI strings in English.
- Tests use Swift Testing (`import Testing`); extend existing suites, never add sibling test files; parameterize input variants.
- Expanded bundles MUST keep tiling as header row + one row per member (scroll-anchor precision). Never nest members inside one row.
- After adding or deleting any file under `Alas/` or `AlasTests/`, run `xcodegen` and commit `Alas.xcodeproj` with the change.
- Conventional Commits; no agent attribution trailers or footers of any kind.
- File edits (`.fileEdit`), subagent rows, and context compaction rows are untouched.

## Running tests locally

Use this form for every "run" step (replace `<Suites>`). Never pipe `xcodebuild` into `tail`; redirect and grep.

```bash
ALAS_ZMX_OPTIONAL=1 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  <Suites> test > /tmp/fold-test.log 2>&1; grep -E "✘|✔ Test run|Test run with|error:|\*\* TEST (SUCCEEDED|FAILED)" /tmp/fold-test.log | tail -30
```

`<Suites>` is a list of `-only-testing AlasTests/<StructName>`. Swift Testing's real result is the `✔`/`✘` lines; ignore the XCTest bridge's "Executed 0 tests".

## Review Focus

1. A tool call awaiting permission (`awaiting_permission` or any unknown status) must stay visible outside every group — a hidden permission prompt blocks the user. Pinned by the existing `completedTurnKeepsBlockersVisible`; Task 1 must keep it green.
2. Collapsing a live, auto-expanded group must stick while it keeps growing. Test in Task 3.
3. An expanded group must turn back to collapsed on its own when narration follows it, unless the user expanded it explicitly. Test in Task 3.
4. A lone call must not become a one-member group, but a lone call in a completed turn still carries "Worked for …". Tests in Task 1.
5. Titles that repeat the verb ("Read foo.swift" under "Read") must not render the verb twice. Test in Task 5.

---

### Task 1: Grouping rules — running calls join, lone calls stay bare, live tail flag

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPToolCallGrouping.swift` (group struct L5–44, `Options` L85–101, `isCollapsible` L163–174, `fold` L184–260)
- Modify: `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift` (`groupingOptions` L652–673)
- Modify: `docs/superpowers/specs/2026-09-27-activity-fold-design.md` (§1)
- Test: `AlasTests/ACP/UI/ACPToolCallGroupingTests.swift`, `AlasTests/ACP/UI/ACPTranscriptScrollerPolicyTests.swift`

**Interfaces:**
- Produces: `ACPTranscriptToolCallGroup.isLive: Bool` (init param `isLive: Bool = false`, last); `ACPToolCallGrouping.Options.isTurnActive: Bool = false`.

- [ ] **Step 1: Update the grouping test helper and write the failing tests**

In `ACPToolCallGroupingTests`, add an `isTurnActive: Bool = false` parameter to the private `fold(...)` helper (after `currentNarrationIndex`) and pass `isTurnActive: isTurnActive` into `.init(...)` of the options. Add a helper below `ids(_:)`:

```swift
    private func groups(_ rows: [ACPTranscriptRenderRow]) -> [ACPTranscriptToolCallGroup] {
        rows.compactMap { row in
            switch row {
            case .toolCallGroup(let group), .toolCallGroupHeader(let group): group
            default: nil
            }
        }
    }
```

Replace `singleFinishedToolFolds`, `activeToolEndsRun`, and `pendingToolIsActive` with:

```swift
    @Test("a lone tool call between messages is a plain row, not a one-member group")
    func loneToolCallIsPlainRow() throws {
        let before = ACPMessage.user(id: UUID(), messageId: "u1", text: "hi", attachments: [])
        let after = ACPMessage.user(id: UUID(), messageId: "u2", text: "thanks", attachments: [])
        let folded = fold([before, tool("a"), after])
        #expect(ids(folded) == ["acp-user:u1", "tc-a", "acp-user:u2"])
        guard case .message = folded[1] else {
            Issue.record("expected a plain message row")
            return
        }
    }

    @Test("a running or pending tool call joins the group instead of ending it", arguments: ["in_progress", "pending"])
    func liveToolJoinsRun(status: String) {
        #expect(ids(fold([tool("a"), tool("b", status: status), tool("c")])) == ["tcg-tc-a"])
    }

    @Test("only the trailing group of an active turn is live")
    func onlyTrailingGroupIsLive() {
        let prose = ACPMessage.agent(id: UUID(), messageId: "m1", StreamingText("text"))
        let plan = ACPMessage.plan(id: UUID(), [.init(content: "x", status: "pending")])
        let messages = [tool("a"), tool("b"), prose, tool("c"), tool("d", status: "in_progress"), plan]
        #expect(groups(fold(messages, isTurnActive: true)).map(\.isLive) == [false, true])
        #expect(groups(fold(messages)).map(\.isLive) == [false, false])
    }
```

Update existing expectations that assumed one-call groups:

- `mixedActivityBoundaries`: first expectation becomes `["tcg-acp-thought:t1", "acp-agent:p1", "tc-b"]`; second becomes `["tcg-tc-a", "tc-b"]`.
- `currentTurnKeepsOrdinaryAgentProseVisible`: `"tcg-tc-a"` → `"tc-a"`.
- `breakAfterIndexSplitsRunAcrossRowlessBoundary`: expectation becomes `["tc-a", "tcg-tc-c"]`.
- `splitTurnDoesNotRepeatDuration`: give the first run two calls so it still forms a group:

```swift
        let messages: [ACPMessage] = [
            .user(id: UUID(), messageId: "u", text: "Investigate", attachments: []),
            tool("a"),
            tool("a2"),
            fork ? tool("boundary") : agent("note", "Keep this explanation visible", phase: .finalAnswer),
            tool("b"),
            agent("answer", "Done", phase: .finalAnswer),
        ]
        let rows = fold(messages, breakAfterIndex: fork ? 3 : nil, currentTurnAnswerIndex: 5)
```

In `ACPTranscriptScrollerPolicyTests.swift` (`ACPTranscriptScrollerRowSpecsTests`):

- Rename `toolCallsFoldWhenCollapsingOn` to `@Test("tool calls, running ones included, fold into one group row when collapsing is on")` and change its expectation to `["tcg-tc-a", "__composer_spacer__"]`.
- `forkDividerEmittedAcrossRowlessBoundary`: expectation becomes `["tc-a", "__fork_divider__", "tcg-tc-c", "__composer_spacer__"]`.

- [ ] **Step 2: Run the tests to verify they fail**

Run with `-only-testing AlasTests/ACPToolCallGroupingTests -only-testing AlasTests/ACPTranscriptScrollerRowSpecsTests`.
Expected: compile failure (`isTurnActive` / `isLive` do not exist).

- [ ] **Step 3: Implement**

In `ACPTranscriptToolCallGroup`, add after `currentNarrationIndex`:

```swift
    /// The trailing run of a turn that is still running. Drives the
    /// "Exploring…/Running…" label and automatic expansion.
    let isLive: Bool
```

and extend `init` with a trailing `isLive: Bool = false` parameter assigned to `self.isLive`.

In `Options`, add:

```swift
        /// Whether the latest turn is still running; only then can a group be live.
        var isTurnActive: Bool = false
```

Replace `isCollapsible` and its doc comment:

```swift
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
              ACPSubagentRowDescriptor(toolCall: toolCall) == nil
        else { return false }
        return true
    }
```

In `fold`, right after `completedTurnKinds` is computed, add:

```swift
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
```

Replace the body of `flushRun()` with:

```swift
        func flushRun() {
            if !run.isEmpty {
                let kind = runKind ?? .activity
                if kind == .activity, run.count == 1,
                   messages.indices.contains(run[0].index),
                   case .toolCall = messages[run[0].index] {
                    // A lone call reads better as its own one-line row than
                    // as a disclosure hiding a single line.
                    result.append(.message(run[0]))
                } else {
                    let group = ACPTranscriptToolCallGroup(
                        members: run,
                        kind: kind,
                        currentNarrationIndex: runCurrentNarrationIndex,
                        isLive: kind == .activity && run[run.count - 1].index == liveTailIndex
                    )
                    if isExpanded(group) {
                        result.append(.toolCallGroupHeader(group))
                        for member in group.members {
                            result.append(.toolCallGroupMember(member, groupId: group.id))
                        }
                    } else {
                        result.append(.toolCallGroup(group))
                    }
                }
            }
            run.removeAll(keepingCapacity: true)
            runKind = nil
            runCurrentNarrationIndex = nil
        }
```

In `ACPTranscriptScroller.Coordinator.groupingOptions`, append `isTurnActive: host.transcript.streamingState != .idle` as the last argument of `ACPToolCallGrouping.Options(...)` (after the `currentNarrationIndex:` argument). `Options` is already part of `ACPVisibleRowsCache`'s key, so live-state changes invalidate the memoized rows.

In the spec §1, replace the `flushRun` bullet with: "`flushRun`: an `.activity` run containing exactly one tool call and nothing else is emitted as a plain `.message` row. Completed-turn runs always form a group so they keep "Worked for …"." Replace the `isCollapsible` bullet's "any status" with "finished, `in_progress`, or `pending` status (unknown statuses such as a permission wait stay visible)".

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: all `✔`, including `completedTurnKeepsBlockersVisible`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPToolCallGrouping.swift Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift AlasTests/ACP/UI/ACPToolCallGroupingTests.swift AlasTests/ACP/UI/ACPTranscriptScrollerPolicyTests.swift
git add -f docs/superpowers/specs/2026-09-27-activity-fold-design.md
git commit -m "feat(acp): fold running tool calls and leave lone calls unbundled"
```

---

### Task 2: Verb-count header labels

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPToolCallGrouping.swift` (`ACPToolCallGroupSummary`, L364–429)
- Modify: `Alas/Sources/ACP/UI/ACPToolCallGroupRow.swift` (`label` property, L63–65)
- Modify: `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift` (`toolCallGroupHeaderSpec`, summary construction ~L777)
- Test: `AlasTests/ACP/UI/ACPToolCallGroupingTests.swift` (summary suite + `completedCurrentTurnCarriesDuration`), `AlasTests/ACP/UI/ACPTranscriptScrollerPolicyTests.swift`

**Interfaces:**
- Consumes: `ACPTranscriptToolCallGroup.isLive` (Task 1), `ACPToolCallPresentation.resolve(_:)`.
- Produces: `ACPToolCallGroupSummary(toolCalls:kind:isLive:)`, `.label: String`, `.iconSystemName: String`, `.isLive: Bool`, `.count`, `.failedCount`. Removes `collapsedLabel`, `expandedLabel`, `latestToolTitle`.

- [ ] **Step 1: Write the failing tests**

In `ACPToolCallGroupSummaryTests`, replace the `tool` helper with:

```swift
    private func tool(_ id: String, kind: String = "read", status: String = "completed") -> ACPMessage.ToolCall {
        .init(toolCallId: id, title: id, kind: kind, status: status)
    }

    private func calls(_ kinds: [String]) -> [ACPMessage.ToolCall] {
        kinds.enumerated().map { tool("t\($0.offset)", kind: $0.element) }
    }
```

Append to `countsMembersAndFailures`:

```swift
        #expect(summary.label == "Read 3 files · 1 failed")
```

Replace `collapsedLabel` and `expandedLabel` tests with:

```swift
    @Test("the label counts tool verbs in first-appearance order", arguments: [
        (["read"], "Read 1 file"),
        (["read", "read", "search"], "Read 2 files, searched 1 time"),
        (["execute", "read", "execute", "execute"], "Ran 3 commands, read 1 file"),
        (["edit", "fetch"], "Edited 1 file, used 1 tool"),
        ([], "Thought"),
    ])
    func labelCountsVerbs(kinds: [String], expected: String) {
        #expect(ACPToolCallGroupSummary(toolCalls: calls(kinds)).label == expected)
    }

    @Test("a live group says what it is doing and how far it got", arguments: [
        (["read", "search", "read"], "Exploring · 3 so far"),
        (["read", "execute"], "Running · 2 so far"),
        ([], "Thinking"),
    ])
    func liveLabel(kinds: [String], expected: String) {
        #expect(ACPToolCallGroupSummary(toolCalls: calls(kinds), isLive: true).label == expected)
    }
```

In `ACPToolCallGroupingTests.completedCurrentTurnCarriesDuration`, replace the two label expectations with:

```swift
        #expect(summary.label == "Worked for 2m 5s · read 1 file")
```

In `ACPTranscriptScrollerPolicyTests.swift`, delete `latestToolTitleChangesHeaderToken` (the title no longer appears in the header).

- [ ] **Step 2: Run the tests to verify they fail**

Run with `-only-testing AlasTests/ACPToolCallGroupSummaryTests -only-testing AlasTests/ACPToolCallGroupingTests`.
Expected: compile failure (`label` / `isLive:` do not exist).

- [ ] **Step 3: Implement**

Replace `ACPToolCallGroupSummary` (keep `isFailed(status:)` and `completedLabel(duration:)` exactly as they are) with:

```swift
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

    // isFailed(status:) — unchanged

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
        switch kind {
        case .activity:
            guard !counts.isEmpty else { return isLive ? "Thinking" : "Thought" }
            return counts.prefix(1).uppercased() + counts.dropFirst() + failure
        case .completedTurn(let duration):
            return completedLabel(duration: duration) + (counts.isEmpty ? "" : " · " + counts) + failure
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

    // completedLabel(duration:) — unchanged
}
```

Delete `toolSuffix`, `failureSuffix`, `collapsedLabel`, `expandedLabel`, and `latestToolTitle`.

In `ACPToolCallGroupHeaderRow`, change `label` to:

```swift
    private var label: String { summary.label }
```

In `toolCallGroupHeaderSpec`, construct the summary with liveness:

```swift
            let summary = ACPToolCallGroupSummary(toolCalls: toolCalls, kind: group.kind, isLive: group.isLive)
```

Update that function's doc comment: replace "Counts, failures, and the latest tool title are part of `summary`" with "Verb counts, failures, and liveness are part of `summary`".

- [ ] **Step 4: Run the tests to verify they pass**

Run with `-only-testing AlasTests/ACPToolCallGroupSummaryTests -only-testing AlasTests/ACPToolCallGroupingTests -only-testing AlasTests/ACPTranscriptScrollerRowSpecsTests -only-testing AlasTests/ACPToolCallGroupRowTests`.
Expected: all `✔`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPToolCallGrouping.swift Alas/Sources/ACP/UI/ACPToolCallGroupRow.swift Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift AlasTests/ACP/UI/ACPToolCallGroupingTests.swift AlasTests/ACP/UI/ACPTranscriptScrollerPolicyTests.swift
git commit -m "feat(acp): label activity groups by what their tools did"
```

---

### Task 3: Auto-expand the live group; explicit toggles win

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPToolCallGrouping.swift` (`ACPToolCallGroupExpansionSeeds`, L431–538)
- Modify: `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift` (`toolCallGroupHeaderSpec`, `expanded` ~L785)
- Test: `AlasTests/ACP/UI/ACPToolCallGroupingTests.swift` (seeds suite), `AlasTests/ACP/UI/ACPTranscriptScrollerPolicyTests.swift`

**Interfaces:**
- Consumes: `ACPTranscriptToolCallGroup.isLive`, `init(members:kind:currentNarrationIndex:isLive:)` (Task 1).
- Produces: `ACPToolCallGroupExpansionSeeds.isExpanded(_ group:)` now returns explicit state, else `group.isLive`. `isExpanded(members:)` keeps meaning "explicitly expanded".

- [ ] **Step 1: Write the failing tests**

In `ACPToolCallGroupExpansionSeedsTests`, add:

```swift
    private func group(_ ids: [String], live: Bool) -> ACPTranscriptToolCallGroup {
        ACPTranscriptToolCallGroup(
            members: ids.enumerated().map { ACPTranscriptVisibleRow(index: $0.offset, stableId: $0.element) },
            isLive: live
        )
    }

    @Test("an untouched group is expanded exactly while it is the live tail", arguments: [true, false])
    func untouchedGroupFollowsLiveness(live: Bool) {
        #expect(ACPToolCallGroupExpansionSeeds().isExpanded(group(["tc-a", "tc-b"], live: live)) == live)
    }

    @Test("collapsing a live group keeps it collapsed as it grows, until expanded again")
    func explicitCollapseOverridesLiveness() {
        let seeds = ACPToolCallGroupExpansionSeeds()
        var changes = 0
        seeds.onChange = { changes += 1 }
        seeds.setExpanded(false, members: ["tc-a", "tc-b"])
        #expect(changes == 1)
        #expect(!seeds.isExpanded(group(["tc-a", "tc-b", "tc-c"], live: true)))

        seeds.setExpanded(true, members: ["tc-a", "tc-b", "tc-c"])
        #expect(seeds.isExpanded(group(["tc-a", "tc-b", "tc-c"], live: false)))
    }
```

In `ACPTranscriptScrollerPolicyTests.swift`, replace `groupTokenChangesOnLiveNarration` with:

```swift
    @Test("the trailing group of a streaming turn renders expanded")
    func liveTrailingGroupRendersExpanded() {
        let host = makeHost(collapsesFinishedToolCalls: true)
        host.transcript.messages = [tool("a"), tool("b", status: "in_progress")]
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil
        host.transcript.streamingState = .streaming

        let ids = ACPTranscriptScroller.Coordinator.rowSpecs(
            host: host, expansionSeeds: ACPToolCallGroupExpansionSeeds()
        ).map(\.id)
        // Streaming may append synthetic tail rows; only the fold matters here.
        #expect(Array(ids.prefix(3)) == ["tcg-tc-a", "tc-a", "tc-b"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run with `-only-testing AlasTests/ACPToolCallGroupExpansionSeedsTests -only-testing AlasTests/ACPTranscriptScrollerRowSpecsTests`.
Expected: `✘` on the three new tests (live groups report collapsed; collapsing an unexpanded group does not notify).

- [ ] **Step 3: Implement**

In `ACPToolCallGroupExpansionSeeds`, add below `lineageByMemberId`:

```swift
    /// Members of runs the user explicitly collapsed. Needed because a live
    /// run is expanded automatically; without this, collapsing it would be
    /// undone by the next render.
    private var collapsedMemberIds: Set<String> = []
```

Replace `setExpanded`'s body:

```swift
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
```

Replace `isExpanded(_ group:)`:

```swift
    /// Whether `group` should render expanded: the user's explicit choice
    /// when there is one, otherwise open only while it is the live tail.
    func isExpanded(_ group: ACPTranscriptToolCallGroup) -> Bool {
        let members = group.members.map(\.stableId)
        if isExpanded(members: members) { return true }
        if members.contains(where: collapsedMemberIds.contains) { return false }
        return group.isLive
    }
```

In `toolCallGroupHeaderSpec`, change

```swift
            let expanded = expansionSeeds.isExpanded(members: memberStableIds)
```

to

```swift
            let expanded = expansionSeeds.isExpanded(group)
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2, plus `-only-testing AlasTests/ACPToolCallGroupingTests`. Expected: all `✔`, including the existing lineage tests.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPToolCallGrouping.swift Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift AlasTests/ACP/UI/ACPToolCallGroupingTests.swift AlasTests/ACP/UI/ACPTranscriptScrollerPolicyTests.swift
git commit -m "feat(acp): keep the live activity group open while it runs"
```

---

### Task 4: New group header; delete the absorb pulse and live narration preview

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPToolCallGroupRow.swift` (whole header view, live narration types, member row, lane)
- Modify: `Alas/Sources/ACP/UI/ACPToolCallGrouping.swift` (remove `currentNarrationIndex` from group, `Options`, and `fold`)
- Modify: `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift` (`groupingOptions`, `groupLiveNarration`, `toolCallGroupHeaderSpec`, `ToolCallGroupTokenInputs`)
- Modify: `Alas/Sources/ACP/UI/ACPNarrationShimmer.swift` (doc comments L1–8, ~L60)
- Delete: `Alas/Sources/ACP/UI/ACPToolCallGroupHeaderAnimation.swift`, `AlasTests/ACP/UI/ACPToolCallGroupHeaderAnimationTests.swift`
- Modify: `Alas.xcodeproj` (via `xcodegen`)
- Test: `AlasTests/ACP/UI/ACPToolCallGroupRowTests.swift`, `AlasTests/ACP/UI/ACPToolCallGroupingTests.swift`

**Interfaces:**
- Consumes: `ACPToolCallGroupSummary.label`, `.iconSystemName`, `.isLive` (Task 2); `View.acpNarrationShimmer(isActive:axis:)` (existing).
- Produces: `ACPToolCallGroupHeaderRow(summary:expanded:onToggle:)`; `ACPToolCallGroupLane { … }` with no `highlight` parameter; `ACPTranscriptToolCallGroup(members:kind:isLive:)`.

This task removes behavior rather than adding it, so there is no new failing test; the existing header-height and member-row tests guard the geometry.

- [ ] **Step 1: Trim the row tests**

In `ACPToolCallGroupRowTests`, delete `livePreviewPreservesHeaderHeight`, `narrowLivePreviewPreservesHeaderHeight`, `livePreviewUsesBoundedLatestLine`, `livePreviewHeightIsBounded`, `laneHeightIsIndependentOfHighlight`, and the `laneHeight` helper. Replace `headerHeight` with:

```swift
    private func headerHeight(expanded: Bool, theme: Theme) -> CGFloat {
        measure(
            ACPToolCallGroupHeaderRow(
                summary: ACPToolCallGroupSummary(
                    toolCalls: [.init(toolCallId: "a", title: "a", status: "completed")]
                ),
                expanded: expanded
            ),
            theme: theme
        )
    }
```

In `ACPToolCallGroupingTests`, delete `collapsedGroupCarriesLiveNarration`, and remove the `currentNarrationIndex` parameter from the `fold` helper and from its `.init(...)` call.

Delete the absorb animation files:

```bash
git rm Alas/Sources/ACP/UI/ACPToolCallGroupHeaderAnimation.swift AlasTests/ACP/UI/ACPToolCallGroupHeaderAnimationTests.swift
```

- [ ] **Step 2: Rewrite the header, member row, and lane**

Replace everything in `ACPToolCallGroupRow.swift` above `ACPToolCallGroupMemberRow` (the header view, `ACPToolCallGroupLiveNarration`, and `ACPToolCallGroupLiveNarrationPreview`) with:

```swift
import SwiftUI

/// The disclosure row for a run of thinking and tool calls: icon, a
/// verb-count label ("Read 2 files, ran 1 command"), and a chevron. While
/// the run is live the label shimmers.
///
/// This row is ONLY the header. When the bundle is expanded its members are
/// tiled as their own sibling rows (`ACPToolCallGroupMemberRow`) rather than
/// nested inside this view — see `ACPTranscriptRenderRow` for why the
/// scroller needs them to be real rows.
///
/// `expanded` is a plain input, owned by `ACPToolCallGroupExpansionSeeds`
/// and folded into the row's equality token; this view holds no state of
/// its own, so a mounted row and the store can never disagree.
struct ACPToolCallGroupHeaderRow: View {
    let summary: ACPToolCallGroupSummary
    let expanded: Bool
    let onToggle: (Bool) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        summary: ACPToolCallGroupSummary,
        expanded: Bool = false,
        onToggle: @escaping (Bool) -> Void = { _ in }
    ) {
        self.summary = summary
        self.expanded = expanded
        self.onToggle = onToggle
    }

    var body: some View {
        Button {
            onToggle(!expanded)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: summary.iconSystemName)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(theme.color("fg-faint"))
                    .accessibilityHidden(true)
                Text(summary.label)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("fg-faint"))
                    // Rolls the digits instead of snapping them.
                    .contentTransition(.numericText(value: Double(summary.count)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: summary.count)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .acpNarrationShimmer(isActive: summary.isLive)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.color("fg-faint"))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}
```

Change `ACPToolCallGroupMemberRow.body` so the lane sits under the header icon:

```swift
    var body: some View {
        ACPToolCallGroupLane {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 7)
    }
```

Replace `ACPToolCallGroupLane` with:

```swift
/// The shared bar + indent that marks a row as part of a tool-call bundle.
/// Factored out so members (and subagent rows) line up exactly.
struct ACPToolCallGroupLane<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.color("bg-4"))
                .frame(width: 1.5)
                .padding(.vertical, 2)
            content()
        }
    }
}
```

- [ ] **Step 3: Remove `currentNarrationIndex` and the scroller plumbing**

In `ACPToolCallGrouping.swift`:
- Delete `currentNarrationIndex` (property, doc comment, init parameter, assignment) from `ACPTranscriptToolCallGroup`.
- Delete `currentNarrationIndex` (and its doc comment) from `Options`.
- In `fold`, delete `var runCurrentNarrationIndex`, the `if row.index == options.currentNarrationIndex { … }` block, the `runCurrentNarrationIndex = nil` reset, and the `currentNarrationIndex:` argument in the group init.
- In `ACPTranscriptRenderRow`'s doc comment, replace `carrying the "Hide N tools" toggle` with `carrying the disclosure toggle`.

In `ACPTranscriptScroller.swift`:
- `groupingOptions`: delete the `currentNarrationIndex: ACPNarrationLiveness.liveIndex(...)` argument.
- Delete `groupLiveNarration(host:group:)` entirely.
- In `toolCallGroupHeaderSpec`: delete the `liveNarration` and `window` locals and their comments; build the token and view as:

```swift
            return ACPTranscriptRowSpec(
                id: group.id,
                equalityToken: token(
                    ToolCallGroupTokenInputs(
                        summary: summary,
                        expanded: expanded,
                        memberStableIds: memberStableIds
                    ),
                    host: host
                ),
                build: {
                    wrapRow(host: host) {
                        ACPToolCallGroupHeaderRow(
                            summary: summary,
                            expanded: expanded,
                            onToggle: { expansionSeeds.setExpanded($0, members: memberStableIds) }
                        )
                    }
                }
            )
```

- Update its doc comment: drop "live narration" from "The token includes …", and delete the sentence "When collapsed, the live narration buffer publishes directly to the nested preview."
- `ToolCallGroupTokenInputs`: delete `liveNarration` and `window` fields with their comments.
- In the comment near L504–507 replace `rendering "Hide N tools" with` with `rendering expanded with`.

In `ACPNarrationShimmer.swift`:
- L3–8: replace the sentence mentioning `ACPToolCallGroupHeaderAnimation` so the comment reads: "Deciding this reads `StreamingText.phase`, which is `@MainActor`-isolated, so every call site (transcript row building, `ACPSubagentRowView`) already runs on the main actor."
- ~L60: replace "(see `ACPToolCallGroupLane` for why that matters to the scroller)" with "(the scroller re-tiles the transcript whenever a row's measured height changes)".

Then regenerate the project:

```bash
xcodegen
grep -rn "ACPToolCallGroupHeaderAnimation\|ACPToolCallGroupLiveNarration\|currentNarrationIndex\|highlight:" Alas AlasTests
```

Expected: `grep` prints nothing.

- [ ] **Step 4: Run the tests**

Run with `-only-testing AlasTests/ACPToolCallGroupRowTests -only-testing AlasTests/ACPToolCallGroupingTests -only-testing AlasTests/ACPToolCallGroupSummaryTests -only-testing AlasTests/ACPToolCallGroupExpansionSeedsTests -only-testing AlasTests/ACPTranscriptScrollerRowSpecsTests`.
Expected: all `✔`.

- [ ] **Step 5: Commit**

```bash
git add -A Alas/Sources/ACP/UI AlasTests/ACP/UI Alas.xcodeproj
git commit -m "refactor(acp): simplify the activity header to icon, count label, and chevron"
```

---

### Task 5: One-line tool call rows

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPToolCallPresentation.swift` (add `target(for:label:)`)
- Modify: `Alas/Sources/ACP/UI/ACPToolCallCard.swift` (header label L58–102, container L105–112, `statusIndicator` `completed` case L226–229, delete `glyph` L253–263)
- Test: `AlasTests/ACP/UI/ACPToolCallPresentationTests.swift`

**Interfaces:**
- Consumes: `ACPToolCallPresentation.resolve(_:)`.
- Produces: `static func ACPToolCallPresentation.target(for: ACPMessage.ToolCall, label: String) -> String?`.

- [ ] **Step 1: Write the failing test**

Append to `ACPToolCallPresentationTests`:

```swift
    @Test("the one-line target drops a repeated verb and falls back to the first location", arguments: [
        ("Read host/engine.test.ts", [String](), "Read", "host/engine.test.ts"),
        ("git status --short", [], "Ran", "git status --short"),
        ("Read", ["/tmp/a.swift"], "Read", "/tmp/a.swift"),
        ("", [], "Tool", nil),
    ] as [(String, [String], String, String?)])
    func oneLineTarget(title: String, locations: [String], label: String, expected: String?) {
        let toolCall = ACPMessage.ToolCall(
            toolCallId: "t", title: title, status: "completed", locations: locations
        )
        #expect(ACPToolCallPresentation.target(for: toolCall, label: label) == expected)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run with `-only-testing AlasTests/ACPToolCallPresentationTests`.
Expected: compile failure (`target(for:label:)` does not exist).

- [ ] **Step 3: Implement**

Add to `ACPToolCallPresentation`, after `resolve(_:)`:

```swift
    /// What a one-line row names after the verb: the title without a
    /// leading copy of the verb, or the first location when the title adds
    /// nothing.
    static func target(for toolCall: ACPMessage.ToolCall, label: String) -> String? {
        let title = toolCall.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = label.lowercased() + " "
        let stripped = title.lowercased().hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
        let target = stripped.trimmingCharacters(in: .whitespaces)
        if !target.isEmpty, target.lowercased() != label.lowercased() { return target }
        return toolCall.locations.first { !$0.isEmpty }
    }
```

In `ACPToolCallCard.body`, replace the button's `label:` `HStack` (from `HStack(spacing: 8) {` through its `.contentShape(Rectangle())`) with:

```swift
                HStack(spacing: 8) {
                    Image(systemName: presentation.iconSystemName)
                        .font(.system(size: 11))
                        .frame(width: 16)
                        .foregroundStyle(theme.color("fg-faint"))
                        .accessibilityHidden(true)
                    Text(presentation.label)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color("fg-faint"))
                    if let target = ACPToolCallPresentation.target(for: toolCall, label: presentation.label) {
                        Text(verbatim: target)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.color("fg-dim"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 6)
                    if isHovering, let messageCreatedAt {
                        Text(ACPMessageTimestampFormatter.string(for: messageCreatedAt))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                    }
                    if let duration = toolCall.executionDuration {
                        Text(ACPToolCallDurationFormatter.string(for: duration))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                            .accessibilityLabel("Tool duration")
                            .accessibilityValue(ACPToolCallDurationFormatter.string(for: duration))
                    }
                    statusIndicator
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.color("fg-faint"))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, expanded ? 10 : 0)
                .padding(.vertical, expanded ? 7 : 3)
                .contentShape(Rectangle())
```

Make the card chrome appear only when expanded — replace the three container modifiers after the `VStack`:

```swift
        .background(expanded ? theme.color("bg-1").opacity(0.5) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: 0.5)
                .opacity(expanded ? 1 : 0)
        )
```

In `statusIndicator`, make `completed` quiet:

```swift
        case "completed":
            EmptyView()
```

Delete the now-unused `glyph` property.

- [ ] **Step 4: Run the tests and build**

Run with `-only-testing AlasTests/ACPToolCallPresentationTests`. Expected: all `✔`.

Then build:

```bash
ALAS_ZMX_OPTIONAL=1 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build > /tmp/fold-build.log 2>&1; grep -E "error:|BUILD (SUCCEEDED|FAILED)" /tmp/fold-build.log | tail -20
```

Expected: no `error:` lines.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPToolCallPresentation.swift Alas/Sources/ACP/UI/ACPToolCallCard.swift AlasTests/ACP/UI/ACPToolCallPresentationTests.swift
git commit -m "feat(acp): render tool calls as quiet one-line rows"
```

---

### Task 6: Final verification

- [ ] **Step 1: Run every touched suite together**

Run with `-only-testing AlasTests/ACPToolCallGroupingTests -only-testing AlasTests/ACPToolCallGroupSummaryTests -only-testing AlasTests/ACPToolCallGroupExpansionSeedsTests -only-testing AlasTests/ACPToolCallGroupRowTests -only-testing AlasTests/ACPTranscriptScrollerRowSpecsTests -only-testing AlasTests/ACPToolCallPresentationTests`.
Expected: all `✔`. Other transcript suites are left to CI.

- [ ] **Step 2: Look at it**

Ask the user to run the built app on a tool-heavy session and compare against the approved mockup (`.superpowers/brainstorm/*/content/activity-fold.html`): live group open with shimmer, collapses when narration follows, lone calls as bare lines, edits unchanged, completed turn reads "Worked for … · counts".
