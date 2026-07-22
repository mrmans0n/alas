# Diff Comment Composer Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every gutter-created diff comment composer acquire keyboard focus immediately, including when an existing composer moves to another line.

**Architecture:** Keep `ReviewDraftComposerTextEditor` as the single AppKit focus owner, but trigger focus with an explicit request generation instead of relying only on a persistent `FocusState<Bool>`. Each diff surface increments its generation for every gutter selection, and the shared coordinator fulfills the latest request after the text view is attached on the next main-loop turn.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, Swift Testing

---

## File Structure

- `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`: shared composer representable, deferred focus coordinator, and unified review-surface request generation.
- `Alas/Sources/Center/DiffTabView.swift`: standalone staged/unstaged diff request generation.
- `AlasTests/DiffReviewSurfaceTests.swift`: AppKit-hosted shared-editor regression tests.
- `AlasTests/DiffPaneViewTests.swift`: standalone diff gutter integration assertion if its existing harness is the more direct place to exercise `DiffTabView`.

### Task 1: Make Shared Composer Focus Requests Durable

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift:1325-1455`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Write the failing AppKit focus regression test**

Add a serialized, main-actor test that hosts the real representable in an `NSWindow`. Use a small test-only SwiftUI harness with `@State var focusRequestGeneration`, `@FocusState var focused`, the real `ReviewDraftComposerTextEditor`, and an accessibility-identified button that increments the generation. Mount the window, issue generation `1`, drain the main actor, and assert that the hosted `NSTextView` is `window.firstResponder`. Then make a sibling `NSTextField` first responder, increment the generation, drain again, and assert that the text view regained first-responder status.

The harness must call the desired API explicitly:

```swift
ReviewDraftComposerTextEditor(
    text: $text,
    theme: theme,
    isFocused: $focused,
    focusRequestGeneration: focusRequestGeneration,
    onSave: {},
    onCancel: {}
)
```

Use a helper that yields at least twice to let both SwiftUI reconciliation and the deferred AppKit request finish. Keep the window alive for the whole assertion and close it with `defer`.

- [ ] **Step 2: Run the focused test to verify red**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  test -only-testing:AlasTests/DiffReviewSurfaceTests -quiet
```

Expected: the new test fails against the current synchronous focus behavior or fails to compile because the explicit request-generation contract is absent. Confirm the failure is specifically caused by the missing behavior/API before continuing.

- [ ] **Step 3: Add request-driven deferred focus to the shared editor**

Add `let focusRequestGeneration: Int` to `ReviewDraftComposerTextEditor`. In its coordinator, track the last fulfilled generation and a cancellable scheduled `Task<Void, Never>?`. Replace direct synchronous `makeFirstResponder` calls with a method that:

```swift
@MainActor
func scheduleFocusRequestIfNeeded() {
    let generation = parent.focusRequestGeneration
    guard generation > 0,
          generation != lastFulfilledFocusRequestGeneration
    else { return }

    scheduledFocusTask?.cancel()
    scheduledFocusTask = Task { @MainActor [weak self] in
        await Task.yield()
        guard !Task.isCancelled,
              let self,
              self.parent.focusRequestGeneration == generation,
              let textView = self.textView,
              let window = textView.window
        else { return }

        guard window.firstResponder === textView || window.makeFirstResponder(textView) else { return }
        self.lastFulfilledFocusRequestGeneration = generation
    }
}
```

Call this method from `updateNSView` and from the text view's `viewDidMoveToWindow` callback. Preserve `textDidBeginEditing` and `textDidEndEditing` so the existing focus binding still reflects actual focus. Cancel the scheduled task when the representable dismantles or when the coordinator is deinitialized.

All existing non-gutter call sites must pass `focusRequestGeneration: 0`; their current `.onAppear` focus binding behavior stays intact. Preserve that legacy binding-triggered path with a deferred request as needed so editing an existing draft does not regress.

- [ ] **Step 4: Run the focused test to verify green**

Run the Task 1 command again. Expected: the new initial-focus and refocus assertions pass, with no failures in `DiffReviewSurfaceTests`.

- [ ] **Step 5: Review the Task 1 diff**

Run `git diff --check` and inspect the full diff. Confirm there is one focus scheduler, stale generations cannot steal focus, scheduled work is cancelled, and focus reporting remains separate from focus-request intent.

- [ ] **Step 6: Commit Task 1**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift AlasTests/DiffReviewSurfaceTests.swift
git commit -m "fix(diff): defer comment composer focus"
```

### Task 2: Emit a Fresh Request From Every Diff Gutter Surface

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift:115-195,680-790,913-932`
- Modify: `Alas/Sources/Center/DiffTabView.swift:120-160,680-735,850-870`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`
- Test: `AlasTests/DiffPaneViewTests.swift` only if needed for direct standalone diff coverage

- [ ] **Step 1: Add failing surface-level request assertions**

Exercise the existing accessibility-enabled gutter selection path in the unified file-section harness and the standalone diff harness. For each surface, press one gutter comment control, assert the composer text view becomes first responder, move first responder away, press a different gutter comment control, and assert that the relocated composer text view regains focus.

If the standalone view cannot be hosted without unrelated services, extract only the request transition into this internal helper and test it directly from both surface test files:

```swift
struct DiffCommentComposerFocusRequest: Equatable {
    private(set) var generation = 0

    mutating func request() {
        generation &+= 1
    }
}
```

The preferred test remains the real gutter-to-first-responder path; use the helper only where the existing view harness makes that impractical.

- [ ] **Step 2: Run the surface tests to verify red**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  test -only-testing:AlasTests/DiffReviewSurfaceTests \
  -only-testing:AlasTests/DiffPaneViewTests -quiet
```

Expected: relocation does not produce a new explicit request in both current surfaces, so the new assertion fails for that reason.

- [ ] **Step 3: Wire the unified review surface**

Add `@State private var draftComposerFocusRequestGeneration = 0` to `DiffReviewFileSection`. Centralize both `onReviewLineSelected` closures through one method:

```swift
private func beginPendingDraft(at anchor: DiffReviewLineAnchor) {
    pendingDraftAnchor = anchor
    pendingDraftBody = ""
    draftComposerFocusRequestGeneration &+= 1
}
```

Pass the generation to `ReviewDraftComposerTextEditor`. Remove the redundant pending-anchor `onChange` and composer `onAppear` assignments that attempted to initiate gutter focus through the Boolean binding. Keep `clearPendingDraft()` resetting actual focus state.

- [ ] **Step 4: Wire the standalone diff surface**

Make the same state, helper, call-site replacement, and editor argument changes in `DiffTabView`. Ensure `clearPendingDraft()` also resets `draftComposerFocused = false`, matching the unified surface.

- [ ] **Step 5: Run focused tests to verify green**

Run the Task 2 command again. Expected: all `DiffReviewSurfaceTests` and `DiffPaneViewTests` pass.

- [ ] **Step 6: Run required project verification**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: project generation succeeds, build exits `0`, and the complete test suite reports no failures.

- [ ] **Step 7: Review and commit Task 2**

Run `git diff --check`, inspect `git diff`, and confirm both gutter paths call the same per-surface helper for every selection. Then commit:

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift \
  Alas/Sources/Center/DiffTabView.swift AlasTests/DiffReviewSurfaceTests.swift \
  AlasTests/DiffPaneViewTests.swift
git commit -m "fix(diff): focus gutter comment composers"
```
