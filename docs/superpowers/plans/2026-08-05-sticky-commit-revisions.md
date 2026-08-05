# Sticky Commit Revisions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let commit-detail tabs and dedicated commit review sessions follow a logical single-commit Git expression while loading and displaying only immutable resolved snapshots.

**Architecture:** A shared `TrackedRevision` model owns the expression, branch baseline, last complete SHA, and pending checkout candidate. Existing Git watchers publish a per-worktree generation; commit and review views resolve on that signal, load the candidate SHA in a guarded shadow generation, and atomically publish only complete snapshots. Fixed-SHA targets keep their existing persistence and behavior.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit on macOS, Swift Observation, Swift Testing, XcodeGen, existing `GitService`, `TabsManager`, and review-session persistence.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Accept one Git commit-ish expression; ranges and branch-comparison reviews remain immutable.
- Normalize expressions only by trimming leading and trailing whitespace.
- Do not add per-tab polling or new dependencies.
- Keep the last complete snapshot visible during refresh and after resolution/load failures.
- Pause only HEAD-dependent expressions on a branch checkout; named refs keep following independently.
- Preserve drafts and handoff history, but clear the verdict and return to `active` when the resolved SHA changes.
- Preserve legacy fixed-SHA decoding and behavior.
- Tests use Swift Testing (`import Testing`), not XCTest.

---

### Task 1: Tracked revision domain model and transition policy

**Files:**
- Create: `Alas/Sources/Center/Commit/TrackedRevision.swift`
- Modify: `AlasTests/CommitTabStateTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `GitService.resolveRevision(at:ref:)` and `GitService.currentBranch(worktreePath:)`.
- Produces: `TrackedRevision`, `TrackedRevisionCandidate`, `TrackedRevisionTransition`, `TrackedRevisionPolicy.evaluate(current:candidate:)`, and `TrackedRevisionResolver.resolve(at:expression:)`.

- [ ] **Step 1: Write failing model and policy tests**

Add tests covering whitespace trimming, HEAD-dependency classification, same-branch movement, named-ref movement across checkout, HEAD checkout pause, unchanged SHA metadata refresh, and pending checkout acceptance:

```swift
@Test func headRelativeRevisionPausesWhenBranchChanges() throws {
    let current = try #require(TrackedRevision(
        expression: " HEAD~3 ", baselineBranch: "feature",
        resolvedSHA: "old"
    ))
    let candidate = TrackedRevisionCandidate(branch: "main", sha: "new")

    #expect(TrackedRevisionPolicy.evaluate(current: current, candidate: candidate)
        == .pause(current.withPendingCheckout(candidate)))
}

@Test func namedRefFollowsAcrossUnrelatedCheckout() throws {
    let current = try #require(TrackedRevision(
        expression: "topic~2", baselineBranch: "feature",
        resolvedSHA: "old"
    ))
    let candidate = TrackedRevisionCandidate(branch: "main", sha: "new")

    #expect(TrackedRevisionPolicy.evaluate(current: current, candidate: candidate)
        == .follow(current.resolving(candidate)))
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/CommitTabStateTests test
```

Expected: compilation fails because the tracked-revision types do not exist.

- [ ] **Step 3: Implement the shared model and live resolver**

Create the following contract:

```swift
struct TrackedRevisionCandidate: Codable, Equatable, Hashable, Sendable {
    let branch: String
    let sha: String
}

struct TrackedRevision: Codable, Equatable, Hashable, Sendable {
    let expression: String
    var baselineBranch: String
    var resolvedSHA: String
    var pendingCheckout: TrackedRevisionCandidate?

    init?(expression: String, baselineBranch: String, resolvedSHA: String)
    var dependsOnWorktreeHEAD: Bool { get }
    func resolving(_ candidate: TrackedRevisionCandidate) -> Self
    func withPendingCheckout(_ candidate: TrackedRevisionCandidate) -> Self
    func acceptingPendingCheckout() -> Self?
}

enum TrackedRevisionTransition: Equatable {
    case unchanged(TrackedRevision)
    case follow(TrackedRevision)
    case pause(TrackedRevision)
}

enum TrackedRevisionPolicy {
    static func evaluate(
        current: TrackedRevision,
        candidate: TrackedRevisionCandidate
    ) -> TrackedRevisionTransition
}

struct TrackedRevisionResolver {
    var resolve: (URL, String) async throws -> String
    var branch: (URL) async throws -> String

    static let live = TrackedRevisionResolver(
        resolve: { try await GitService().resolveRevision(at: $0, ref: $1) },
        branch: { try await GitService().currentBranch(worktreePath: $0) }
    )

    func resolve(at worktreePath: URL, expression: String) async throws
        -> TrackedRevisionCandidate
}
```

`dependsOnWorktreeHEAD` recognizes expressions beginning with `HEAD` or `@` after trimming. `evaluate` pauses only when that flag is true, the branch changed, and the SHA changed. A same-SHA candidate clears pending state and adopts the candidate branch without reloading.

- [ ] **Step 4: Regenerate the project and rerun tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/CommitTabStateTests test
```

Expected: all `CommitTabStateTests` pass.

- [ ] **Step 5: Commit the domain model**

```bash
git add Alas/Sources/Center/Commit/TrackedRevision.swift \
  AlasTests/CommitTabStateTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(review): add tracked revision model"
```

---

### Task 2: Persist fixed and followed commit tabs with stable identity

**Files:**
- Modify: `Alas/Sources/Center/Tab.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `AlasTests/CommitTabStateTests.swift`
- Modify: `AlasTests/TabsManagerTests.swift`

**Interfaces:**
- Consumes: `TrackedRevision` from Task 1.
- Produces: `CommitRevision`, stable `CommitTabState`, and `TabsManager.updateCommit(worktreeId:tabId:mutate:)`.

- [ ] **Step 1: Add failing persistence and manager tests**

Cover legacy JSON decoding, a followed round-trip, stable ID across SHA movement and stopping, and mutation without tab reorder:

```swift
@Test func legacyCommitJSONDecodesAsFixedRevision() throws {
    let json = #"{"id":"commit:wt:abc","worktreeId":"wt","sha":"abc","title":"Old"}"#
    let state = try JSONDecoder().decode(CommitTabState.self, from: Data(json.utf8))
    #expect(state.revision == .fixed(sha: "abc"))
    #expect(state.id == "commit:wt:abc")
}

@Test func trackedCommitUpdatePreservesTabIdentityAndOrder() {
    let originalID = manager.tabs(forWorktree: "wt")[0].id
    _ = manager.updateCommit(worktreeId: "wt", tabId: originalID) {
        $0.revision = .following(tracked.resolving(.init(branch: "feature", sha: "new")))
        $0.title = "new Subject"
    }
    #expect(manager.tabs(forWorktree: "wt")[0].id == originalID)
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/CommitTabStateTests \
  -only-testing:AlasTests/TabsManagerTests test
```

Expected: tests fail because `CommitRevision` and `updateCommit` are missing.

- [ ] **Step 3: Implement custom Codable compatibility and stable updates**

Replace the immutable SHA-only state with:

```swift
enum CommitRevision: Codable, Equatable, Hashable, Sendable {
    case fixed(sha: String)
    case following(TrackedRevision)

    var resolvedSHA: String { get }
    var tracked: TrackedRevision? { get }
}

struct CommitTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    var revision: CommitRevision
    var title: String

    var sha: String { revision.resolvedSHA }
    init(worktreeId: String, sha: String, title: String)
    init(worktreeId: String, trackedRevision: TrackedRevision, title: String)
}
```

Use a custom decoder that reads `revision` when present and otherwise maps the legacy `sha` key to `.fixed`. Encode `revision` and retain `sha` as a compatibility mirror for downgrade resilience. The tracked initializer derives a deterministic initial ID from worktree plus a SHA-256 digest of the expression; subsequent mutations retain the stored ID.

Add:

```swift
@discardableResult
func updateCommit(
    worktreeId: String,
    tabId: TabID,
    mutate: (inout CommitTabState) -> Void
) -> Tab?
```

Persist once after replacing the matching `.commit` element. Update commit open/focus searches to compare `state.sha`, not IDs.

- [ ] **Step 4: Rerun focused tests**

Expected: both suites pass, including the unchanged legacy ID assertions.

- [ ] **Step 5: Commit commit-tab persistence**

```bash
git add Alas/Sources/Center/Tab.swift Alas/Sources/Center/TabsManager.swift \
  AlasTests/CommitTabStateTests.swift AlasTests/TabsManagerTests.swift
git commit -m "feat(review): persist followed commit tabs"
```

---

### Task 3: Add tracked commit review targets and atomic draft migration

**Files:**
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftModels.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionModels.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift`
- Modify: `AlasTests/ReviewDraftCommentStoreTests.swift`
- Modify: `AlasTests/ReviewSessionModelsTests.swift`
- Modify: `AlasTests/ReviewSessionLoaderTests.swift`

**Interfaces:**
- Consumes: `TrackedRevision` and existing commit review loader.
- Produces: `.trackedCommit`, `ReviewDraftSessionID.trackedCommit(...)`, `ReviewDraftCommentStore.migrate(from:to:)`, and record retarget helpers.

- [ ] **Step 1: Write failing target, migration, and loader tests**

```swift
@Test func trackedCommitIdentityUsesExpressionNotResolvedSHA() throws {
    let revision = try #require(TrackedRevision(
        expression: "HEAD~3", baselineBranch: "feature", resolvedSHA: "aaa"
    ))
    let first = ReviewSessionTarget.trackedCommit(
        worktreeID: "wt", repositoryPath: URL(fileURLWithPath: "/repo"),
        revision: revision, title: "Review HEAD~3"
    )
    let second = first.updatingTrackedRevision(
        revision.resolving(.init(branch: "feature", sha: "bbb")),
        title: "Review rewritten commit"
    )
    #expect(first.id == second.id)
    #expect(first.draftSessionID == second.draftSessionID)
}

@Test func migrateMovesAndRekeysDraftsInOneWrite() throws {
    try store.save(comment(sessionID: oldID, id: "draft-1"))
    try store.migrate(from: oldID, to: newID)
    #expect(try store.load(sessionID: oldID).isEmpty)
    #expect(try store.load(sessionID: newID).single?.sessionID == newID)
}
```

Also assert that moving from resolved SHA `aaa` to `bbb` clears `verdict`, sets `status = .active`, preserves handoffs, and that `ReviewSessionLoader` passes only `bbb` to its commit loader.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ReviewDraftCommentStoreTests \
  -only-testing:AlasTests/ReviewSessionModelsTests \
  -only-testing:AlasTests/ReviewSessionLoaderTests test
```

- [ ] **Step 3: Implement tracked review identity and migration**

Add `.trackedCommit` to `ReviewDraftSourceKind`, `ReviewSessionTargetKind`, and `ReviewSessionTarget.Payload`. Define:

```swift
static func trackedCommit(
    worktreeID: String,
    repositoryPath: URL,
    revision: TrackedRevision,
    title: String
) -> ReviewSessionTarget

func updatingTrackedRevision(
    _ revision: TrackedRevision,
    title: String
) -> ReviewSessionTarget

func freezingTrackedRevision(title: String) -> ReviewSessionTarget?
```

The target and draft IDs use the normalized expression and never the resolved SHA. `revisionDescription` is `"<expression> -> <sha>"`; `sourceDescription` uses the same unambiguous pair.

Add record behavior:

```swift
func retargetingCommit(
    to target: ReviewSessionTarget,
    resolvedSHAChanged: Bool,
    now: Date
) -> ReviewSessionRecord
```

When `resolvedSHAChanged` is true, clear `verdict`, set `status = .active`, preserve handoffs, and update `updatedAt`.

Implement `ReviewDraftCommentStore.migrate(from:to:)` by reading one snapshot, removing the source array, rewriting every moved comment's `sessionID`, merging by comment ID with the moved value winning, then writing once.

Route `.trackedCommit` through the existing commit loader using only `revision.resolvedSHA`.

- [ ] **Step 4: Rerun focused tests**

Expected: all three suites pass.

- [ ] **Step 5: Commit tracked review persistence**

```bash
git add Alas/Sources/Center/ReviewWorkspace/ReviewDraftModels.swift \
  Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift \
  Alas/Sources/Center/ReviewWorkspace/ReviewSessionModels.swift \
  Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift \
  AlasTests/ReviewDraftCommentStoreTests.swift AlasTests/ReviewSessionModelsTests.swift \
  AlasTests/ReviewSessionLoaderTests.swift
git commit -m "feat(review): add followed review targets"
```

---

### Task 4: Publish Git revision-change generations from existing watchers

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Watch/GitEventFilter.swift`
- Modify: `Alas/Sources/SSH/RemoteProjectGitWatcher.swift`
- Modify: `AlasTests/AppStateCleanupTests.swift`
- Modify: `AlasTests/ProjectGitWatcherTests.swift`
- Modify: `AlasTests/SSH/RemoteWorktreePollTests.swift`

**Interfaces:**
- Consumes: existing `ProjectGitWatcher` and `RemoteProjectGitWatcher` callbacks.
- Produces: `AppState.revisionChangeGeneration(worktreeID:)` and internal generation bump helpers.

- [ ] **Step 1: Add failing generation tests**

Test that a worktree HEAD callback bumps only matching worktrees, while shared-ref movement bumps every worktree in the project. Expand `GitEventFilter` coverage so `refs/heads`, `refs/remotes`, and `refs/tags` all signal a revision change. Test that repeated callbacks monotonically increase, remote HEAD movement takes the topology path, and a remote helper Git event can signal revision movement even when `git worktree list` is otherwise unchanged.

```swift
@Test func headUpdateAdvancesMatchingWorktreeRevisionGeneration() async throws {
    let before = state.revisionChangeGeneration(worktreeID: worktree.id)
    state.handleProjectHeadUpdates(
        projectId: project.id,
        branchByWorktreePath: [worktree.path: worktree.branch]
    )
    #expect(state.revisionChangeGeneration(worktreeID: worktree.id) == before + 1)
}
```

- [ ] **Step 2: Run focused watcher tests and verify failure**

Run the three suites with `rtk xcodebuild ... test`; expect missing generation APIs.

- [ ] **Step 3: Implement observable per-worktree generations**

Add an observable dictionary and accessor:

```swift
private(set) var revisionChangeGenerations: [String: Int] = [:]

func revisionChangeGeneration(worktreeID: String) -> Int {
    revisionChangeGenerations[worktreeID, default: 0]
}
```

In `handleProjectHeadUpdates`, canonicalize callback paths, bump every matching worktree even when its branch label did not change, then retain the existing sidebar/GG invalidation behavior. Treat every non-lock path under `refs/` as a shared revision change and bump all current worktrees for the project before the existing asynchronous topology refresh; newly discovered worktrees start at zero.

Add `RemoteProjectGitWatcher.onRevisionChanged`. Invoke it for remote-helper `.git` events before the reconciliation tick, and wire it in `AppState` to bump all project worktree generations without forcing a second topology refresh. Remote poll HEAD deltas retain their existing topology callback, which also bumps generations.

- [ ] **Step 4: Rerun watcher tests**

Expected: focused local and remote watcher suites pass.

- [ ] **Step 5: Commit watcher generation wiring**

```bash
git add Alas/Sources/App/AppState.swift Alas/Sources/Watch/GitEventFilter.swift \
  Alas/Sources/SSH/RemoteProjectGitWatcher.swift AlasTests/AppStateCleanupTests.swift \
  AlasTests/ProjectGitWatcherTests.swift AlasTests/SSH/RemoteWorktreePollTests.swift
git commit -m "feat(review): signal tracked revision changes"
```

---

### Task 5: Centralize follow, edit, stop, and checkout-accept actions

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Center/TabBarView.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `Alas/Sources/Center/Commit/TrackedRevision.swift`
- Modify: `AlasTests/CommitTabStateTests.swift`
- Modify: `AlasTests/TabsManagerReviewSessionTests.swift`

**Interfaces:**
- Consumes: `TabsManager.updateCommit`, tracked review target helpers, and draft migration.
- Produces: `AppState.followRevision(worktreeID:tabID:expression:)`, `stopFollowingRevision(worktreeID:tabID:)`, `acceptTrackedRevisionCheckout(worktreeID:tabID:)`, and tab-context actions.

- [ ] **Step 1: Write failing retarget action tests**

Test the pure mutation seam for both tab kinds: fixed commit to followed, followed expression edit, followed commit to fixed, fixed review to followed with draft migration IDs, and pending checkout acceptance. Verify invalid/blank expressions leave state untouched.

- [ ] **Step 2: Run focused tests and verify failure**

Run `CommitTabStateTests` and `TabsManagerReviewSessionTests`; expect missing action helpers.

- [ ] **Step 3: Implement testable mutation helpers and AppKit prompt**

Add a helper returning explicit persistence work:

```swift
struct TrackedRevisionRetargetingResult {
    let record: ReviewSessionRecord
    let oldDraftSessionID: ReviewDraftSessionID
    let newDraftSessionID: ReviewDraftSessionID
}

enum TrackedRevisionRetargeter {
    static func follow(
        record: ReviewSessionRecord,
        revision: TrackedRevision,
        title: String,
        now: Date
    ) -> TrackedRevisionRetargetingResult?

    static func stop(
        record: ReviewSessionRecord,
        title: String,
        now: Date
    ) -> TrackedRevisionRetargetingResult?
}
```

AppState resolves the entered expression first, then applies either a commit-tab mutation or the review record + draft migration + tab title update. Use an `NSAlert` with one text field for header/context-menu entry; show validation failures with the existing warning alert path. Prefill an existing expression when editing and a first-parent `HEAD~N` suggestion when `GitService` can prove the displayed SHA equals that expression.

- [ ] **Step 4: Add tab-bar context actions**

Extend `TabBarView` with `onFollowRevision`, `onEditRevision`, and `onStopFollowingRevision` callbacks. Show these only for `.commit` and commit-kind `.reviewSession` tabs; the review-session capability is determined from its current record in `CenterPaneView`. Mirror the same AppState methods used by pane headers.

- [ ] **Step 5: Rerun focused tests**

Expected: retargeting and persistence tests pass.

- [ ] **Step 6: Commit revision actions**

```bash
git add Alas/Sources/App/AppState.swift Alas/Sources/Center/TabBarView.swift \
  Alas/Sources/Center/CenterPaneView.swift Alas/Sources/Center/Commit/TrackedRevision.swift \
  AlasTests/CommitTabStateTests.swift AlasTests/TabsManagerReviewSessionTests.swift
git commit -m "feat(review): add revision follow actions"
```

---

### Task 6: Make commit-detail tabs refresh atomically

**Files:**
- Modify: `Alas/Sources/Center/Commit/CommitTabView.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `AlasTests/CommitTabViewTests.swift`

**Interfaces:**
- Consumes: `CommitTabState`, `TrackedRevisionResolver`, watcher generation, and AppState actions.
- Produces: guarded `CommitTabSnapshot`, updating/error presentation, and checkout banner behavior.

- [ ] **Step 1: Add failing publication and presentation tests**

Define tests for: old snapshot retained while updating; candidate details and review session published together; stale load token rejected; selection retained by matching file path; failure retains the old snapshot; pending checkout exposes accept/stop actions; fixed tabs never resolve on generation changes.

```swift
@Test func trackedPublicationRetainsSelectionByPath() {
    let publication = CommitTabRefreshPublication.make(
        previousSelection: .init(namespace: "commit", path: "A.swift"),
        snapshot: snapshot(paths: ["A.swift", "B.swift"])
    )
    #expect(publication.selectedFileID?.path == "A.swift")
}
```

- [ ] **Step 2: Run `CommitTabViewTests` and verify failure**

- [ ] **Step 3: Refactor the view around a complete immutable snapshot**

Pass `tabState: CommitTabState` instead of a bare SHA. Add:

```swift
struct CommitTabSnapshot {
    let sha: String
    let details: CommitDetails
    let reviewSession: DiffReviewLoadedSession
}
```

Load details and review content into locals, then publish one snapshot only if the generation token remains active. Initial fixed tabs may show the existing full-page spinner; followed refreshes retain the prior snapshot and show `commit-revision-updating` in the header. Resolution/load failures show a nonblocking `commit-revision-error` banner with Retry, Edit, and Stop.

The task identity includes tab ID, tracked expression, and `appState.revisionChangeGeneration(worktreeID:)`. Evaluate `TrackedRevisionPolicy` before loading. Persist pause metadata immediately; persist a new resolved SHA/title only after its complete snapshot loads.

- [ ] **Step 4: Add header follow controls and checkout banner**

Fixed headers call `followRevision`; followed headers show the expression, short SHA, Edit, and Stop. Pending checkout shows Update to new branch and Stop. Add stable accessibility identifiers for all controls.

- [ ] **Step 5: Update center-pane identity and rerun tests**

Render `CommitTabView(tabState:s, ...)` with `.id(s.id)`, never `.id(s.sha)`, so a rewrite does not recreate tab-local UI state.

Expected: `CommitTabViewTests` pass.

- [ ] **Step 6: Commit atomic commit-tab refresh**

```bash
git add Alas/Sources/Center/Commit/CommitTabView.swift \
  Alas/Sources/Center/CenterPaneView.swift AlasTests/CommitTabViewTests.swift
git commit -m "feat(review): refresh followed commit tabs"
```

---

### Task 7: Make dedicated review sessions refresh atomically

**Files:**
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `AlasTests/ReviewSessionTabViewTests.swift`
- Modify: `AlasTests/TabsManagerReviewSessionTests.swift`

**Interfaces:**
- Consumes: tracked target helpers, `ReviewSessionLoader`, resolver policy, draft migration, and watcher generation.
- Produces: tracked-session shadow reload, verdict reset, continuity publication, and tracked review header/banner.

- [ ] **Step 1: Add failing tracked-session refresh tests**

Cover same-branch follow, unchanged resolution, checkout pause, old loaded context retained during refresh/error, out-of-order suppression, file selection retention, draft controller stability, verdict reset, and title/tab-state persistence.

```swift
@Test func movingTrackedReviewReopensVerdictAndPreservesHandoffs() throws {
    let updated = reviewedRecord.retargetingCommit(
        to: movedTarget,
        resolvedSHAChanged: true,
        now: Date(timeIntervalSince1970: 50)
    )
    #expect(updated.status == .active)
    #expect(updated.verdict == nil)
    #expect(updated.handoffs == reviewedRecord.handoffs)
}
```

- [ ] **Step 2: Run review-session suites and verify failure**

- [ ] **Step 3: Resolve before load and publish a complete generation**

Include the worktree revision generation in `loadTaskID` only for tracked commit targets. Split initial-empty loading from tracked-refresh loading so `beginLoadReviewSession` does not clear `loaded` during a refresh. For `.follow`, build the candidate target in memory, call `loader.load(target:)`, then atomically:

1. retarget and save the record,
2. update the tab title/selection,
3. publish the new loaded context,
4. keep the same draft controller because the logical draft ID is unchanged.

For `.pause`, save pending metadata without replacing loaded content. For resolution/load failure, retain loaded content and show a tracked error banner; on first reopen, load the persisted last-resolved SHA even if revalidation fails so the last snapshot is recoverable.

- [ ] **Step 4: Add tracked header and checkout/error banners**

Mirror the commit-tab actions and identifiers. Feedback target text must use `expression -> resolvedSHA`. Retry increments the existing load generation.

- [ ] **Step 5: Rerun focused review-session tests**

Expected: `ReviewSessionTabViewTests` and `TabsManagerReviewSessionTests` pass.

- [ ] **Step 6: Commit tracked review refresh**

```bash
git add Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift \
  Alas/Sources/Center/TabsManager.swift AlasTests/ReviewSessionTabViewTests.swift \
  AlasTests/TabsManagerReviewSessionTests.swift
git commit -m "feat(review): refresh followed review sessions"
```

---

### Task 8: Open followed revisions from the review palette

**Files:**
- Modify: `Alas/Sources/Dialogs/ReviewTarget/ReviewTargetPaletteEnvironment.swift`
- Modify: `Alas/Sources/Dialogs/ReviewTarget/AppState+ReviewPalette.swift`
- Modify: `Alas/Sources/Dialogs/ReviewTarget/ReviewTargetPaletteModel.swift`
- Modify: `Alas/Sources/Dialogs/ReviewTarget/ReviewTargetDialog.swift`
- Modify: `AlasTests/ReviewTargetPaletteModelTests.swift`

**Interfaces:**
- Consumes: live resolver and `ReviewSessionTarget.trackedCommit`.
- Produces: debounced exact-query validation and `.followedRevision` palette rows.

- [ ] **Step 1: Add failing palette tests**

Test valid exact expression, invalid expression, stale async result suppression, commit-filter rows retained, selection snapping to the followed row when it is the only result, and activation opening a tracked target.

```swift
@Test func exactRevisionQueryLaunchesTrackedCommit() async throws {
    model.query = "HEAD~3"
    await model.validateRevisionQuery(environment: env)
    #expect(model.targetRows().contains(.followedRevision(
        expression: "HEAD~3", resolvedSHA: "resolved-HEAD~3", branch: "feature"
    )))
    await model.activateSelection(environment: env)
    #expect(opened?.kind == .trackedCommit)
}
```

- [ ] **Step 2: Run `ReviewTargetPaletteModelTests` and verify failure**

- [ ] **Step 3: Implement validation state and row activation**

Add `currentBranch` to the environment. Add a selectable row:

```swift
case followedRevision(expression: String, resolvedSHA: String, branch: String)
```

`validateRevisionQuery` trims the exact query, captures a validation token, resolves SHA and branch concurrently, and publishes only if the token and query still match. Do not hide ordinary fuzzy commit/branch matches. Activation builds `TrackedRevision` and opens `ReviewSessionTarget.trackedCommit` titled `Review <expression>`.

- [ ] **Step 4: Wire debounced validation and presentation**

Start validation from a query-keyed task in `ReviewTargetDialog` after a short cancellation-aware debounce. Render a pin icon, expression, and resolved short SHA. Surface validation errors only when no normal target rows match, avoiding noisy errors during ordinary fuzzy search.

- [ ] **Step 5: Rerun palette tests**

Expected: all existing and new palette tests pass.

- [ ] **Step 6: Commit palette entry**

```bash
git add Alas/Sources/Dialogs/ReviewTarget/ReviewTargetPaletteEnvironment.swift \
  Alas/Sources/Dialogs/ReviewTarget/AppState+ReviewPalette.swift \
  Alas/Sources/Dialogs/ReviewTarget/ReviewTargetPaletteModel.swift \
  Alas/Sources/Dialogs/ReviewTarget/ReviewTargetDialog.swift \
  AlasTests/ReviewTargetPaletteModelTests.swift
git commit -m "feat(review): open followed revisions from palette"
```

---

### Task 9: Integration regression pass and required verification

**Files:**
- Verify: all tracked-revision, commit-tab, review-session, watcher, palette, and persistence suites.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a fully verified feature with no unrelated behavior changes.

- [ ] **Step 1: Run all focused suites together**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/CommitTabStateTests \
  -only-testing:AlasTests/CommitTabViewTests \
  -only-testing:AlasTests/TabsManagerTests \
  -only-testing:AlasTests/TabsManagerReviewSessionTests \
  -only-testing:AlasTests/ReviewDraftCommentStoreTests \
  -only-testing:AlasTests/ReviewSessionModelsTests \
  -only-testing:AlasTests/ReviewSessionLoaderTests \
  -only-testing:AlasTests/ReviewSessionTabViewTests \
  -only-testing:AlasTests/ReviewTargetPaletteModelTests \
  -only-testing:AlasTests/ProjectGitWatcherTests test
```

Expected: all focused tests pass.

- [ ] **Step 2: Run formatting and repository checks**

```bash
swiftformat --lint Alas/Sources AlasTests
git diff --check
```

Expected: both commands exit successfully.

- [ ] **Step 3: Regenerate and run the required build**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: generation and build succeed. Commit `Alas.xcodeproj/project.pbxproj` if regeneration changes it.

- [ ] **Step 4: Run the full test suite**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: full suite passes. If an unrelated known flaky test fails, rerun that test in isolation and report both results without claiming a clean full-suite pass.

- [ ] **Step 5: Review the final diff and commit verification fixes**

```bash
git status --short
git diff --stat 1b07a6c6..HEAD
git diff --check 1b07a6c6..HEAD
```

Confirm that no CLI/MCP, range-review, hosted-review, draft-commit, or commit-editor behavior changed. Commit only real verification fixes with a focused message; do not create an empty verification commit.
