# GG Prepare Sync Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the GG Prepare card visible and actionable whenever the current stack readiness state requires Sync or Rebase.

**Architecture:** `GGStackReadinessModel` remains the only component that decides whether stack reconciliation is needed. `ChangesTabView` passes its current Sync/Rebase action into `ChangesPreparationModel`, which owns Prepare visibility, while `ChangesPreparationCard` renders and dispatches that action through the existing GG stack action path.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation, Swift Testing, XcodeGen

---

### Task 1: Add Reconciliation To The Prepare Model And Card

**Files:**
- Modify: `Alas/Sources/Right/ChangesPreparationModel.swift`
- Modify: `Alas/Sources/Right/ChangesPreparationCard.swift`
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Test: `AlasTests/Right/ChangesPreparationModelTests.swift`

- [ ] **Step 1: Write failing model tests**

Add tests that construct `GGStackReadinessModel.Action` values directly and
pass them through `ChangesPreparationModel.makeGG`:

```swift
@Test func ggReconciliationMakesEmptyPreparationVisible() {
    let sync = GGStackReadinessModel.Action(
        kind: .sync,
        title: "Sync stack",
        detail: nil,
        isEnabled: true,
        isInFlight: false,
        emphasis: .primary
    )
    let model = ChangesPreparationModel.makeGG(
        staged: .zero,
        hasDraft: false,
        capabilities: stagedOnlyCapabilities,
        reconciliationAction: sync
    )

    #expect(model.reconciliationAction == sync)
    #expect(model.isVisible)
}

@Test func synchronizedEmptyGGPreparationRemainsHidden() {
    let model = ChangesPreparationModel.makeGG(
        staged: .zero,
        hasDraft: false,
        capabilities: stagedOnlyCapabilities,
        reconciliationAction: nil
    )

    #expect(model.reconciliationAction == nil)
    #expect(!model.isVisible)
}
```

Also add one preservation test with an in-flight auto-rebase Sync action:

```swift
@Test func ggReconciliationPreservesReadinessPresentation() {
    let action = GGStackReadinessModel.Action(
        kind: .sync,
        title: "Sync stack",
        detail: "Includes rebase onto main",
        isEnabled: false,
        isInFlight: true,
        emphasis: .primary
    )
    let model = ChangesPreparationModel.makeGG(
        staged: .zero,
        hasDraft: false,
        capabilities: stagedOnlyCapabilities,
        reconciliationAction: action
    )

    #expect(model.reconciliationAction == action)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ChangesPreparationModelTests test
```

Expected: compilation fails because `reconciliationAction` is not yet part of
`ChangesPreparationModel.makeGG` or the model.

- [ ] **Step 3: Add the minimal model contract**

In `ChangesPreparationModel`:

```swift
let reconciliationAction: GGStackReadinessModel.Action?
```

Add a defaulted `reconciliationAction: GGStackReadinessModel.Action? = nil`
parameter to both public `makeGG` overloads and thread it through the private
factory. Assign it in the GG-only private initializer. Assign `nil` in the
non-GG initializer.

Update GG visibility without changing non-GG behavior:

```swift
var isVisible: Bool {
    if !ggActions.isEmpty {
        return reconciliationAction != nil
            || reviewAction != nil
            || ggAction(.newStackCommit)?.isEnabled == true
    }
    return reviewAction != nil || draftAction != nil || !reviewRequestActions.isEmpty
}
```

- [ ] **Step 4: Render the readiness action in Prepare**

In `ChangesPreparationCard`, render `model.reconciliationAction` after the
optional review button and before the GG destination row:

```swift
if let reconciliationAction = model.reconciliationAction {
    ggReconciliationButton(reconciliationAction)
}
```

Implement a full-width button using the existing card colors, `Spinner` for
`isInFlight`, a sync/rebase icon selected from `action.kind`, `action.title`,
and optional `action.detail`. Preserve `action.isEnabled` and expose
`changes-preparation-gg-reconciliation` as its accessibility identifier.

Add a dedicated callback:

```swift
let onGGStackAction: (GGStackActionKind) -> Void
```

The button dispatches `onGGStackAction(action.kind)`. Do not merge Sync/Rebase
into `GGChangesPreparationAction`, whose cases remain working-tree
destinations.

Update the `ChangesPreparationCard` construction in `ChangesTabView` so the
new callback compiles and routes through the existing mutation path:

```swift
onGGStackAction: { action in
    rps.onGGStackAction(action, appState: appState)
}
```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ChangesPreparationModelTests test
```

Expected: `ChangesPreparationModelTests` passes.

- [ ] **Step 6: Commit Task 1**

```bash
git add Alas/Sources/Right/ChangesPreparationModel.swift \
  Alas/Sources/Right/ChangesPreparationCard.swift \
  Alas/Sources/Right/ChangesTabView.swift \
  AlasTests/Right/ChangesPreparationModelTests.swift
git commit -m "feat(gg): add reconciliation to Prepare"
```

### Task 2: Derive And Route The GG Readiness Action

**Files:**
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Test: `AlasTests/ChangesTabViewTests.swift`

- [ ] **Step 1: Write failing integration-policy tests**

Add a helper in `ChangesTabViewTests` that creates `GGStack` fixtures with
configurable `syncedCommits`, `behindBase`, and `prState`. Exercise the real
`GGStackReadinessModel.make` policy and the new Prepare filter:

```swift
@Test func prepareSelectsSyncForChangedOrPublishableStack() {
    let unsynced = GGStackReadinessModel.make(
        stack: stack(syncedCommits: 0, prState: .open),
        action: GGStackActionState()
    )
    let publishable = GGStackReadinessModel.make(
        stack: stack(syncedCommits: 1, prState: nil),
        action: GGStackActionState()
    )

    #expect(ChangesTabView.reconciliationAction(from: unsynced)?.kind == .sync)
    #expect(ChangesTabView.reconciliationAction(from: publishable)?.kind == .sync)
}

@Test func prepareSelectsConfiguredBaseReconciliation() {
    let auto = GGStackReadinessModel.make(
        stack: stack(syncedCommits: 1, behindBase: 2, prState: .open),
        action: GGStackActionState(),
        effectiveConfig: .init(syncAutoRebase: true, syncBehindThreshold: 1)
    )
    let manual = GGStackReadinessModel.make(
        stack: stack(syncedCommits: 1, behindBase: 2, prState: .open),
        action: GGStackActionState(),
        effectiveConfig: .init(syncAutoRebase: false, syncBehindThreshold: 1)
    )

    #expect(ChangesTabView.reconciliationAction(from: auto)?.kind == .sync)
    #expect(ChangesTabView.reconciliationAction(from: auto)?.detail == "Includes rebase onto main")
    #expect(ChangesTabView.reconciliationAction(from: manual)?.kind == .rebase)
}

@Test func prepareOmitsNonReconciliationReadiness() {
    let readyToLand = GGStackReadinessModel.make(
        stack: stack(syncedCommits: 1, prState: .open, approved: true, ci: .success),
        action: GGStackActionState()
    )

    #expect(ChangesTabView.reconciliationAction(from: readyToLand) == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ChangesTabViewTests test
```

Expected: compilation fails because
`ChangesTabView.reconciliationAction(from:)` does not exist.

- [ ] **Step 3: Build readiness from the same drawer inputs**

Add a private `ggReadinessModel` property to `ChangesTabView`. When
`ggStackLoadState == .loaded` and `ggStack` exists, call
`GGStackReadinessModel.make` with:

```swift
stack: stack
action: rps.ggActionState
liveBehindBase: GGStackDrawer.liveBehindBaseOverride(
    stack: stack,
    selectedBaseBranch: rps.baseBranch,
    behindBase: rps.behindBase
)
hasBlockingGitOperation: GGStackDrawer.hasBlockingGitOperation(
    mergeOperation: rps.mergeOp.current,
    pausedGGOperation: rps.ggActionState.pausedOperation
)
effectiveConfig: rps.ggEffectiveConfig
localChanges: rps.ggLocalChangeStatistics
undoCandidate: rps.ggUndoCandidate
```

Return `nil` for unloaded/empty/failed stack states.

- [ ] **Step 4: Filter and pass reconciliation into Prepare**

Add this pure helper:

```swift
static func reconciliationAction(
    from readiness: GGStackReadinessModel?
) -> GGStackReadinessModel.Action? {
    readiness?.primaryActions.first {
        $0.kind == .sync || $0.kind == .rebase
    }
}
```

Pass it to `ChangesPreparationModel.makeGG`:

```swift
reconciliationAction: Self.reconciliationAction(from: ggReadinessModel)
```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ChangesTabViewTests \
  -only-testing:AlasTests/ChangesPreparationModelTests \
  -only-testing:AlasTests/GGStackReadinessModelTests test
```

Expected: all selected suites pass.

- [ ] **Step 6: Run project verification**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: XcodeGen succeeds, the macOS build exits zero, and the full test
suite reports no failures.

- [ ] **Step 7: Commit Task 2**

```bash
git add Alas/Sources/Right/ChangesTabView.swift \
  AlasTests/ChangesTabViewTests.swift \
  Alas.xcodeproj
git commit -m "feat(gg): surface stack sync in Prepare"
```

If `xcodegen` produces no project diff, do not stage `Alas.xcodeproj`.

### Task 3: Final Review And Publication Readiness

**Files:**
- Review: all changes since `origin/main`

- [ ] **Step 1: Review the complete diff against the design**

Confirm:

- Prepare appears for Sync and Rebase readiness only.
- GG readiness remains the single reconciliation policy.
- fully synchronized clean stacks do not show an empty Prepare card.
- the drawer and existing working-tree destinations are unchanged.
- action title, detail, enablement, and in-flight state are preserved.

- [ ] **Step 2: Run final verification from a clean index**

Run:

```bash
git diff --check
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
git status --short
```

Expected: no whitespace errors, build and tests pass, and the worktree is
clean.
