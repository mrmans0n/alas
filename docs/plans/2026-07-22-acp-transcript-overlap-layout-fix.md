# ACP transcript overlapping-rows fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop reopened ACP transcripts from drawing a band of messages superimposed on top of each other.

**Architecture:** The transcript list switched from a plain `VStack` to a `LazyVStack` in #717 (to bound an unbounded reveal window, issue #666). That same era added a hard render-window cap (`maxVisibleRows = 90`, enforced by `setVisibleWindow`), so laziness is now redundant — at most 90 rows ever exist in the `ForEach`. On macOS 26 the `LazyVStack` mis-places rows when the scroll-up "reveal older" path grafts 30 rows at the top of the `ForEach` while a programmatic `scrollTo` re-anchors the viewport (`stepHeadBackPreservingScroll`), leaving a contiguous band drawn at stale/compressed offsets. A plain `VStack` computes every child's real height eagerly and stacks them sequentially, so rows physically cannot overlap regardless of what perturbs the layout — eliminating the entire bug class at the bounded window size.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS), Swift Testing (`import Testing`).

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Tests use the Swift Testing framework (`import Testing`), not XCTest.
- No agent attributions of any kind in commits, PRs, or code.
- The repo finish checklist in `AGENTS.md` (`xcodegen`, the quiet build, and the
  full `xcodebuild ... test`) always governs before a change is considered
  complete — the notes below do not replace it.

Per-task execution notes (do not override the `AGENTS.md` checklist above):

- This change touches no `project.yml`, so `xcodegen` regenerates nothing new
  while iterating — still run the full `AGENTS.md` checklist (including
  `xcodegen`) before finishing.
- If the dev Alas app is running locally, the full `xcodebuild test` can hang
  on the ACP-terminal suites, so iterate against focused `-only-testing`
  suites; CI runs the exhaustive pass, and the full local run per `AGENTS.md`
  should still be completed (e.g. with the dev app quit) before merge.

## Investigation summary (why this fix)

- **Container-level placement bug, not text mis-measurement.** The overlap band includes plain-SwiftUI `ACPThoughtView` rows (`Text` + `Button` only), which cannot under-report height — so individual `sizeThatFits`/`NSTextView` measurement is ruled out; whole row frames are placed wrong.
- **Not a ForEach id collision.** Scanned the affected per-worktree ACP session stores for duplicate `toolCallId` / `(kind, messageId)` pairs — none. The repeated "READ SKILL.md" rows are genuinely distinct tool calls.
- **The render window is already bounded** (existing `ACPTranscriptWindowTests` assert `visibleTail - visibleHead == maxVisibleRows` across `stepHeadBack` / `stepTailForward` / `setVisibleWindow(containing:)` / `shiftVisibleHeadAfterPrepending`). This is what makes eager `VStack` rendering safe today, where it was not at the time of #666.
- **Rows are already `.equatable()`-gated** (`ACPTranscriptRowContent`, from the #823 live-lock fix), so a `VStack` does not re-diff unchanged rows on scroll/geometry passes.

No live GUI repro was possible in the fixing environment. The fix is validated by (a) the structural guarantee that a `VStack` cannot overlap rows, (b) existing window-bound tests, and (c) manual confirmation on the dev build (see Task 3).

---

### Task 1: Lock the bounded-window premise with an explicit mixed-sequence invariant test

Existing tests cover each window path in isolation. Add one test that runs a
realistic mixed sequence (reset → step back → step forward → prepend) and
asserts the window never exceeds `maxVisibleRows` at any point — this is the
single invariant that guarantees the `VStack` in Task 2 renders a bounded
number of rows. Co-locate with the existing window tests.

**Files:**
- Test: `AlasTests/ACP/Session/ACPTranscriptWindowTests.swift` (add one `@Test` to the existing `ACPTranscriptWindowTests` suite)

**Interfaces:**
- Consumes: `ACPTranscript` (`resetWindowToTail()`, `stepHeadBack()`, `stepTailForward(preserving:)`, `shiftVisibleHeadAfterPrepending(_:)`, `setVisibleWindow(containing:)`, `visibleHead`, `visibleTailBound`, `ACPTranscript.maxVisibleRows`) — all already `@MainActor` on `ACPTranscript`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the invariant test**

Add this test inside the existing `struct ACPTranscriptWindowTests` (after
`prependedHistoryPreservesExplicitTailAtOldEnd`):

```swift
    @Test("render window never exceeds maxVisibleRows across a mixed sequence")
    func windowStaysBoundedAcrossMixedSequence() {
        let t = ACPTranscript()
        for _ in 0..<300 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }

        func assertBounded(_ label: String) {
            let span = t.visibleTailBound - t.visibleHead
            #expect(
                span <= ACPTranscript.maxVisibleRows,
                "\(label): window span \(span) exceeded maxVisibleRows \(ACPTranscript.maxVisibleRows)"
            )
            #expect(t.visibleHead >= 0, "\(label): head went negative")
            #expect(t.visibleTailBound <= t.messages.count, "\(label): tail past end")
        }

        t.resetWindowToTail()
        assertBounded("after reset")

        t.stepHeadBack()
        assertBounded("after first step back")
        t.stepHeadBack()
        assertBounded("after second step back")

        t.stepTailForward(preserving: t.visibleHead + 5)
        assertBounded("after step forward")

        t.setVisibleWindow(containing: 120)
        assertBounded("after anchor restore")

        t.messages.insert(contentsOf: (0..<40).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: "older")
        }, at: 0)
        t.shiftVisibleHeadAfterPrepending(40)
        assertBounded("after prepend")
    }
```

- [ ] **Step 2: Run the test to verify it passes (premise holds)**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPTranscriptWindowTests test
```
Expected: PASS, including the new `windowStaysBoundedAcrossMixedSequence`.
(This is a characterization/guard test — it documents the invariant the
`VStack` relies on. If it ever fails, eager rendering is no longer bounded
and Task 2's safety argument must be revisited.)

- [ ] **Step 3: Commit**

```bash
git add AlasTests/ACP/Session/ACPTranscriptWindowTests.swift
git commit -m "test(acp): assert transcript render window stays bounded across mixed steps"
```

---

### Task 2: Render the transcript stack eagerly to eliminate lazy row overlap

Swap the transcript container from `LazyVStack` to `VStack`. Because the
window is capped at `maxVisibleRows` (Task 1's invariant) and heavy rows are
`.equatable()`-gated, eager layout is bounded and cheap, and a `VStack`
cannot draw rows overlapping each other.

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift:141` (the `LazyVStack(alignment: .leading, spacing: 18)` opening the transcript content)

**Interfaces:**
- Consumes: the bounded-window invariant guaranteed by Task 1.
- Produces: no API change; purely the container view type + explanatory comment.

- [ ] **Step 1: Replace `LazyVStack` with `VStack` and document why**

In `Alas/Sources/ACP/UI/ACPMessageList.swift`, find (around line 141):

```swift
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
```

Replace with:

```swift
                    ScrollView {
                        // Eager VStack, not LazyVStack: the render window is
                        // hard-capped at `ACPTranscript.maxVisibleRows` (see
                        // ACPTranscriptWindowTests) and heavy rows are
                        // `.equatable()`-gated (ACPTranscriptRowContent), so at
                        // most ~90 already-diffed rows are ever laid out. A
                        // LazyVStack mis-places rows on macOS 26 when the
                        // scroll-up reveal path grafts a chunk at the top of the
                        // ForEach while `scrollTo` re-anchors the viewport,
                        // drawing a band of messages overlapping. An eager VStack
                        // computes every child's real height and stacks them
                        // sequentially, so rows cannot overlap regardless of
                        // scroll/anchor timing.
                        VStack(alignment: .leading, spacing: 18) {
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the transcript test suites to verify no regression**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPTranscriptWindowTests \
  -only-testing:AlasTests/ACPTranscriptMarkdownCacheEvictionTests \
  -only-testing:AlasTests/ACPMessageListPaginationTests test
```
Expected: PASS (windowing, cache eviction, and pagination policy unaffected).

- [ ] **Step 4: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPMessageList.swift
git commit -m "fix(acp): render transcript rows eagerly to stop overlapping messages"
```

---

### Task 3: Manual validation on the dev build

There is no automated overlap assertion (SwiftUI layout can't be unit-tested
here, and per-row frame reporting is gated off on the modern/macOS-26 scroll
path by #718, so a frame-based DEBUG detector would have no data). Validate
visually on the running dev build the user already uses as their workspace —
do **not** quit their running Alas; just `open` the freshly built app.

**Files:** none.

- [ ] **Step 1: Build and open the dev app**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
open "$(xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')"
```

- [ ] **Step 2: Reproduce the original scenario and confirm the fix**

Open a long restored ACP session (100+ messages — e.g. one of the sessions
from the bug report), scroll up through several "reveal older" steps, then
scroll back down. Confirm:
- no band of superimposed / overlapping messages at any scroll position;
- the "go to newest" affordance still resumes tail-follow;
- streaming into the tail still auto-scrolls and does not beachball.

- [ ] **Step 3: No commit** (validation only).

---

## Self-review notes

- **Spec coverage:** the reported symptom (overlapping transcript rows on
  reopen) is addressed by Task 2; Task 1 protects the premise that keeps the
  fix cheap; Task 3 is the only available validation of the visual outcome.
- **Type consistency:** all referenced members (`maxVisibleRows`,
  `visibleTailBound`, `visibleHead`, `resetWindowToTail`, `stepHeadBack`,
  `stepTailForward(preserving:)`, `setVisibleWindow(containing:)`,
  `shiftVisibleHeadAfterPrepending`) exist on `ACPTranscript` as used by the
  existing `ACPTranscriptWindowTests`.
- **If Task 2 does not fully resolve it** (i.e. manual validation still shows
  overlap): the container is no longer the cause. Fall back to keying the
  stack with a window generation that increments on `stepHeadBack` so a
  reveal forces a fresh layout instead of an in-place top insertion — but do
  not add that speculatively (YAGNI).

## Follow-ups spotted (out of scope)

- `ACPSession.apply(.toolCall)` (`ACPSession.swift:413`) appends
  unconditionally with no `toolCallId` merge guard, unlike text chunks' replay
  suppression. Store scan is clean today, but a cheap upsert guard via
  `transcript.toolCallIndex(toolCallId:)` would harden ForEach identity
  against any future replay leak.
- The hydration + `session/load` double-render (deferred after #404) remains
  open and adjacent to, but distinct from, this layout bug.
