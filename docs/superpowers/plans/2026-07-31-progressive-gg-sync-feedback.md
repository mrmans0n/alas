# Progressive gg Sync Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Alas show immediate, compact, stable progress for its existing `gg sync` integration without requiring any git-gud changes.

**Architecture:** Keep raw `GGSyncEvent` values as the CLI source of truth, derive the pre-stream `Preparing sync…` state from the existing mutation lifecycle, and reduce streamed events into one live status plus one stable row per stack position. Move `--jsonl` detection into the existing session-cached `GGCapabilities` probe and pass that value explicitly through the mutation coordinator to `GGService`.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation, Foundation `Process`, `AsyncThrowingStream`, Swift Testing, XcodeGen.

## Global Constraints

- This is an Alas-only change; do not modify git-gud or require a newer gg release.
- Preserve `gg sync --json` as the atomic fallback when `--jsonl` is unsupported.
- Do not claim visibility into gg's internal provider, fetch, rebase, lint, or metadata-normalization phases before `start`.
- Keep raw CLI events separate from Alas lifecycle state; do not synthesize a fake `GGSyncEvent.preparing` case.
- Treat the terminal `summary` event as the JSONL success boundary.
- Keep unknown non-error JSONL events tolerant and forward-compatible.
- Retain completed rows from a failed sync until the next action begins.
- Keep all code, comments, logs, and UI copy in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Do not create new source files or change Xcode project membership.
- Prefix repository commands with `rtk`.

---

## File Map

- `Alas/Sources/Integrations/GG/GGActionEvents.swift`: parse the full existing sync event set, including positional failures.
- `Alas/Sources/Integrations/GG/GGMutationModels.swift`: store session-cached `syncJSONL` capability state.
- `Alas/Sources/Integrations/GG/GGService.swift`: probe sync capability once, select output mode explicitly, and validate terminal JSONL ordering.
- `Alas/Sources/Integrations/GG/GGMutationCoordinator.swift`: pass cached capability into mutation execution.
- `Alas/Sources/Integrations/GG/GGStackActionState.swift`: clear old progress at the next action boundary while retaining failed-attempt progress.
- `Alas/Sources/Integrations/GG/GGStackReadinessModel.swift`: reduce events into live status and stable per-position rows.
- `Alas/Sources/Integrations/GG/GGStackDrawer.swift`: render the compact progress surface with stable SwiftUI row identity.
- `AlasTests/Integrations/GGActionEventsTests.swift`: event parsing coverage.
- `AlasTests/Integrations/GGAvailabilityTests.swift`: cached capability detection.
- `AlasTests/Integrations/GGServiceActionsTests.swift`: explicit JSONL/fallback selection and stream terminal validation.
- `AlasTests/Integrations/GGMutationCoordinatorTests.swift`: capability forwarding, immediate lifecycle feedback, success clearing, and failure retention.
- `AlasTests/Integrations/GGStackActionStateTests.swift`: action-boundary progress lifecycle.
- `AlasTests/Integrations/GGStackReadinessModelTests.swift`: pure progress-reducer behavior.
- `AlasTests/RightPaneGGStackTests.swift`: drawer-facing terminology and presentation integration.

---

### Task 1: Parse the complete existing gg sync event set

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGActionEvents.swift:3-104`
- Modify: `Alas/Sources/Integrations/GG/GGMutationCoordinator.swift:260-270`
- Modify: `Alas/Sources/Integrations/GG/GGStackReadinessModel.swift:251-263`
- Test: `AlasTests/Integrations/GGActionEventsTests.swift:31-60`
- Update test fixtures: `AlasTests/Integrations/GGServiceActionsTests.swift`, `AlasTests/Integrations/GGMutationCoordinatorTests.swift`, `AlasTests/Integrations/GGStackActionStateTests.swift`, `AlasTests/Integrations/GGStackReadinessModelTests.swift`

**Interfaces:**
- Consumes: gg schema-1 events `pr_updated`, `pr_skipped_closed`, `push_error`, and existing sync events.
- Produces: `GGSyncEvent.prUpdated(position:prNumber:action:)`, `GGSyncEvent.prSkippedClosed(position:prNumber:)`, and `GGSyncEvent.error(position:operation:message:)` for Tasks 2-4.

- [ ] **Step 1: Extend parser tests with the missing event variants and positional errors**

Update `parsesEachSyncEventVariant` to assert the exact installed gg shapes:

```swift
#expect(GGSyncEvent.parse(line: #"{"event":"pr_updated","position":1,"pr_number":42,"action":"updated"}"#)
    == .prUpdated(position: 1, prNumber: 42, action: "updated"))
#expect(GGSyncEvent.parse(line: #"{"event":"pr_skipped_closed","position":2,"pr_number":43}"#)
    == .prSkippedClosed(position: 2, prNumber: 43))
#expect(GGSyncEvent.parse(line: #"{"event":"error","message":"boom"}"#)
    == .error(position: nil, operation: nil, message: "boom"))
#expect(GGSyncEvent.parse(line: #"{"event":"push_error","position":1,"message":"push failed"}"#)
    == .error(position: 1, operation: "push", message: "push failed"))
#expect(GGSyncEvent.parse(line: #"{"event":"summary","entries":[{"position":2,"error":"PR failed"}]}"#)
    == .error(position: 2, operation: nil, message: "PR failed"))
#expect(GGSyncEvent.parse(line: #"{"version":1,"sync":{"entries":[{"position":3,"error":"push failed"}]}}"#)
    == .error(position: 3, operation: nil, message: "push failed"))
```

Keep the existing blank, malformed, and unknown-event expectations unchanged.

- [ ] **Step 2: Run the event tests and confirm they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGActionEventsTests test
```

Expected: compilation failures because the new event cases and positional error payload do not exist.

- [ ] **Step 3: Add typed cases and parse the existing gg fields**

Change the sync event enum to:

```swift
enum GGSyncEvent: Equatable {
    case start(totalEntries: Int)
    case entryStarted(position: Int, title: String)
    case pushStarted(position: Int)
    case pushDone(position: Int, forced: Bool)
    case prCreated(position: Int, prNumber: Int, prURL: String?, draft: Bool)
    case prUpdated(position: Int, prNumber: Int, action: String)
    case prSkippedClosed(position: Int, prNumber: Int)
    case summary
    case error(position: Int?, operation: String?, message: String)
}
```

Add parser branches before `summary`:

```swift
case "pr_updated":
    guard let pos = int("position"),
          let number = int("pr_number"),
          let action = eventObject["action"] as? String
    else { return nil }
    return .prUpdated(position: pos, prNumber: number, action: action)
case "pr_skipped_closed":
    guard let pos = int("position"), let number = int("pr_number") else { return nil }
    return .prSkippedClosed(position: pos, prNumber: number)
```

Return positional errors without adding the position to their message:

```swift
case "summary":
    if let entries = eventObject["entries"] as? [[String: Any]] {
        for entry in entries {
            if let error = message(from: entry["error"]) {
                return .error(position: entry["position"] as? Int, operation: nil, message: error)
            }
        }
    }
    return .summary
case "error":
    return .error(
        position: int("position"),
        operation: nil,
        message: message(default: "gg reported an error")
    )
default:
    if event.hasSuffix("_error") {
        return .error(
            position: int("position"),
            operation: String(event.dropLast("_error".count)),
            message: message(default: "gg reported \(event)")
        )
    }
    return nil
```

Update `GGActionErrorMessage.parse(fromJSON:)` to match `.error(let position, _, let message)` and preserve its established prefix:

```swift
if let line = String(data: data, encoding: .utf8),
   case .error(let position, _, let message) = GGSyncEvent.parse(line: line)
{
    return position.map { "[\($0)] \(message)" } ?? message
}
```

Update existing test fixtures throughout the focused test files from `.error(message:)` to `.error(position:operation:message:)` without changing their intent.

Update the coordinator's streamed-error extraction to:

```swift
if case .error(_, _, let message) = event {
    actionState.setError(message)
}
```

Keep the existing append-only readiness projection compiling until Task 3 replaces it by adding temporary branches for the two new PR cases and updating the error pattern:

```swift
case .prUpdated(let position, let number, _): return "[\(position)] PR #\(number)"
case .prSkippedClosed(let position, let number): return "[\(position)] PR #\(number) already closed"
case .error(_, _, let message): return "Error: \(message)"
```

- [ ] **Step 4: Run parser tests and all directly affected compile-time consumers**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/GGActionEventsTests \
  -only-testing:AlasTests/GGServiceActionsTests \
  -only-testing:AlasTests/GGStackActionStateTests \
  -only-testing:AlasTests/GGStackReadinessModelTests \
  -only-testing:AlasTests/GGMutationCoordinatorTests test
```

Expected: PASS.

- [ ] **Step 5: Commit the event contract change**

```bash
git status --short
git add Alas/Sources/Integrations/GG/GGActionEvents.swift \
  Alas/Sources/Integrations/GG/GGMutationCoordinator.swift \
  Alas/Sources/Integrations/GG/GGStackReadinessModel.swift \
  AlasTests/Integrations/GGActionEventsTests.swift \
  AlasTests/Integrations/GGServiceActionsTests.swift \
  AlasTests/Integrations/GGMutationCoordinatorTests.swift \
  AlasTests/Integrations/GGStackActionStateTests.swift \
  AlasTests/Integrations/GGStackReadinessModelTests.swift
git commit -m "feat(gg): parse complete sync progress events"
```

---

### Task 2: Cache JSONL capability and validate the sync stream boundary

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGMutationModels.swift:10-15`
- Modify: `Alas/Sources/Integrations/GG/GGService.swift:292-308,426-453,614-619,801-845`
- Modify: `Alas/Sources/Integrations/GG/GGMutationCoordinator.swift:26-79,205-280,665-700`
- Test: `AlasTests/Integrations/GGAvailabilityTests.swift:16-59,78-123`
- Test: `AlasTests/Integrations/GGServiceActionsTests.swift:5-85`
- Test: `AlasTests/Integrations/GGMutationCoordinatorTests.swift:21-59,124-181`
- Update direct call: `AlasTests/RightPaneGGStackTests.swift:1699-1706`

**Interfaces:**
- Consumes: `GGSyncEvent.parse(line:)` from Task 1 and the existing session-scoped `GGAvailability` probe.
- Produces: `GGCapabilities.syncJSONL: Bool`, `GGService.sync(worktreePath:supportsJSONL:)`, and `GGMutationExecuting.execute(_:worktreePath:clientOperationID:supportsSyncJSONL:onSyncEvent:)` for Tasks 3-4.

- [ ] **Step 1: Write failing capability-probe tests**

Extend `HelpGGRunner` with `let sync: String?`, accept it in the initializer, and handle `case ["sync", "--help"]`. Add:

```swift
@Test func syncJSONLCapabilityUsesSyncHelpAndDefaultsOff() async {
    let current = GGService(runner: HelpGGRunner(
        split: "", unstack: "", sync: "--json --jsonl"
    ))
    #expect((await current.probeCapabilities()).syncJSONL)

    let old = GGService(runner: HelpGGRunner(
        split: "", unstack: "", sync: "--json"
    ))
    #expect(!(await old.probeCapabilities()).syncJSONL)
}
```

Keep `sync` defaulted to `nil` so existing capability tests prove the new field defaults off.

- [ ] **Step 2: Write failing explicit output-mode and terminal-boundary tests**

Remove `syncHelpStdout` behavior from `RecordingGGRunner`; output-mode selection must no longer execute help during sync. Update existing calls to pass `supportsJSONL: true` or `false`, then assert exact calls:

```swift
for try await event in service.sync(worktreePath: "/tmp/wt", supportsJSONL: true) {
    events.append(event)
}
#expect(runner.calls == [["sync", "--jsonl"]])

for try await event in service.sync(worktreePath: "/tmp/wt", supportsJSONL: false) {
    fallbackEvents.append(event)
}
#expect(runner.calls == [["sync", "--json"]])
```

Add stream-boundary cases:

```swift
@Test func syncJSONLRequiresTerminalSummary() async {
    let runner = RecordingGGRunner(stdout: #"{"event":"start","total_entries":1}"#)
    let service = GGService(runner: runner)

    await #expect(throws: GGServiceError.malformedOutput("gg sync ended without a summary event.")) {
        for try await _ in service.sync(worktreePath: "/tmp/wt", supportsJSONL: true) {}
    }
}

@Test func syncJSONLRejectsEventsAfterSummary() async {
    let runner = RecordingGGRunner(stdout: [
        #"{"event":"summary"}"#,
        #"{"event":"push_done","position":1,"forced":false}"#,
    ].joined(separator: "\n"))
    let service = GGService(runner: runner)

    await #expect(throws: GGServiceError.malformedOutput("gg sync emitted data after a terminal event.")) {
        for try await _ in service.sync(worktreePath: "/tmp/wt", supportsJSONL: true) {}
    }
}
```

Unknown or malformed lines before summary remain skipped; add a success fixture containing one such line before a valid summary.

- [ ] **Step 3: Run capability and service tests and confirm they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/GGAvailabilityTests \
  -only-testing:AlasTests/GGServiceActionsTests test
```

Expected: compilation failures for `syncJSONL` and the new `sync` signature.

- [ ] **Step 4: Add the cached capability and explicit sync signature**

Extend the model with a defaulted field so unrelated memberwise initializers stay source-compatible:

```swift
struct GGCapabilities: Equatable, Sendable {
    var structuredSplit: Bool
    var keepCurrentUnstack: Bool
    var clientOperationID: Bool = false
    var stagedOnlyAmend: Bool = false
    var syncJSONL: Bool = false
}
```

Probe sync help once with the session capabilities:

```swift
let sync = try? await runner.run(args: ["sync", "--help"], cwd: nil)

return GGCapabilities(
    structuredSplit: split?.exitCode == 0
        && split?.stdout.contains("--describe") == true
        && split?.stdout.contains("--plan-json") == true,
    keepCurrentUnstack: unstack?.exitCode == 0
        && unstack?.stdout.contains("--keep-current") == true,
    clientOperationID: root?.exitCode == 0
        && root?.stdout.contains("--client-operation-id") == true,
    stagedOnlyAmend: sc?.exitCode == 0
        && sc?.stdout.contains("--staged-only") == true,
    syncJSONL: sync?.exitCode == 0 && sync?.stdout.contains("--jsonl") == true
)
```

Delete `syncSupportsJSONL()`. Change the public sync boundary to:

```swift
func sync(
    worktreePath: String,
    supportsJSONL: Bool
) -> AsyncThrowingStream<GGSyncEvent, Error>
```

For JSONL, track `sawSummary`. Reject every raw line after summary before attempting to parse it, set the flag when `.summary` arrives, and require it after the line stream completes. Keep skipped unknown/malformed lines before summary from changing terminal state. For the atomic fallback, retain the existing checked `--json` execution and decoded single event.

- [ ] **Step 5: Pass the cached capability through the mutation boundary**

Add the argument to the protocol and concrete executor:

```swift
func execute(
    _ request: GGMutationRequest,
    worktreePath: String,
    clientOperationID: String?,
    supportsSyncJSONL: Bool,
    onSyncEvent: (GGSyncEvent) -> Void
) async throws -> GGMutationExecutionResult
```

Add a coordinator dependency beside the client-operation capability:

```swift
private let syncJSONLCapability: () -> Bool

init(
    // existing arguments
    syncJSONLCapability: @escaping () -> Bool = {
        GGAvailability.shared.capabilities.syncJSONL
    },
    // remaining arguments
) {
    self.syncJSONLCapability = syncJSONLCapability
}
```

Pass `supportsSyncJSONL: syncJSONLCapability()` to `execute`. In the `.sync` branch use:

```swift
for try await event in service.sync(
    worktreePath: worktreePath,
    supportsJSONL: supportsSyncJSONL
) {
    onSyncEvent(event)
}
```

Update `RecordingGGMutationExecutor` to record `[Bool]` capability values, update the harness with an injected capability box, and assert a sync forwards both true and false values. Update all direct test calls to `GGService.sync` with an explicit Boolean.

- [ ] **Step 6: Run the focused capability, service, and coordinator tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/GGAvailabilityTests \
  -only-testing:AlasTests/GGServiceActionsTests \
  -only-testing:AlasTests/GGMutationCoordinatorTests \
  -only-testing:AlasTests/RightPaneGGStackTests test
```

Expected: PASS, with runner call histories proving there is no per-sync help subprocess.

- [ ] **Step 7: Commit cached output-mode selection**

```bash
git status --short
git add Alas/Sources/Integrations/GG/GGMutationModels.swift \
  Alas/Sources/Integrations/GG/GGService.swift \
  Alas/Sources/Integrations/GG/GGMutationCoordinator.swift \
  AlasTests/Integrations/GGAvailabilityTests.swift \
  AlasTests/Integrations/GGServiceActionsTests.swift \
  AlasTests/Integrations/GGMutationCoordinatorTests.swift \
  AlasTests/RightPaneGGStackTests.swift
git commit -m "perf(gg): cache sync streaming capability"
```

---

### Task 3: Reduce sync events into compact stable progress

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGStackActionState.swift:27-66`
- Modify: `Alas/Sources/Integrations/GG/GGStackReadinessModel.swift:52-263`
- Test: `AlasTests/Integrations/GGStackActionStateTests.swift:5-65`
- Test: `AlasTests/Integrations/GGStackReadinessModelTests.swift:375-416`
- Test: `AlasTests/Integrations/GGMutationCoordinatorTests.swift:482-555,1183-1193`

**Interfaces:**
- Consumes: the extended `GGSyncEvent` contract from Task 1 and the existing `GGStackActionState` mutation lifecycle.
- Produces: `GGSyncProgressPresentation`, `GGSyncProgressPresentation.Row`, and `GGStackReadinessModel.syncProgress` for Task 4.

- [ ] **Step 1: Write failing action-lifecycle tests**

Replace the old expectation that unrelated actions leave hidden sync events behind. Require clearing at the next action boundary while retaining a failed attempt while idle:

```swift
@Test func beginningAnyLaterActionClearsRetainedSyncProgress() {
    let state = GGStackActionState()
    _ = state.beginAction(.sync)
    state.appendSyncEvent(.start(totalEntries: 1))
    state.appendSyncEvent(.error(position: 1, operation: "push", message: "push failed"))
    state.endAction(.sync)
    #expect(!state.syncProgress.isEmpty)

    _ = state.beginAction(.land)
    #expect(state.syncProgress.isEmpty)
}
```

Keep `recordSummary`'s successful-sync clearing expectation intact.

- [ ] **Step 2: Write failing pure reducer tests**

Replace append-only `progressRows` tests with exact presentation assertions:

```swift
@Test func syncWithoutEventsShowsImmediatePreparingStatus() {
    let action = GGStackActionState()
    _ = action.beginAction(.sync)

    let model = GGStackReadinessModel.make(
        stack: stack([entry(position: 1, prState: .open)]),
        action: action
    )

    #expect(model.syncProgress == GGSyncProgressPresentation(
        liveStatus: "Preparing sync…",
        showsSpinner: true,
        rows: []
    ))
}

@Test func syncProgressUpdatesOneStableRowPerPosition() throws {
    let action = GGStackActionState()
    _ = action.beginAction(.sync)
    action.appendSyncEvent(.start(totalEntries: 2))
    action.appendSyncEvent(.entryStarted(position: 2, title: "Second"))
    action.appendSyncEvent(.pushDone(position: 2, forced: false))
    action.appendSyncEvent(.prUpdated(position: 2, prNumber: 22, action: "updated"))
    action.appendSyncEvent(.entryStarted(position: 1, title: "First"))
    action.appendSyncEvent(.pushDone(position: 1, forced: false))
    action.appendSyncEvent(.prCreated(position: 1, prNumber: 11, prURL: nil, draft: false))

    let progress = try #require(GGStackReadinessModel.make(
        stack: stack([entry(position: 1, prState: nil), entry(position: 2, prState: nil)]),
        action: action
    ).syncProgress)
    #expect(progress.rows == [
        .init(position: 1, text: "[1] Pushed · PR #11 created"),
        .init(position: 2, text: "[2] Pushed · PR #22 updated"),
    ])
    #expect(progress.liveStatus == "Syncing 2 of 2 commits…")
}
```

Add separate cases for:

```swift
.prUpdated(position: 1, prNumber: 7, action: "unchanged")
// row: "[1] PR #7 up to date"

.prSkippedClosed(position: 1, prNumber: 7)
// row: "[1] PR #7 already closed"

.error(position: 1, operation: "push", message: "push failed")
// row: "[1] Failed to push", liveStatus nil, showsSpinner false
```

Also assert paused sync retains rows, a terminal summary removes the live line, and an idle failed sync remains relevant while `lastError` is set.

- [ ] **Step 3: Run state and reducer tests and confirm they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/GGStackActionStateTests \
  -only-testing:AlasTests/GGStackReadinessModelTests test
```

Expected: compilation failures for `GGSyncProgressPresentation` and `syncProgress`.

- [ ] **Step 4: Clear prior progress at the next action boundary**

Change `beginAction` so clearing occurs before the new in-flight value is published:

```swift
func beginAction(_ action: GGStackActionKind) -> Bool {
    guard inFlightAction == nil else { return false }
    if !syncProgress.isEmpty { syncProgress = [] }
    if lastError != nil { lastError = nil }
    if lastActionSummary != nil { lastActionSummary = nil }
    inFlightAction = action
    return true
}
```

Remove the now-redundant progress and error clearing from `GGMutationCoordinator.applyReserved`. Do not clear progress in `endAction`; failure and pause handling need it after the process exits. Successful sync continues clearing only after `syncSummaryLine` confirms `.summary`.

- [ ] **Step 5: Define stable progress presentation types**

In `GGStackReadinessModel.swift`, add:

```swift
struct GGSyncProgressPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        let position: Int
        let text: String
        var id: Int { position }
    }

    let liveStatus: String?
    let showsSpinner: Bool
    let rows: [Row]
}
```

Replace `let progressRows: [String]` with:

```swift
let syncProgress: GGSyncProgressPresentation?
```

Update the stack-recovery fallback initializer to use `syncProgress: nil`.

- [ ] **Step 6: Implement the pure event reducer**

Implement this exact private reducer boundary:

```swift
private struct SyncEntryProgress {
    var title: String?
    var didPush = false
    var row: String?
}

private static func makeSyncProgress(
    events: [GGSyncEvent],
    isInFlight: Bool
) -> GGSyncProgressPresentation {
    var entries: [Int: SyncEntryProgress] = [:]
    var completed: Set<Int> = []
    var totalEntries: Int?
    var liveStatus: String? = events.isEmpty && isInFlight ? "Preparing sync…" : nil
    var sawSummary = false
    var hasTerminalError = false

    func titledStatus(_ verb: String, position: Int) -> String {
        guard let title = entries[position]?.title else { return "\(verb) [\(position)]…" }
        return "\(verb) [\(position)] \(title)…"
    }

    func countStatus() -> String {
        guard let totalEntries else { return "Finishing sync…" }
        return "Syncing \(completed.count) of \(totalEntries) commit\(totalEntries == 1 ? "" : "s")…"
    }

    for event in events {
        switch event {
        case .start(let total):
            totalEntries = total
            liveStatus = "Syncing 0 of \(total) commit\(total == 1 ? "" : "s")…"
        case .entryStarted(let position, let title):
            entries[position, default: .init()].title = title
            liveStatus = "Syncing [\(position)] \(title)…"
        case .pushStarted(let position):
            liveStatus = titledStatus("Pushing", position: position)
        case .pushDone(let position, _):
            entries[position, default: .init()].didPush = true
            entries[position, default: .init()].row = "[\(position)] Pushed"
            liveStatus = titledStatus("Finishing", position: position)
        case .prCreated(let position, let number, _, _):
            entries[position, default: .init()].row = "[\(position)] Pushed · PR #\(number) created"
            completed.insert(position)
            liveStatus = countStatus()
        case .prUpdated(let position, let number, let action):
            let result = action == "updated" ? "updated" : "up to date"
            let pushed = entries[position]?.didPush == true ? "Pushed · " : ""
            entries[position, default: .init()].row = "[\(position)] \(pushed)PR #\(number) \(result)"
            completed.insert(position)
            liveStatus = countStatus()
        case .prSkippedClosed(let position, let number):
            entries[position, default: .init()].row = "[\(position)] PR #\(number) already closed"
            completed.insert(position)
            liveStatus = countStatus()
        case .error(let position, let operation, _):
            if let position {
                let failure = operation == "push" ? "Failed to push" : "Failed"
                entries[position, default: .init()].row = "[\(position)] \(failure)"
            }
            liveStatus = nil
            hasTerminalError = true
        case .summary:
            liveStatus = nil
            sawSummary = true
        }
    }

    if !isInFlight { liveStatus = nil }
    return GGSyncProgressPresentation(
        liveStatus: liveStatus,
        showsSpinner: isInFlight && !sawSummary && !hasTerminalError,
        rows: entries.compactMap { position, entry in
            entry.row.map { .init(position: position, text: $0) }
        }.sorted { $0.position < $1.position }
    )
}
```

For an in-flight sync with no events, the initialization returns `Preparing sync…`. For paused sync or retained failed progress, reduction keeps rows but the final `!isInFlight` guard prevents a stale live line or spinner. A sync is relevant when any of these is true:

```swift
inFlight == .sync
    || action.pausedOperation?.pausedBy == .sync
    || (inFlight == nil && action.lastError != nil && !action.syncProgress.isEmpty)
```

Build the model field with:

```swift
syncProgress: syncIsRelevant
    ? makeSyncProgress(events: action.syncProgress, isInFlight: inFlight == .sync)
    : nil
```

- [ ] **Step 7: Add coordinator coverage for immediate preparation and failure retention**

Use `startApplying` to inspect the synchronous reservation before its task advances:

```swift
@Test func reservingSyncImmediatelyPublishesPreparingFeedback() async throws {
    let harness = GGMutationHarness(stacks: [stack(head: "a")])
    harness.service.blockExecution = true
    let task = try #require(harness.coordinator.startApplying(.sync, confirmedAgainst: nil))

    let model = GGStackReadinessModel.make(
        stack: try #require(harness.stacks[0].stack),
        action: harness.actionState
    )
    #expect(model.syncProgress?.liveStatus == "Preparing sync…")

    try await waitUntil { !harness.service.requests.isEmpty }
    harness.service.resumeExecution()
    try await task.value
}
```

Extend the streamed-error test to emit a successful row before the positional error, then assert `syncProgress` remains non-empty after `apply` throws and the readiness model exposes the completed and failed rows without a spinner. Keep `remoteMutationRefreshesEveryAffectedSurface` proving success clears progress.

- [ ] **Step 8: Run state, reducer, and coordinator tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/GGStackActionStateTests \
  -only-testing:AlasTests/GGStackReadinessModelTests \
  -only-testing:AlasTests/GGMutationCoordinatorTests test
```

Expected: PASS.

- [ ] **Step 9: Commit compact progress reduction**

```bash
git status --short
git add Alas/Sources/Integrations/GG/GGStackActionState.swift \
  Alas/Sources/Integrations/GG/GGStackReadinessModel.swift \
  Alas/Sources/Integrations/GG/GGMutationCoordinator.swift \
  AlasTests/Integrations/GGStackActionStateTests.swift \
  AlasTests/Integrations/GGStackReadinessModelTests.swift \
  AlasTests/Integrations/GGMutationCoordinatorTests.swift
git commit -m "feat(gg): show compact sync progress"
```

---

### Task 4: Render compact progress and verify the complete change

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGStackDrawer.swift:55-92,265-302`
- Test: `AlasTests/RightPaneGGStackTests.swift:764-793`
- Verify all files changed in Tasks 1-4.

**Interfaces:**
- Consumes: `GGStackReadinessModel.syncProgress`, `GGSyncProgressPresentation.liveStatus`, `.showsSpinner`, and stable `.rows` from Task 3.
- Produces: the final drawer behavior; no new interface is consumed by later tasks.

- [ ] **Step 1: Update the drawer-facing presentation test first**

Replace the old append-only terminology assertion with exact compact state:

```swift
@Test func ggOwnedPresentationUsesCommitTerminology() throws {
    let action = GGStackActionState()
    _ = action.beginAction(.sync)
    action.appendSyncEvent(.start(totalEntries: 2))
    action.appendSyncEvent(.entryStarted(position: 1, title: "First"))
    action.appendSyncEvent(.pushDone(position: 1, forced: false))
    action.appendSyncEvent(.prCreated(position: 1, prNumber: 7, prURL: nil, draft: false))
    let stack = GGStack(
        name: "feature", base: "main", totalCommits: 2, syncedCommits: 0,
        currentPosition: 2, behindBase: 0, entries: []
    )

    let drawer = GGStackReadinessModel.make(stack: stack, action: action)
    let progress = try #require(drawer.syncProgress)
    #expect(progress.liveStatus == "Syncing 1 of 2 commits…")
    #expect(progress.rows.map(\.text) == ["[1] Pushed · PR #7 created"])

    let typedStrings = drawer.facts.map(\.label)
        + progress.rows.map(\.text)
        + [progress.liveStatus ?? "", GGInboxTabView.commitCountLabel(2)]
        + [CommitRow.ggCheckoutTitle, GGMutationConfirmation.clean(mergedCommits: 2).message]
    #expect(typedStrings.allSatisfy {
        !$0.lowercased().contains("entry") && !$0.lowercased().contains("entries")
    })
}
```

Expected before implementation: compilation failures because the drawer model still exposes `progressRows`.

- [ ] **Step 2: Render the live line and stable rows**

Change the recovery-model initializer to `syncProgress: nil`. Replace all `progressRows` branches with an optional compact progress surface. Keep paused recovery controls visible after progress:

```swift
if model.isPaused {
    if let progress = model.syncProgress { syncProgressView(progress) }
    Text("A gg operation is paused on conflicts. Resolve them in the Conflicts section, then Continue — or Abort to roll back.")
    // existing error, actions, details, and facts
} else if let progress = model.syncProgress {
    syncProgressView(progress)
    if let error = rps.ggActionState.lastError {
        Text(error)
            .font(.system(size: 11))
            .foregroundColor(theme.color("warn"))
            .lineLimit(3)
    }
} else {
    // existing summary, error, actions, details, and facts
}
```

Render the compact state with position-based identity:

```swift
private func syncProgressView(_ progress: GGSyncProgressPresentation) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        if let status = progress.liveStatus {
            HStack(spacing: 6) {
                if progress.showsSpinner {
                    Spinner(lineWidth: 1.4, duration: 0.8)
                        .frame(width: 10, height: 10)
                }
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
        }
        ForEach(progress.rows) { row in
            Text(row.text)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
        }
    }
}
```

Do not use enumerated offsets as identity; `Row.id == position` keeps a commit's view stable when its text upgrades.

- [ ] **Step 3: Run all focused sync-feedback tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/GGActionEventsTests \
  -only-testing:AlasTests/GGAvailabilityTests \
  -only-testing:AlasTests/GGServiceActionsTests \
  -only-testing:AlasTests/GGStackActionStateTests \
  -only-testing:AlasTests/GGStackReadinessModelTests \
  -only-testing:AlasTests/GGMutationCoordinatorTests \
  -only-testing:AlasTests/RightPaneGGStackTests test
```

Expected: PASS.

- [ ] **Step 4: Run formatting and project generation checks**

Run:

```bash
rtk swiftformat --lint Alas/Sources/Integrations/GG AlasTests/Integrations AlasTests/RightPaneGGStackTests.swift
rtk xcodegen
git status --short
```

Expected: SwiftFormat lint passes. `xcodegen` completes and does not create an unintended project-file diff because no source membership changed. If it normalizes an already-stale project file, inspect that diff and do not include unrelated regeneration without user approval.

- [ ] **Step 5: Run the repository-required build and full test suite serially**

Run the build first and wait for it to finish:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

Then run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0 with the full test suite passing. If the run stalls without an `xctest` process, report it as incomplete rather than green and preserve the focused-test evidence.

- [ ] **Step 6: Inspect scope and commit the drawer integration**

```bash
git status --short
git diff --check
git diff --stat HEAD
git diff -- Alas/Sources/Integrations/GG/GGStackDrawer.swift AlasTests/RightPaneGGStackTests.swift
git add Alas/Sources/Integrations/GG/GGStackDrawer.swift AlasTests/RightPaneGGStackTests.swift
git commit -m "feat(gg): render stable sync feedback"
```

- [ ] **Step 7: Verify final repository state**

```bash
git status --short --branch
git log --oneline --decorate -5
git ls-files docs/superpowers/specs/2026-07-31-progressive-gg-sync-feedback-design.md \
  docs/superpowers/plans/2026-07-31-progressive-gg-sync-feedback.md
```

Expected: clean worktree, the design and plan are tracked, and the implementation consists of the narrow commits described above.
