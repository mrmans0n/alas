# GG Stack Refresh Cancellation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure a cancelled GG stack reload cannot leave the stacked-diffs drawer displaying `Loading` indefinitely.

**Architecture:** Keep cancellation recovery inside `RightPaneState.refreshGGStack`, where refresh-generation and snapshot-generation ownership are already enforced. Capture the prior stable stack presentation before clearing it; if the current load is cancelled without being superseded, restore a same-key stable snapshot or publish a retryable failure.

**Tech Stack:** Swift 5.9+, Swift Concurrency, Observation, Swift Testing, SwiftUI/macOS, XcodeGen/Xcode.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Do not change successful, inactive-context, non-cancellation failure, or superseded-refresh behavior.
- Never display a stack snapshot under a different branch/context/commit key.
- Do not change GG sync streaming or GG command timeouts.

---

### Task 1: Make cancellation terminal without publishing stale stack data

**Files:**
- Modify: `AlasTests/RightPaneGGStackTests.swift:1332`
- Modify: `Alas/Sources/Right/RightPaneState.swift:953-1047`

**Interfaces:**
- Consumes: `RightPaneState.refreshGGStack(forceRemote:)`, `ggStackRefreshGeneration`, `snapshotInvalidationGeneration`, `GGStackLoadState`, `GGStackSummaryStore`.
- Produces: Cancellation recovery within `refreshGGStack(forceRemote:)`; no new public API.

- [ ] **Step 1: Add failing cancellation regression tests**

Add these tests near the existing refresh-generation tests in `RightPaneGGStackTests`:

```swift
@Test func cancelledSameKeyReloadRestoresPreviousStableStack() async throws {
    let worktree = makeWorktree()
    defer { GGStackSummaryStore.shared.summaries[worktree.path.path] = nil }
    let result = ProcessResult(
        exitCode: 0,
        stdout: GGStackModelsTests.fixture,
        stderr: ""
    )
    let runner = ControlledStackGGRunner(
        stackResults: [("agent-inbox", result), ("agent-inbox", result)],
        suspendedCalls: [2]
    )
    let state = RightPaneState(worktree: worktree, baseBranch: "main")
    state.ggService = GGService(runner: runner)
    state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
    state.ggStackSourceCommits = [
        commit(sha: String(repeating: "q", count: 40), stackShaped: true),
    ]

    await state.refreshGGStack()
    let stableKey = try #require(state.ggStackCommitsKey)
    let stableSummary = try #require(GGStackSummaryStore.shared.summaries[worktree.path.path])

    let refresh = Task { @MainActor in
        await state.refreshGGStack(forceRemote: true)
    }
    await runner.waitUntilCall(2)
    #expect(state.ggStackLoadState == .loading)

    refresh.cancel()
    await runner.complete(call: 2)
    await refresh.value

    #expect(state.ggStackLoadState == .loaded)
    #expect(state.ggStack?.name == "agent-inbox")
    #expect(state.ggStackCommitsKey == stableKey)
    #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] == stableSummary)
}

@Test func cancelledFirstStackLoadBecomesRetryableFailure() async {
    let worktree = makeWorktree()
    let result = ProcessResult(
        exitCode: 0,
        stdout: GGStackModelsTests.fixture,
        stderr: ""
    )
    let runner = ControlledStackGGRunner(
        stackResults: [("agent-inbox", result)],
        suspendedCalls: [1]
    )
    let state = RightPaneState(worktree: worktree, baseBranch: "main")
    state.ggService = GGService(runner: runner)
    state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
    state.ggStackSourceCommits = [
        commit(sha: String(repeating: "r", count: 40), stackShaped: true),
    ]

    let refresh = Task { @MainActor in await state.refreshGGStack() }
    await runner.waitUntilCall(1)
    #expect(state.ggStackLoadState == .loading)

    refresh.cancel()
    await runner.complete(call: 1)
    await refresh.value

    #expect(state.ggStackLoadState == .failed("Stack refresh was interrupted. Retry to load it again."))
    #expect(state.ggStack == nil)
    #expect(state.ggStackCommitsKey == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/RightPaneGGStackTests/cancelledSameKeyReloadRestoresPreviousStableStack \
  -only-testing:AlasTests/RightPaneGGStackTests/cancelledFirstStackLoadBecomesRetryableFailure
```

Expected: both tests fail because `ggStackLoadState` remains `.loading`; the same-key test also observes a nil stack, cache key, and summary.

- [ ] **Step 3: Implement ownership-aware cancellation recovery**

Immediately after the unchanged-key guard in `refreshGGStack(forceRemote:)`, capture the previous stable presentation and install a `defer` before switching to `.loading`:

```swift
let previousStack = ggStack
let previousKey = ggStackCommitsKey
let previousLoadState = ggStackLoadState
let previousSummary = GGStackSummaryStore.shared.summaries[worktree.path.path]
defer {
    if Task.isCancelled,
       snapshotGeneration == snapshotInvalidationGeneration,
       refreshGeneration == ggStackRefreshGeneration,
       ggStackLoadState == .loading {
        let canRestorePreviousSnapshot = previousKey == key
            && (previousLoadState == .loaded || previousLoadState == .empty)
        if canRestorePreviousSnapshot {
            ggStack = previousStack
            ggStackCommitsKey = previousKey
            ggStackLoadState = previousLoadState
            GGStackSummaryStore.shared.summaries[worktree.path.path] = previousSummary
        } else {
            ggStack = nil
            ggStackCommitsKey = nil
            ggStackLoadState = .failed(
                "Stack refresh was interrupted. Retry to load it again."
            )
            GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
        }
    }
}
```

Keep the existing `Task.isCancelled` checks in the success and catch paths. They prevent normal result publication; the `defer` now supplies the missing terminal transition only when this refresh still owns `.loading`.

- [ ] **Step 4: Run focused GG stack tests and verify GREEN**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/RightPaneGGStackTests
```

Expected: all `RightPaneGGStackTests` pass, including existing stale-generation and changed-key tests.

- [ ] **Step 5: Regenerate and run project verification**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
git diff --check
```

Expected: XcodeGen succeeds without unintended project changes; build and all tests pass; `git diff --check` reports no errors.

- [ ] **Step 6: Commit the tested fix**

```bash
git add Alas/Sources/Right/RightPaneState.swift AlasTests/RightPaneGGStackTests.swift
git commit -m "fix(gg): resolve cancelled stack refreshes"
```
