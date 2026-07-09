# Draft Commit Diff Re-render Live-lock Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop the main-thread live-lock (beachball) that occurs when a Draft Commit tab shows a large staged diff while an agent/build continuously writes files in the worktree.

**Architecture:** Three complementary layers. (1) `RightPaneState.refresh()` stops republishing `@Observable` properties whose values did not change, so watcher-driven refreshes no longer invalidate every observing view. (2) `DraftCommitTabView` stops building a brand-new `DiffReviewLoadedSession` (with fresh closures) on every body evaluation; the session-with-actions is built once per loaded session and the loader keeps the previous instance when content is unchanged. (3) `DiffReviewFileSection` gains an explicit `Equatable` conformance comparing only render-relevant content (closures and bindings' identities excluded), so SwiftUI can skip the entire per-file subtree — hundreds of `NSViewRepresentable`s — when nothing visible changed.

**Tech Stack:** Swift 5.9 / SwiftUI (macOS), Swift Testing (`import Testing`), xcodegen/xcodebuild.

**Root cause evidence:** `/private/tmp/claude-502/-Users-nacho-lopez/47539476-4410-47be-acfe-323077aa0bd3/scratchpad/alas_sample.txt` — 5s sample fully inside one `GraphHost.flushTransactions()`, dominated by `PlatformViewChild.updateValue` → `AppKitPlatformViewHost.updateNestedHosts`/`coreUpdateEnvironment`, `DiffPaneView.body`, `DiffDisplayRow` copy/equality churn, plus `DraftCommitTabView.sessionWithActions` frames. Trigger chain: `WorktreeWatcher` (≤2s cadence under agent writes) → `RightPaneState.refresh()` unconditional `self.changes = entries` → `DraftCommitTabView.body` (reads `rps.changes`) → new `sessionWithActions` closures → non-equatable subtree fully re-diffed (seconds per pass) → transactions queue faster than they drain.

**Stale-closure risk accepted (documented):** with the Equatable gate, closures captured by an older body generation stay installed while `==` reports equal. All such closures either read view state through `@State`/`@Observable` storage (always fresh) or capture immutable per-file values (paths, ids) that are covered by the content comparison. The only visible effect: hunk-header button enabled-state derived from `busy` may lag for the duration of a git mutation, and those handlers already `guard !busy`.

---

### Task 1: Content equality for review session models

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewModels.swift` (after `DiffReviewLoadedSession`, line ~284)
- Test: `AlasTests/DiffReviewModelsTests.swift` (append)

**Step 1: Write failing tests** (Swift Testing, follow existing style in `DiffReviewModelsTests.swift`)

Cases:
- Two `DiffReviewFileSectionModel`s with identical summary/parsedDiff/displayModel/placeholder but *different* closure instances and different `contextProvider` UUIDs → `hasSameRenderableContent` is `true` when action presence matches.
- Same but one has `stagedMutationActions = nil` vs non-nil → `false`.
- One has `openFile` nil vs non-nil → `false`.
- Different `displayModel` rows → `false`.
- `DiffReviewLoadedSession.hasSameRenderableContent(as:)`: equal-content sessions → `true`; different file count or any file differing → `false`.

**Step 2: Run tests, verify they fail to compile / fail.**

**Step 3: Implement**

```swift
extension DiffReviewStagedMutationActions {
    /// Presence-only signature: closure identity is not comparable, but which
    /// actions exist affects rendered buttons.
    var renderablePresence: (Bool, Bool, Bool) {
        (unstageFile != nil, unstageHunk != nil, isHunkUnstageEnabled != nil)
    }
}

extension DiffReviewFileSectionModel {
    /// True when this model renders identically to `other`. Ignores closure
    /// identity (openFile, contextProvider.snapshot, stagedMutationActions
    /// bodies) — only content and action *presence* are compared.
    func hasSameRenderableContent(as other: DiffReviewFileSectionModel) -> Bool {
        summary == other.summary
            && parsedDiff == other.parsedDiff
            && displayModel == other.displayModel
            && placeholderMessage == other.placeholderMessage
            && (openFile == nil) == (other.openFile == nil)
            && (contextProvider == nil) == (other.contextProvider == nil)
            && (stagedMutationActions?.renderablePresence ?? (false, false, false))
                == (other.stagedMutationActions?.renderablePresence ?? (false, false, false))
    }
}

extension DiffReviewLoadedSession {
    func hasSameRenderableContent(as other: DiffReviewLoadedSession) -> Bool {
        guard summary == other.summary, files.count == other.files.count else { return false }
        return zip(files, other.files).allSatisfy { $0.hasSameRenderableContent(as: $1) }
    }
}
```

**Step 4: Run tests → PASS.**

**Step 5: Commit** `perf(review): add renderable-content equality to review session models`

---

### Task 2: Equatable gate on DiffReviewFileSection

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift` (add `Equatable` conformance)
- Modify: `Alas/Sources/Center/Diff/DiffPaneLSP.swift` (add `rendersEqual` helper)
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift:305` (wrap in `.equatable()`)
- Test: `AlasTests/DiffReviewFileSectionEqualityTests.swift` (new)

**Step 1: Write failing tests**

- Two sections with same content model instance, same flags, *different* closure instances → `==` true.
- Flip each render-relevant input one at a time (focusedFeedbackID, layoutMode binding value, wrapLines, showWhitespace, codeFontSize, threads, annotations, canReply, allowsDraftCommentCreation, draftComments, inlineFeedback, showsSourceBadge, reviewFeedbackTarget) → `==` false for each.
- `DiffPaneLSPContext.rendersEqual`: nil/nil true; nil/some false; same worktreeId+relativePath+language+same `lsp` instance but different `openTarget` closures → true; different relativePath → false.

**Step 2: Run → fail.**

**Step 3: Implement**

In `DiffPaneLSP.swift`:

```swift
extension DiffPaneLSPContext {
    /// Render-relevant equality: ignores the openTarget closure.
    static func rendersEqual(_ lhs: DiffPaneLSPContext?, _ rhs: DiffPaneLSPContext?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return l.worktreeId == r.worktreeId
                && l.relativePath == r.relativePath
                && l.language == r.language
                && l.lsp === r.lsp
        default:
            return false
        }
    }
}
```

In `DiffReviewFileSection.swift`:

```swift
extension DiffReviewFileSection: Equatable {
    /// Render-relevant equality so SwiftUI can skip this subtree when a parent
    /// body storm did not change anything visible. Closure inputs (actions,
    /// selection callbacks) are intentionally excluded: they read live state
    /// through @State/@Observable storage, so an older generation stays correct.
    static func == (lhs: DiffReviewFileSection, rhs: DiffReviewFileSection) -> Bool {
        lhs.file.hasSameRenderableContent(as: rhs.file)
            && lhs.inlineFeedback == rhs.inlineFeedback
            && lhs.focusedFeedbackID == rhs.focusedFeedbackID
            && lhs.inlineFeedbackScrollTargetID == rhs.inlineFeedbackScrollTargetID
            && lhs.draftComments == rhs.draftComments
            && lhs.focusedDraftCommentID == rhs.focusedDraftCommentID
            && lhs.layoutMode == rhs.layoutMode
            && lhs.wrapLines == rhs.wrapLines
            && lhs.showWhitespace == rhs.showWhitespace
            && lhs.codeFontFamily == rhs.codeFontFamily
            && lhs.codeFontSize == rhs.codeFontSize
            && lhs.showsSourceBadge == rhs.showsSourceBadge
            && DiffPaneLSPContext.rendersEqual(lhs.lspContext, rhs.lspContext)
            && lhs.allowsDraftCommentCreation == rhs.allowsDraftCommentCreation
            && lhs.reviewFeedbackTarget == rhs.reviewFeedbackTarget
            && lhs.threads == rhs.threads
            && lhs.annotations == rhs.annotations
            && lhs.canReply == rhs.canReply
            && lhs.canResolve == rhs.canResolve
            && lhs.canAddToReview == rhs.canAddToReview
    }
}
```

Note: `lhs.layoutMode` reads the binding's `wrappedValue`. `@State`/`@StateObject`/`@FocusState`/`@Environment` properties are excluded — SwiftUI tracks those dependencies independently of `==`.

In `DiffReviewSurface.fileSection(_:)` wrap the returned view: `DiffReviewFileSection(...) .equatable()` — check other `DiffReviewFileSection(` call sites (`grep -rn "DiffReviewFileSection(" Alas/Sources`) and wrap them too.

**Step 4: Run tests → PASS.**

**Step 5: Commit** `perf(review): equality-gate DiffReviewFileSection subtree`

---

### Task 3: Stop rebuilding the session per body eval in DraftCommitTabView

**Files:**
- Modify: `Alas/Sources/Center/Commit/DraftCommitTabView.swift:69-87` (computed `sessionWithActions` → built on load), `:306-325` (`loadStagedSession`)
- Test: existing `AlasTests/DiffReviewStagedMutationActionsTests.swift` must still pass; content-equality path covered by Task 1 tests.

**Step 1: Implement**

- Add `@State private var sessionWithActions: DiffReviewLoadedSession?`.
- Extract the current overlay body into `private func overlayingActions(on session: DiffReviewLoadedSession) -> DiffReviewLoadedSession` (same closure bodies; closures capture `self` and read `busy` through `@State` storage, so values stay fresh without per-render recreation).
- In `loadStagedSession()`, after loading:

```swift
guard !Task.isCancelled, stagedKey == token else { return }
if let existing = stagedSession, existing.hasSameRenderableContent(as: session) {
    // Same visible content: keep existing instances so downstream
    // equality checks hit the O(1) same-storage fast path.
} else {
    stagedSession = session
    sessionWithActions = overlayingActions(on: session)
    synchronizeSelection(with: session)
}
```

(Keep the error path clearing both `stagedSession` and `sessionWithActions`.)

- `stagedDiffBody` uses the `@State` `sessionWithActions` instead of the computed property. Delete the computed property.

**Step 2: Build + run the full test suite.**

**Step 3: Commit** `perf(commit): build draft-commit review session once per load`

---

### Task 4: Publish-only-on-change in RightPaneState.refresh()

**Files:**
- Modify: `Alas/Sources/Right/RightPaneState.swift:467-475` (and nearby assignments)

**Step 1: Implement** — guard the `@Observable` assignments that fire on every watcher refresh:

```swift
if self.upstreamRef != resolvedUpstream?.ref { self.upstreamRef = resolvedUpstream?.ref }
if self.changes != entries { self.changes = entries }
self.reconcileStashCaches(with: stashes)
if self.stashes != stashes { self.stashes = stashes }
self.changesGeneration += 1   // keep unconditional: consumers treat it as "a refresh happened"
if self.indexFingerprint != indexFingerprint { self.indexFingerprint = indexFingerprint }
let mergedTree = Self.preservingLazyChildren(fresh: tree, previous: self.fileTree)
if self.fileTree != mergedTree { self.fileTree = mergedTree }
if self.commits != commits { self.commits = commits }
if self.comparisonRef != ref { self.comparisonRef = ref }
if self.currentBranch != currentBranch { self.currentBranch = currentBranch }
if self.currentHeadSHA != headSHA { self.currentHeadSHA = headSHA }
```

Only guard properties whose types are already `Equatable` (verify `stashes` element and `fileTree` node types during implementation; skip any that aren't — do NOT add new conformances here). Keep `commitRemote`/`primaryCommitRemote` as-is unless trivially Equatable.

**Step 2: Run the RightPaneState test files** (`RightPaneStateFileTreeTests`, `RightPaneStateSyncStatusTests`, etc.) → PASS.

**Step 3: Commit** `perf(right-pane): skip republishing unchanged observable state on refresh`

---

### Task 5: Full verification

- `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
- `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`
- Manual sanity (if feasible): open Draft Commit tab with staged changes, touch files in the worktree in a loop (`while true; do date >> scratch.txt; sleep 0.3; done`), confirm CPU stays low and UI responsive.
