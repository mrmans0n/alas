# GG Post-Sync Refresh Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Each task must follow superpowers:test-driven-development and receive a task-scoped review before the next task starts.

**Goal:** Ensure a completed GG mutation never leaves its action spinner running while a follow-up stack refresh is slow, hung, cancelled, or failed.

**Architecture:** Treat mutation execution and refresh reconciliation as two distinct phases. The coordinator publishes terminal mutation state before it awaits refresh work; `RightPaneState` routes that refresh through its existing cancellable `ggStackRefreshTask`; and the process runner applies a short timeout only to read-only `gg ls --json` calls while retaining the long mutation timeout.

**Tech Stack:** Swift 5.9+, SwiftUI/Observation, Swift Concurrency, Swift Testing, XcodeGen/Xcode.

## Global Constraints

- Preserve the completed mutation result while refresh is pending or fails: success remains success, and a mutation error remains the terminal mutation error.
- Clear `GGMutationCoordinator.activeRequest` and `GGStackActionState.inFlightAction` before any post-mutation refresh await.
- Ending an old request must never clear a newer request, including a newer request with the same `GGMutationRequest` value.
- Keep the returned mutation task awaitable through refresh completion for deterministic callers and tests.
- Route post-mutation stack refreshes through the same tracked `ggStackRefreshTask` lifecycle used by `reevaluateGGGate()`.
- Use `Process.defaultTimeout` (30 seconds) for buffered `gg ls --json` invocations, including invocations with client-operation arguments before or after the command tokens.
- Keep the 600-second timeout for buffered mutations, capability probes, and streaming mutation commands.
- A timed-out or otherwise failed stack refresh must surface through `ggStackLoadState` as a retryable failure without resurrecting an action spinner.
- Keep the existing 0.14.4 cancellation recovery behavior and tests green.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Keep code, comments, logs, and UI strings in English.
- Do not edit `project.yml` or generated project files for this fix.

---

### Task 1: Publish terminal mutation state before refresh

**Files:**

- Modify: `AlasTests/Integrations/GGMutationCoordinatorTests.swift`
- Modify: `Alas/Sources/Integrations/GG/GGMutationCoordinator.swift`

**Step 1: Strengthen the suspended-refresh regression tests**

Update `terminalSyncSummaryDoesNotRegressToPreparingDuringRefresh` so that, while `onRefreshStack` is suspended, it asserts all of these observable outcomes:

```swift
#expect(harness.coordinator.activeRequest == nil)
#expect(harness.actionState.inFlightAction == nil)
#expect(harness.actionState.lastActionSummary == "Synced")
#expect(harness.actionState.syncProgress.isEmpty)
#expect(model.syncProgress == nil)
#expect(model.primaryActions.first(where: { $0.kind == .sync })?.isInFlight == false)
```

Update `syncCommandFailurePublishesTerminalStateBeforeSuspendedRefresh` so that the suspended refresh likewise observes `activeRequest == nil` and `inFlightAction == nil`, while preserving `lastError == "sync failed"` and `syncHasTerminalFailure == true`.

These tests catch the original bug: moving action cleanup back behind `await refresh(...)` must make them fail.

**Step 2: Run the focused tests and confirm RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGMutationCoordinatorTests/terminalSyncSummaryDoesNotRegressToPreparingDuringRefresh \
  -only-testing:AlasTests/GGMutationCoordinatorTests/syncCommandFailurePublishesTerminalStateBeforeSuspendedRefresh
```

Expected: the new assertions fail because the coordinator still owns the action reservation during refresh.

**Step 3: Release the observable action phase exactly once**

Refactor `applyReserved` to use a synchronous local release path guarded by a per-invocation boolean. The fallback `defer` must release only if an earlier terminal path has not already released. The release path must:

```swift
activeRequest = nil
actionState.endAction(request.actionKind)
if request == .sync,
   actionState.lastError == nil,
   GGStackActionState.syncSummaryLine(from: actionState.syncProgress) != nil {
    actionState.clearSyncProgress()
}
```

Call it after `recordSummary` and `reconcilePausedState` on success but before `await refresh(...)`. In both error catches, publish the terminal error/failure state and then release before awaiting refresh. Set the per-invocation guard so the fallback defer cannot later clear a newer reservation.

Do not detach the refresh and do not change refresh ordering or undo reconciliation.

**Step 4: Run the focused tests and confirm GREEN**

Run the command from Step 2. Expected: both tests pass, with their continuations still proving the returned task waits for refresh completion.

**Step 5: Run the coordinator suite**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGMutationCoordinatorTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add Alas/Sources/Integrations/GG/GGMutationCoordinator.swift AlasTests/Integrations/GGMutationCoordinatorTests.swift
git commit -m "fix(gg): end mutation state before stack refresh"
```

---

### Task 2: Put post-mutation refreshes on the tracked refresh lifecycle

**Files:**

- Modify: `AlasTests/RightPaneGGStackTests.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift`

**Step 1: Add an integration regression test for replacement refresh cancellation**

Add a purpose-built `GGCommandRunning` test double that can:

- return a valid stack snapshot for the mutation preflight,
- return a terminal JSONL sync summary,
- suspend the post-sync `gg ls --json` call in a cancellation-sensitive await,
- record when that suspended call is cancelled, and
- let the next `gg ls --json` replacement complete successfully.

Add `postMutationStackRefreshIsCancelledByReplacementRefresh`. Drive sync through `RightPaneState.onGGStackAction(.sync, appState:)`, wait for the post-sync stack read to suspend, then call and await `state.reevaluateGGGate()`. Assert the first post-sync read observed cancellation, the replacement read loaded the stack, and the action state remains terminal (`inFlightAction == nil`, summary retained, no sync progress).

This catches routing the coordinator closure directly to `refreshGGStack()`: in that implementation the mutation refresh is not stored in `ggStackRefreshTask`, so replacement gate evaluation cannot cancel it.

**Step 2: Run the new test and confirm RED**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/RightPaneGGStackTests/postMutationStackRefreshIsCancelledByReplacementRefresh
```

Expected: the suspended post-mutation refresh does not observe cancellation.

**Step 3: Route the mutation context through `reevaluateGGGate()`**

Replace the direct refresh body in `GGMutationContext.refreshStack` with the tracked path:

```swift
refreshStack: { [weak self] in
    guard let self else { return }
    await self.reevaluateGGGate().value
},
```

Do not add another task property or duplicate the cancellation/generation logic. `reevaluateGGGate()` remains the single owner of `ggStackRefreshTask` replacement.

**Step 4: Run the focused cancellation coverage and confirm GREEN**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/RightPaneGGStackTests/postMutationStackRefreshIsCancelledByReplacementRefresh \
  -only-testing:AlasTests/RightPaneGGStackTests/cancelledSameKeyReloadRestoresPreviousStableStack \
  -only-testing:AlasTests/RightPaneGGStackTests/cancelledFirstStackLoadBecomesRetryableFailure
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Alas/Sources/Right/RightPaneState.swift AlasTests/RightPaneGGStackTests.swift
git commit -m "fix(gg): track post-mutation stack refreshes"
```

---

### Task 3: Bound read-only stack query time without shortening mutations

**Files:**

- Modify: `AlasTests/Integrations/GGServiceTests.swift`
- Modify: `Alas/Sources/Integrations/GG/GGService.swift`

**Step 1: Add timeout policy tests**

Add a table-driven test named `processRunnerUsesShortTimeoutOnlyForStackQueries` covering literal expectations:

| Arguments | Expected timeout |
|---|---:|
| `["ls", "--json"]` | `Process.defaultTimeout` |
| `["--client-operation-id", "alas:1", "ls", "--json"]` | `Process.defaultTimeout` |
| `["ls", "--json", "--client-operation-id", "alas:1"]` | `Process.defaultTimeout` |
| `["sync", "--json"]` | `600` |
| `["sync", "--help"]` | `600` |
| `["ls"]` | `600` |

Exercise the timeout selected by `ProcessGGCommandRunner.run(args:cwd:)` through an injected process-launch closure that records the invocation and returns a successful `ProcessResult`. Assert the executable and command arguments remain `/usr/bin/env` and `["gg"] + args` as well as the timeout. Do not invoke a real `gg` subprocess.

The test catches an over-broad short timeout, a suffix-only matcher that misses client-operation tokens, and accidental shortening of mutations.

**Step 2: Run the new test and confirm RED**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGServiceTests/processRunnerUsesShortTimeoutOnlyForStackQueries
```

Expected: compilation or assertions fail until the runner exposes an injectable launch seam and selects the timeout by command tokens.

**Step 3: Implement the narrow timeout policy**

Keep `commandTimeout` at 600 seconds. Give `ProcessGGCommandRunner` an internal injected async process-launch closure whose default calls `Process.run`, and have `run(args:cwd:)` pass either `Process.defaultTimeout` or `commandTimeout` to it.

Recognize the stack query by locating an adjacent `"ls", "--json"` pair anywhere in the GG argument list; do not classify a lone `ls`, a lone `--json`, or non-adjacent tokens as a stack query. Continue passing 600 seconds to `runStreaming`.

**Step 4: Run service and streaming runner tests and confirm GREEN**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGServiceTests \
  -only-testing:AlasTests/GGCommandRunningStreamingTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Alas/Sources/Integrations/GG/GGService.swift AlasTests/Integrations/GGServiceTests.swift
git commit -m "fix(gg): bound stack query duration"
```

---

### Task 4: Verify the complete fix and regression envelope

**Files:**

- Verify only; change files only if a verification failure exposes a defect in Tasks 1–3.

**Step 1: Regenerate the Xcode project**

```bash
xcodegen
```

Expected: succeeds and produces no tracked diff because `project.yml` was not changed.

**Step 2: Build the macOS app**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

**Step 3: Run the full test suite**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: all tests pass.

**Step 4: Inspect the final diff**

```bash
git status --short
git diff --check
git log --oneline --decorate -5
```

Expected: only the planned implementation, tests, design, and plan are present; no generated or unrelated changes remain.

**Step 5: Record verification**

Do not create an empty commit. Put command output and the final pass/fail summary in the subagent report so the controller can use it for final review and PR publication.
