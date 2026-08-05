# AppKit Transcript Logical Scrollbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the AppKit ACP transcript a stable, transcript-wide native scrollbar while rendering no more than the existing 90-message window.

**Architecture:** Keep the measured AppKit document bounded and decouple the native `NSScroller` metrics from its pixel height. A pure logical-scroll model maps global message indices to native knob values; `ACPTranscript` supplies a tail-hydration index offset; the AppKit coordinator commits a bounded page jump only after the user releases the scroller.

**Tech Stack:** Swift 5.9+, AppKit `NSScrollView`/`NSScroller`, SwiftUI hosting, Observation via Combine, Swift Testing.

## Global Constraints

- Apply only to the feature-flagged AppKit transcript; do not change the legacy SwiftUI scrollbar behavior.
- Use 96 logical points per message and the existing 30-row page / 90-row maximum window.
- Preserve native AppKit scrollbar appearance, accessibility, track clicks, wheel scrolling, and tail-follow behavior.
- Keep persisted schemas and wire formats unchanged.
- Keep code, comments, logs, and UI strings in English.

---

### Task 1: Logical history indices and bounded target windows

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPTranscript.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Test: `AlasTests/ACP/Session/ACPTranscriptWindowTests.swift`

**Interfaces:**
- Produces: `ACPTranscript.messageIndexOffset: Int`, `logicalMessageCount: Int`, `globalIndex(forLocalIndex:)`, `localIndex(forGlobalIndex:)`, `setVisibleWindow(around:)`.
- Consumes: existing `tailWindow`, `maxVisibleRows`, `setVisibleWindow(head:tail:)`, and tail-first hydration/prepend paths.

- [ ] **Step 1: Add failing transcript-index tests**

  Add Swift Testing cases proving that a 30-message materialized tail with offset 170 reports 200 logical messages, maps local index 0 to global 170, rejects global 169 as unavailable, and maps global 199 to local 29. Add cases proving `setVisibleWindow(around: 100)` selects `70..<160`, while targets near either end clamp the window to `0..<90` and `110..<200`.

- [ ] **Step 2: Run the focused tests and confirm failure**

  Run:

  ```bash
  ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTranscriptWindowTests test
  ```

  Expected: compilation fails because the logical-index API does not exist.

- [ ] **Step 3: Implement logical indices atomically with transcript publication**

  Add a non-published, `private(set)` message-index offset defaulting to zero. Set it before replacing the initial hydrated tail, decrement it before a prepend publishes the expanded `messages` array, and reset it for ordinary full replacements. Derive the logical count as `messageIndexOffset + messages.count`; make conversions bounds-checked. Implement `setVisibleWindow(around:)` so the target has up to `tailWindow` older rows preloaded and the result never exceeds `maxVisibleRows`.

- [ ] **Step 4: Run the transcript tests and confirm success**

  Run the focused command from Step 2. Expected: all `ACPTranscriptWindowTests` pass.

- [ ] **Step 5: Commit the transcript model slice**

  ```bash
  git add Alas/Sources/ACP/Session/ACPTranscript.swift Alas/Sources/ACP/Session/ACPSessionManager.swift AlasTests/ACP/Session/ACPTranscriptWindowTests.swift
  git commit -m "feat(acp): expose logical transcript history indices"
  ```

### Task 2: Pure logical scrollbar mapping

**Files:**
- Create: `Alas/Sources/ACP/UI/Scroller/ACPTranscriptLogicalScrollModel.swift`
- Create: `AlasTests/ACP/UI/ACPTranscriptLogicalScrollModelTests.swift`

**Interfaces:**
- Produces: `ACPTranscriptLogicalScrollModel` with `logicalPointsPerMessage = 96`, `metrics(totalCount:viewportHeight:topGlobalIndex:isAtTail:)`, and `targetGlobalIndex(value:totalCount:viewportHeight:)`.
- Consumes: global indices from Task 1.

- [ ] **Step 1: Add failing pure mapping tests**

  Cover empty and short transcripts, top and bottom endpoints, midpoint rounding/clamping, viewport resizing, and genuine count growth. Assert that changing rendered-window membership or measured pixel heights is not an input and therefore cannot change knob proportion or value for identical logical inputs.

- [ ] **Step 2: Run the focused tests and confirm failure**

  Run:

  ```bash
  ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTranscriptLogicalScrollModelTests test
  ```

  Expected: compilation fails because the model does not exist.

- [ ] **Step 3: Implement the pure model**

  Define an equatable `Metrics` value containing normalized `value`, `knobProportion`, and `logicalViewportMessages`. Compute the logical viewport as `max(1, viewportHeight / 96)`, clamp the knob to `0...1`, force tail-follow to value `1`, and map release values across `max(0, totalCount - logicalViewportMessages)`.

- [ ] **Step 4: Regenerate the project and run the focused tests**

  Run `rtk xcodegen`, then the command from Step 2. Expected: tests pass and the new source/test files belong to their targets.

- [ ] **Step 5: Commit the logical model slice**

  ```bash
  git add project.yml Alas.xcodeproj Alas/Sources/ACP/UI/Scroller/ACPTranscriptLogicalScrollModel.swift AlasTests/ACP/UI/ACPTranscriptLogicalScrollModelTests.swift
  git commit -m "feat(acp): add logical transcript scrollbar metrics"
  ```

### Task 3: Native release-to-jump AppKit coordination

**Files:**
- Modify: `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScrollerView.swift`
- Modify: `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift`
- Test: `AlasTests/ACP/UI/ACPTranscriptScrollerPolicyTests.swift`
- Test: `AlasTests/ACP/UI/ACPTranscriptScrollerScrollBackTests.swift`

**Interfaces:**
- Consumes: Task 1 logical indices/window selection and Task 2 metrics/mapping.
- Produces: `ACPTranscriptScrollerView.onLogicalScrollCommit`, `setLogicalScrollerMetrics(_:)`, coordinator pending-target resolution, and bounded AppKit pagination.

- [ ] **Step 1: Add failing native-policy tests**

  Assert the installed vertical `NSScroller` is non-continuous; logical metrics override physical document metrics; intermediate value changes do not navigate; a commit maps to and aligns a loaded historical row; value `1` restores tail-follow; an unavailable pre-backfill target remains pending and resolves after prepend; and repeated head/tail steps never exceed `maxVisibleRows`.

- [ ] **Step 2: Run focused AppKit tests and confirm failure**

  Run:

  ```bash
  ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTranscriptScrollerPolicyTests -only-testing:AlasTests/ACPTranscriptScrollerScrollBackTests test
  ```

  Expected: compilation or assertions fail because logical scroller coordination is absent.

- [ ] **Step 3: Install and maintain logical native metrics**

  Keep a native vertical `NSScroller`, set `isContinuous = false`, and route its action to a release callback without custom drawing. After every physical scroll report, layout, and host update, overwrite its value and knob proportion from the pure logical model so `reflectScrolledClipView` cannot leak bounded-document metrics to the user.

- [ ] **Step 4: Implement loaded and queued page jumps**

  In the coordinator, special-case a committed value of `1` to reset the tail window, scroll to bottom after reconciliation, and resume tail-follow. For historical values, pause/freeze tail-follow, convert the global target to a local index, select a bounded window around it, and retain the target stable id until the next apply can align that row at the viewport top. If conversion fails because the global target precedes `messageIndexOffset`, retain the global index and retry on subsequent transcript updates; clamp against the current logical count before retrying.

- [ ] **Step 5: Bound wheel and trackpad pagination**

  Replace the AppKit-only unbounded `stepHeadBack(boundTail: false)` and `stepTailForward(..., boundHead: false)` calls with bounded window steps. Keep the existing reconciler anchor capture/restore and pending-head-step latch so simultaneous insertion/removal does not move the visible row or enqueue duplicate pages.

- [ ] **Step 6: Run focused tests and fix regressions**

  Run the command from Step 2 plus:

  ```bash
  ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTranscriptWindowTests -only-testing:AlasTests/ACPTranscriptScrollerReconcilerTests test
  ```

  Expected: all selected suites pass.

- [ ] **Step 7: Commit AppKit integration**

  ```bash
  git add Alas/Sources/ACP/UI/Scroller/ACPTranscriptScrollerView.swift Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift AlasTests/ACP/UI/ACPTranscriptScrollerPolicyTests.swift AlasTests/ACP/UI/ACPTranscriptScrollerScrollBackTests.swift
  git commit -m "feat(acp): stabilize the AppKit transcript scrollbar"
  ```

### Task 4: Full verification

**Files:**
- Modify only files required by concrete failures attributable to this change.

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: a fully verified AppKit-only feature with no new public persistence or wire contract.

- [ ] **Step 1: Regenerate and inspect generated-project drift**

  Run `rtk xcodegen` and `git status --short`. Commit generated files only if source membership changed them.

- [ ] **Step 2: Run formatting lint**

  Run the repository SwiftFormat lint command and correct only violations introduced by this branch.

- [ ] **Step 3: Run the required quiet build**

  ```bash
  ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
  ```

  Expected: exit status 0.

- [ ] **Step 4: Run the complete required test suite**

  ```bash
  ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
  ```

  Expected: exit status 0 with no failures attributable to this change.

- [ ] **Step 5: Review the final diff and commit verification fixes**

  Confirm the legacy SwiftUI path and persistence schema are untouched, no render window exceeds 90 messages, and no placeholders or agent attribution appear. Commit any necessary verification fixes with a focused conventional message.
