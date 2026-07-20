# Alas Native GG Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make GG projects fully operable from Alas by adding GG-aware change preparation, commit and stack mutations, native Split/Reorder flows, config-aware sync behavior, and durable Undo presentation.

**Architecture:** UI surfaces emit typed GG intents to one per-worktree `GGMutationCoordinator`; the coordinator performs fresh preflight, serializes mutations, delegates every process call to `GGService`, and refreshes stack, Git changes, provider review, topology, and inbox state according to mutation scope. Existing non-GG review behavior stays unchanged, while GG-specific presentation models keep command construction and safety policy out of SwiftUI views.

**Tech Stack:** Swift 5.9+, SwiftUI for macOS, Swift Observation, Swift Testing, `Process` through `GGCommandRunning`, XcodeGen, GG JSON command contracts.

## Global Constraints

- Implement in the existing isolated Alas GG stack worktree and keep one logical change per commit.
- Treat the approved design in `docs/superpowers/specs/2026-07-20-gg-native-workflow-integration-design.md` as the product contract.
- Preserve the existing non-GG Prepare, local Review Commit, review-loop, commit-editor, and Git context-menu behavior.
- Keep `GGService` as the only process boundary; views and presentation models must not build GG argument arrays.
- Route every mutating GG action through one `GGMutationCoordinator` per worktree.
- Never stage, stash, abort, retry, switch branches, or roll back remote state implicitly.
- Do not expose GG `--force` or `--ignore-immutable` options.
- Use `commit` or `stack commit` in Alas-owned UI; retain `entry` only in internal wire/model names such as `GGStackEntry`.
- Amend and Absorb operate on staged changes only and remain disabled with `Stage changes first` when the index is empty.
- Native Split is capability-gated on GG supporting both `split --describe` and `split --plan-json`, and Amend is capability-gated on `sc --staged-only`. Older GG versions retain actions that do not depend on a missing native-client capability; Alas never falls back to plain `sc` for Amend.
- Native Split shows non-textual files as read-only remainder content; protocol v1 never lets Alas assign them to the first commit.
- Creating an Unstack result without a worktree is capability-gated on `gg unstack --keep-current`; older GG versions retain the default-on worktree path.
- Regenerate `Alas.xcodeproj` with `xcodegen` after adding Swift files and commit `Alas.xcodeproj/project.pbxproj` with the corresponding source change.
- Write tests with Swift Testing (`import Testing`), not XCTest.
- Before each implementation commit, run the focused tests named by that task. Before completion, run the full build and test commands from `AGENTS.md`.

---

## File Map

- Create `Alas/Sources/Integrations/GG/GGMutationModels.swift`: typed mutation requests/results, effective config, capabilities, and Undo candidate.
- Create `Alas/Sources/Integrations/GG/GGMutationCoordinator.swift`: fresh preflight, serialization, command execution, refreshes, paused state, and Undo eligibility.
- Create `Alas/Sources/Integrations/GG/GGUndoMarkerStore.swift`: persisted per-worktree identity for the last Alas-initiated local operation.
- Create `Alas/Sources/Integrations/GG/GGCommitMenuModel.swift`: pure commit-scoped menu construction and disabled reasons.
- Create `Alas/Sources/Integrations/GG/GGUnstackSheet.swift`: native Split Stack confirmation and result presentation.
- Create `Alas/Sources/Integrations/GG/GGSplitCommitModel.swift`: structured Split loading, editing, validation, stale-plan preservation, and apply.
- Create `Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift`: hunk selection, two messages, and two previews.
- Create `Alas/Sources/Integrations/GG/GGReorderSheet.swift`: native mutable-region ordering UI.
- Create `Alas/Sources/Integrations/GG/GGRestackSheet.swift`: dry-run preview and explicit Restack apply.
- Modify the existing GG config, availability, service, stack state, drawer, inbox, right-pane, Prepare card, commit-menu, tab, and app presentation files named in the tasks below.
- Add focused test files under `AlasTests/Integrations`, `AlasTests/Right`, and `AlasTests/Center` for each new model or coordinator.
- Modify `docs/manual-test.md`: native GG acceptance scenarios and older-GG fallback checks.

### Task 1: Resolve Effective Config And Workflow Capabilities

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGMutationModels.swift`
- Modify: `Alas/Sources/Integrations/GG/GGConfigReader.swift`
- Modify: `Alas/Sources/Integrations/GG/GGService.swift`
- Modify: `AlasTests/Integrations/GGConfigReaderTests.swift`
- Modify: `AlasTests/Integrations/GGAvailabilityTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` (generated)

**Interfaces:**

```swift
struct GGEffectiveConfig: Equatable, Sendable {
    var syncAutoRebase: Bool
    var syncBehindThreshold: Int
    static let defaults = GGEffectiveConfig(syncAutoRebase: false, syncBehindThreshold: 1)
}

struct GGCapabilities: Equatable, Sendable {
    var structuredSplit: Bool
    var keepCurrentUnstack: Bool
    var stagedOnlyAmend: Bool
}
```

- `GGConfigReader.effectiveConfig(repoPath:globalConfigPath:)` mirrors GG's defaults-block semantics: when a local config exists, missing or malformed supported keys use hardcoded defaults rather than global values; otherwise global values fall back to hardcoded defaults.
- `GGService.probeCapabilities()` runs `gg split --help`, `gg unstack --help`, and `gg sc --help`. `structuredSplit` requires both Split flags, `keepCurrentUnstack` requires `--keep-current`, and `stagedOnlyAmend` requires `--staged-only`.
- `GGAvailability` caches the capabilities with the detected executable/version result and invalidates them when that result changes.

- [ ] **Step 1: Write failing config and capability tests**

Add tests for defaults, global values, local defaults-block replacement, malformed local values falling back to hardcoded defaults, all required help flags, missing flags, and command failure. Use an injected `GGCommandRunning` fake for help output; do not invoke the installed GG binary.

Extend the existing `makeRepo`/`makeGlobal` fixtures with these assertions:

```swift
@Test func localDefaultsBlockDoesNotInheritMissingGlobalKeys() throws {
    let repo = try makeRepo(configJSON: #"{"defaults":{"sync_auto_rebase":true}}"#)
    let global = try makeGlobal(configJSON: #"{"defaults":{"sync_auto_rebase":false,"sync_behind_threshold":4}}"#)

    #expect(GGConfigReader.effectiveConfig(repoPath: repo, globalConfigPath: global)
        == GGEffectiveConfig(syncAutoRebase: true, syncBehindThreshold: 1))
}

@Test func workflowCapabilitiesRequireTheirHelpFlags() async {
    let service = GGService(runner: HelpGGRunner(
        split: "--describe --plan-json", unstack: "--keep-current", sc: "--staged-only"
    ))
    #expect(await service.probeCapabilities()
        == GGCapabilities(structuredSplit: true, keepCurrentUnstack: true, stagedOnlyAmend: true))
    let oldService = GGService(runner: HelpGGRunner(split: "--describe", unstack: "", sc: ""))
    #expect(await oldService.probeCapabilities()
        == GGCapabilities(structuredSplit: false, keepCurrentUnstack: false, stagedOnlyAmend: false))
}
```

Define `HelpGGRunner` in `GGAvailabilityTests.swift` as a `GGCommandRunning` fake that returns the supplied Split, Unstack, or SC help for the matching argument array and exit `127` for every other call.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGConfigReaderTests -only-testing:AlasTests/GGAvailabilityTests test
```

Expected: FAIL because effective config and structured Split capability are absent.

- [ ] **Step 3: Implement config resolution and capability probing**

Decode only `sync_auto_rebase` and `sync_behind_threshold` for presentation. Do not duplicate `sync_draft`, lint, title, or description policy in Alas; GG still applies those when `gg sync` runs.

Probe help through `GGCommandRunning`, tolerate older GG errors by returning `structuredSplit: false`, and keep GG availability itself usable. Add equality coverage so unchanged probes do not cause observable churn.

Implement the merge and probe with these decision rules:

```swift
static func effectiveConfig(repoPath: String, globalConfigPath: String?) -> GGEffectiveConfig {
    let localPath = repoConfigPath(repoPath)
    if fileExists(localPath) {
        let local = readDefaults(at: localPath)
        return GGEffectiveConfig(
            syncAutoRebase: local?.syncAutoRebase ?? false,
            syncBehindThreshold: local?.syncBehindThreshold ?? 1
        )
    }
    let global = globalConfigPath.flatMap { readDefaults(at: $0) }
    return GGEffectiveConfig(
        syncAutoRebase: global?.syncAutoRebase ?? false,
        syncBehindThreshold: global?.syncBehindThreshold ?? 1
    )
}

func probeCapabilities() async -> GGCapabilities {
    let split = try? await runner.run(args: ["split", "--help"], cwd: nil)
    let unstack = try? await runner.run(args: ["unstack", "--help"], cwd: nil)
    let sc = try? await runner.run(args: ["sc", "--help"], cwd: nil)
    return .init(
        structuredSplit: split?.exitCode == 0
            && split?.stdout.contains("--describe") == true
            && split?.stdout.contains("--plan-json") == true,
        keepCurrentUnstack: unstack?.exitCode == 0
            && unstack?.stdout.contains("--keep-current") == true,
        stagedOnlyAmend: sc?.exitCode == 0
            && sc?.stdout.contains("--staged-only") == true
    )
}
```

- [ ] **Step 4: Regenerate and rerun focused tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGConfigReaderTests -only-testing:AlasTests/GGAvailabilityTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit config and capability support**

```bash
rtk git add Alas/Sources/Integrations/GG/GGMutationModels.swift Alas/Sources/Integrations/GG/GGConfigReader.swift Alas/Sources/Integrations/GG/GGService.swift AlasTests/Integrations/GGConfigReaderTests.swift AlasTests/Integrations/GGAvailabilityTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(gg): detect workflow configuration and capabilities"
```

### Task 2: Add Typed GG Mutation Commands And JSON Results

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGMutationModels.swift`
- Modify: `Alas/Sources/Integrations/GG/GGService.swift`
- Modify: `AlasTests/Integrations/GGServiceActionsTests.swift`
- Create: `AlasTests/Integrations/GGMutationModelsTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` (generated)

**Interfaces:**

Add Codable DTOs with explicit schema-version validation for Drop, Unstack, Restack, Undo, and structured Split. Expose service methods with these argument contracts:

```swift
func amendCurrent(worktreePath: String) async throws
func absorbStaged(worktreePath: String) async throws
func drop(worktreePath: String, target: String) async throws -> GGDropResult
func unstack(worktreePath: String, target: String, name: String, createWorktree: Bool) async throws -> GGUnstackResult
func reorder(worktreePath: String, order: [String]) async throws
func restack(worktreePath: String, dryRun: Bool) async throws -> GGRestackResult
func rebase(worktreePath: String, target: String?) async throws
func listUndoOperations(worktreePath: String, limit: Int) async throws -> [GGOperationSummary]
func undo(worktreePath: String, operationID: String) async throws -> GGUndoResult
func describeSplit(worktreePath: String, target: String) async throws -> GGSplitDescription
func applySplit(worktreePath: String, planURL: URL) async throws -> GGSplitApplyResult
```

The public Unstack result is normalized across GG versions:

```swift
struct GGUnstackResult: Equatable, Sendable {
    var originalStack: String
    var newStack: String
    var movedCommits: [GGUnstackCommit]
    var worktreePath: String?
    var currentStack: String
}
```

Extend the existing error enum with stable categories used by the coordinator and editors:

```swift
case immutableTargets(message: String)
case dirtyWorkingTree(message: String)
case staleTarget(message: String)
case staleSplitPlan(message: String)
case pausedConflict(message: String)
case partialMutation(message: String)
case undoRefused(message: String, hint: String?)
```

Add the private envelope used before decoding command-specific payloads:

```swift
private struct GGSchemaVersion: Decodable {
    let version: Int
}
```

Decode `current_stack` as optional on the wire. For `createWorktree: true`, an older response may infer `currentStack = originalStack`; for `createWorktree: false`, the service has sent `--keep-current` and must require `current_stack == original_stack`.

Command construction must be exact: capability-gated Amend `sc --staged-only` from the paired git-gud native client protocol, with no plain-`sc` fallback; Absorb `absorb -s`; Drop `drop <target> --yes --json`; Unstack `unstack --target <target> --name <name> --no-tui --json` plus `--worktree` when requested or capability-gated `--keep-current` from that paired protocol when not; Reorder `reorder --order <comma-separated IDs>`; Restack `restack --json` plus `--dry-run`; Rebase `rebase [target]`; Undo list `undo --list --json --limit <n>`; Undo apply `undo <id> --json`; Split describe `split --describe --commit <target> --json`; Split apply `split --plan-json <path> --json`. Update Clean to `clean --all --json` if it does not already use that shape.

- [ ] **Step 1: Write failing service argument and decoding tests**

For every method, assert the exact executable arguments and working directory. Add fixtures for successful JSON, unsupported schema versions, malformed payloads, GG refusal errors, and missing required result fields. Verify `createWorktree: false` never emits `--worktree` and no method emits `--force`.

Use the existing `RecordingGGRunner` and add concrete assertions like:

```swift
@Test func unstackWithoutWorktreeUsesNoninteractiveJSONArguments() async throws {
    let runner = RecordingGGRunner(stdout: #"{"version":1,"unstack":{"original_stack":"feature","new_stack":"api","moved_entries":[],"worktree_path":null,"current_stack":"feature"}}"#)
    _ = try await GGService(runner: runner).unstack(
        worktreePath: "/repo", target: "change-2", name: "api", createWorktree: false
    )
    #expect(runner.calls == [["unstack", "--target", "change-2", "--name", "api", "--no-tui", "--json", "--keep-current"]])
    #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
    #expect(!runner.lastArgs.contains("--force"))
}

@Test func splitRejectsUnknownSchemaVersion() async {
    let runner = RecordingGGRunner(stdout: #"{"version":2}"#)
    await #expect(throws: GGServiceError.self) {
        try await GGService(runner: runner).describeSplit(worktreePath: "/repo", target: "change-2")
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGServiceActionsTests -only-testing:AlasTests/GGMutationModelsTests test
```

Expected: FAIL because the typed methods and DTOs do not exist.

- [ ] **Step 3: Implement typed commands and strict decoding**

Keep all argument arrays private to `GGService`. Decode snake-case payloads with `JSONDecoder`, reject unsupported versions with an actionable update message, and preserve GG's typed refusal text for UI presentation. Do not infer success from exit code when a required JSON result is absent.

Use one strict helper for the version envelope:

```swift
private func decodeVersioned<T: Decodable>(_ type: T.Type, from result: ProcessResult) throws -> T {
    let data = Data(result.stdout.utf8)
    let version = try JSONDecoder().decode(GGSchemaVersion.self, from: data).version
    guard version == 1 else { throw GGServiceError.unsupportedSchema(version) }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: data)
}

func drop(worktreePath: String, target: String) async throws -> GGDropResult {
    let result = try await runAction(
        ["drop", target, "--yes", "--json"], cwd: URL(fileURLWithPath: worktreePath)
    )
    return try decodeVersioned(GGDropResponse.self, from: result).drop
}
```

Split plan files are created by the caller with owner-only permissions, passed by URL, and always removed with `defer`; the service only invokes GG and decodes the result.

- [ ] **Step 4: Regenerate and rerun focused tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGServiceActionsTests -only-testing:AlasTests/GGMutationModelsTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit the typed process boundary**

```bash
rtk git add Alas/Sources/Integrations/GG/GGMutationModels.swift Alas/Sources/Integrations/GG/GGService.swift AlasTests/Integrations/GGServiceActionsTests.swift AlasTests/Integrations/GGMutationModelsTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(gg): add typed stack mutation commands"
```

### Task 3: Centralize Mutation Lifecycle And Refreshes

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGMutationCoordinator.swift`
- Create: `Alas/Sources/Integrations/GG/GGUndoMarkerStore.swift`
- Modify: `Alas/Sources/Integrations/GG/GGMutationModels.swift`
- Modify: `Alas/Sources/Integrations/GG/GGStackModels.swift`
- Modify: `Alas/Sources/Integrations/GG/GGStackActionState.swift`
- Modify: `Alas/Sources/Integrations/GG/GGInboxStore.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift`
- Modify: `Alas/Sources/Right/RightPaneStore.swift`
- Modify: `Alas/Sources/App/RootView.swift`
- Create: `AlasTests/Integrations/GGMutationCoordinatorTests.swift`
- Create: `AlasTests/Integrations/GGUndoMarkerStoreTests.swift`
- Modify: `AlasTests/Integrations/GGActionEventsTests.swift`
- Modify: `AlasTests/Integrations/GGInboxStoreTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` (generated)

**Interfaces:**

```swift
enum GGMutationRequest: Equatable, Sendable {
    case amendCurrent
    case absorbStaged
    case checkout(target: String)
    case drop(target: String)
    case unstack(target: String, name: String, createWorktree: Bool)
    case reorder(order: [String])
    case restack
    case rebase(target: String?)
    case sync
    case land(target: String)
    case clean
    case continueOperation
    case abortOperation
    case undo(operationID: String)
    case applySplit(planURL: URL, target: GGSplitTargetIdentity, planToken: String)
}

struct GGStackIdentity: Equatable, Sendable {
    var stackName: String
    var headSHA: String
    var operationID: String?
}

struct GGPreparedMutation: Equatable, Sendable {
    var request: GGMutationRequest
    var snapshot: GGStackIdentity
    var confirmation: GGMutationConfirmation?
}

enum GGMutationConfirmation: Equatable, Sendable {
    case drop(target: String, rewrittenDescendants: Int, hasOpenReview: Bool)
    case unstack(target: String, movedCommits: Int, lowerStack: String, newStack: String)
    case land(target: String, readyCommits: Int)
    case clean(mergedCommits: Int)
}

enum GGMutationError: Error, Equatable {
    case operationInFlight
    case staleConfirmation
    case immutableTarget(reason: String)
    case pausedOperation
}

protocol GGUndoMarkerStoring: Sendable {
    func operationID(worktreeId: String) -> String?
    func set(operationID: String, worktreeId: String)
    func clear(worktreeId: String)
}

final class GGUndoMarkerStore: GGUndoMarkerStoring {
    init(defaults: UserDefaults = .standard)
}

@MainActor
struct GGMutationContext {
    var loadFreshStack: () async throws -> GGStackSnapshot
    var refreshStack: () async -> Void
    var refreshGitChanges: () async -> Void
    var refreshProviderReviews: () async -> Void
    var refreshProjectTopology: () async -> Void
    var invalidateInbox: () -> Void
    var selectWorktreeAtPath: (String) async -> Void
}
```

`GGMutationCoordinator` owns exactly one active request. `prepare(_:)` loads fresh state and returns any required typed confirmation; `apply(_:confirmedAgainst:)` loads fresh state again, rejects a stale confirmation, calls `GGService`, records completion or paused-conflict state, refreshes in `defer`, and exposes the latest local undoable operation. Generalize `refreshProjectTopologyAfterGGClean` to `refreshProjectTopologyAfterGGMutation`. Add `GGInboxStore.invalidate(projectId:)` that expires freshness without discarding the last visible snapshot.

- [ ] **Step 1: Write failing coordinator lifecycle tests**

Cover request serialization, fresh preflight before confirmation and again before Apply, stale-confirmation rejection before process launch, immutable-target rejection, paused-operation gating, refresh after success, refresh after error, topology refresh only for results that can add/remove worktrees, Git/review refresh scope, inbox invalidation after stack or remote changes, and preservation of GG's conflict-paused state. Verify a second concurrent request is refused rather than queued invisibly.

The core stale-confirmation and refresh assertions are:

```swift
@Test func applyRechecksSnapshotAfterConfirmation() async throws {
    let harness = GGMutationHarness(stacks: [stack(head: "a"), stack(head: "b")])
    let prepared = try await harness.coordinator.prepare(.drop(target: "change-2"))

    await #expect(throws: GGMutationError.staleConfirmation) {
        try await harness.coordinator.apply(.drop(target: "change-2"), confirmedAgainst: prepared.snapshot)
    }
    #expect(harness.service.requests.isEmpty)
}

@Test func remoteMutationRefreshesEveryAffectedSurface() async throws {
    let harness = GGMutationHarness(stacks: [stack(head: "a"), stack(head: "a")])
    try await harness.coordinator.apply(.sync, confirmedAgainst: nil)
    #expect(harness.refreshes == [.stack, .gitChanges, .providerReviews, .inbox])
}
```

Define `GGMutationHarness`, `stack(head:)`, and its recording service/context in `GGMutationCoordinatorTests.swift`; it must vend snapshots in order and record each process request and refresh callback.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGMutationCoordinatorTests -only-testing:AlasTests/GGUndoMarkerStoreTests -only-testing:AlasTests/GGActionEventsTests -only-testing:AlasTests/GGInboxStoreTests test
```

Expected: FAIL because the coordinator and invalidation API do not exist.

- [ ] **Step 3: Implement the coordinator and migrate existing actions**

Expand `GGStackActionKind` for all mutation requests. Move existing Sync, Land, Clean, Continue, Abort, and Checkout execution from `RightPaneState` into the coordinator while retaining current confirmation presentation in `RootGGPresentationHandlers`. Keep `RightPaneState` responsible for binding observable state to its worktree, not for constructing GG commands.

The coordinator must preserve the two-phase identity check:

```swift
func prepare(_ request: GGMutationRequest) async throws -> GGPreparedMutation {
    guard activeRequest == nil else { throw GGMutationError.operationInFlight }
    let stack = try await context.loadFreshStack()
    return try preflight(request, stack: stack)
}

func apply(_ request: GGMutationRequest, confirmedAgainst snapshot: GGStackIdentity?) async throws {
    guard activeRequest == nil else { throw GGMutationError.operationInFlight }
    activeRequest = request
    defer { activeRequest = nil }
    let current = try await context.loadFreshStack()
    if let snapshot, snapshot != current.identity { throw GGMutationError.staleConfirmation }
    try preflight(request, snapshot: current)
    undoMarkerStore.clear(worktreeId: worktreeId)
    do {
        let result = try await execute(request, current: current)
        await refresh(after: request)
        recordUndoCandidate(from: result)
    } catch {
        await refresh(after: request)
        throw error
    }
}
```

Always refresh stack and Git state after a launched mutation, including partial failure. Refresh provider review state after remote mutations, invalidate Inbox after stack or remote mutations, and refresh topology after Clean or worktree-creating Unstack. If a zero-exit remote command returns malformed JSON, report the observed refreshed state rather than claiming the remote operation failed. Never auto-abort, auto-stash, or retry a stale-base Sync. A stale-base refusal refreshes and lets readiness choose Rebase on the next render.

- [ ] **Step 4: Regenerate and rerun focused tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGMutationCoordinatorTests -only-testing:AlasTests/GGUndoMarkerStoreTests -only-testing:AlasTests/GGActionEventsTests -only-testing:AlasTests/GGInboxStoreTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit centralized mutation orchestration**

```bash
rtk git add Alas/Sources/Integrations/GG/GGMutationCoordinator.swift Alas/Sources/Integrations/GG/GGUndoMarkerStore.swift Alas/Sources/Integrations/GG/GGMutationModels.swift Alas/Sources/Integrations/GG/GGStackModels.swift Alas/Sources/Integrations/GG/GGStackActionState.swift Alas/Sources/Integrations/GG/GGInboxStore.swift Alas/Sources/Right/RightPaneState.swift Alas/Sources/Right/RightPaneStore.swift Alas/Sources/App/RootView.swift AlasTests/Integrations/GGMutationCoordinatorTests.swift AlasTests/Integrations/GGUndoMarkerStoreTests.swift AlasTests/Integrations/GGActionEventsTests.swift AlasTests/Integrations/GGInboxStoreTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "refactor(gg): centralize mutation lifecycle"
```

### Task 4: Restore A GG-aware Prepare Card And Commit Terminology

**Files:**
- Modify: `Alas/Sources/Right/ChangesPreparationModel.swift`
- Modify: `Alas/Sources/Right/ChangesPreparationCard.swift`
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Modify: `Alas/Sources/Integrations/GG/GGStackDrawer.swift`
- Modify: `Alas/Sources/Integrations/GG/GGInboxTabView.swift`
- Modify: `Alas/Sources/Right/CommitRow.swift`
- Modify: `AlasTests/Right/ChangesPreparationModelTests.swift`
- Modify: `AlasTests/RightPaneGGStackTests.swift`

**Interfaces:**

Add a GG presentation variant with one primary command and three visible destinations:

```swift
enum GGChangesPreparationAction: Equatable {
    case newStackCommit
    case amendCurrent
    case absorbIntoStack
}
```

The primary action remains the existing `Review current changes`. `New stack commit` opens the existing draft commit editor and is enabled only when the worktree is checked out at the actual stack head. Amend and Absorb show staged statistics, dispatch through the coordinator, and are disabled with `Stage changes first` when the staged diff is empty.

- [ ] **Step 1: Write failing Prepare presentation tests**

Cover GG and non-GG card variants, all four GG actions, staged-only availability, actual-stack-head versus middle-commit checkout, a non-empty saved draft with no staged changes, and simultaneous visibility of the Prepare card and stack drawer. Add string assertions that typed drawer/inbox/progress/confirmation text says `commit`/`commits`, never `entry`/`entries`.

Add these cases to the existing model tests:

```swift
@Test func ggPreparationShowsReviewAndThreeDestinations() {
    let model = ChangesPreparationModel.makeGG(
        staged: .init(files: 2, insertions: 8, deletions: 3), hasDraft: false
    )
    #expect(model.primaryAction?.title == "Review current changes")
    #expect(model.ggActions.map(\.kind) == [.newStackCommit, .amendCurrent, .absorbIntoStack])
    #expect(model.ggActions.allSatisfy(\.isEnabled))
}

@Test func ggRewriteDestinationsRequireStagedChanges() {
    let model = ChangesPreparationModel.makeGG(staged: .zero, hasDraft: true)
    #expect(model.ggAction(.newStackCommit)?.isEnabled == true)
    #expect(model.ggAction(.amendCurrent)?.disabledReason == "Stage changes first")
    #expect(model.ggAction(.absorbIntoStack)?.disabledReason == "Stage changes first")
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ChangesPreparationModelTests -only-testing:AlasTests/RightPaneGGStackTests test
```

Expected: FAIL because GG mode still suppresses the card and lacks its action model.

- [ ] **Step 3: Implement the GG card and terminology changes**

Remove GG drawer state from `ChangesTabView.shouldShowChangesPreparationCard`. Render the approved clear hierarchy: full-width Review, then a stable three-action row for New/Amend/Absorb. Keep existing file staging controls unchanged and do not stage implicitly.

Keep the view structure explicit:

```swift
VStack(spacing: 8) {
    primaryReviewButton
        .frame(maxWidth: .infinity)
    HStack(spacing: 6) {
        ggDestinationButton(.newStackCommit)
        ggDestinationButton(.amendCurrent)
        ggDestinationButton(.absorbIntoStack)
    }
}
```

Replace Alas-owned visible `Entry`, `Entries`, and `Syncing N entries` strings across the drawer, inbox, commit row, and typed confirmations. Do not rename `GGStackEntry` or decoded GG keys.

- [ ] **Step 4: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ChangesPreparationModelTests -only-testing:AlasTests/RightPaneGGStackTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit GG-aware preparation**

```bash
rtk git add Alas/Sources/Right/ChangesPreparationModel.swift Alas/Sources/Right/ChangesPreparationCard.swift Alas/Sources/Right/ChangesTabView.swift Alas/Sources/Integrations/GG/GGStackDrawer.swift Alas/Sources/Integrations/GG/GGInboxTabView.swift Alas/Sources/Right/CommitRow.swift AlasTests/Right/ChangesPreparationModelTests.swift AlasTests/RightPaneGGStackTests.swift
rtk git commit -m "feat(gg): add stack-aware change preparation"
```

### Task 5: Add The GG Commit Submenu And Split Stack Flow

**Prerequisite:** Task 4 of `docs/superpowers/plans/2026-07-20-gg-native-client-protocols.md` supplies `--keep-current`. On older GG versions, Alas can ship this task with the Unstack worktree toggle locked on.

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGCommitMenuModel.swift`
- Create: `Alas/Sources/Integrations/GG/GGUnstackSheet.swift`
- Modify: `Alas/Sources/Right/CommitRow.swift`
- Modify: `Alas/Sources/Right/CommitsSectionView.swift`
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift`
- Modify: `Alas/Sources/Right/RightPaneStore.swift`
- Modify: `Alas/Sources/App/RootView.swift`
- Create: `AlasTests/Integrations/GGCommitMenuModelTests.swift`
- Modify: `AlasTests/CommitRowTests.swift`
- Modify: `AlasTests/RightPaneGGLandTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` (generated)

**Interfaces:**

`GGCommitMenuModel` returns this strict commit-scoped order with stable separators: Review PR/MR in Alas, Open PR/MR in Browser, Checkout Commit, Split Commit, Drop Commit, Split Stack Here, Land Through Here. It includes visibility, enabled state, and a concise disabled reason for each action. `CommitRow` accepts the model and one typed action callback instead of separate GG closures.

`GGUnstackSheet` owns editable derived stack name and `createWorktree = true`. Its confirmation names the selected commit, lower and destination stacks, and exact moved-commit count. On GG versions without `--keep-current`, the toggle remains on and disabled with `Update GG to create a stack without a worktree`.

- [ ] **Step 1: Write failing menu and Unstack tests**

Cover exact item order, PR versus MR labels, remote items hidden without a provider review, Checkout hidden for current commit, immutable and in-flight disabled reasons, Drop descendant/open-review warning, derived stack-name normalization, exact moved count, and the default-on worktree toggle.

The pure-menu expectation is:

```swift
@Test func mappedPullRequestCommitGetsStrictGGSubmenuOrder() {
    let model = GGCommitMenuModel.make(context: .fixture(provider: .github, isCurrent: false))
    #expect(model.items.map(\.action) == [
        .reviewProviderRequest, .openProviderRequest, nil,
        .checkout, .splitCommit, nil,
        .dropCommit, .unstackHere, .landThrough
    ])
    #expect(model.items.first?.title == "Review PR in Alas...")
}

@Test func unstackDefaultsToManagedWorktree() {
    let model = GGUnstackModel(target: .fixture(position: 3), stack: .fixture(count: 5))
    #expect(model.createWorktree)
    #expect(model.movedCommitCount == 3)
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGCommitMenuModelTests -only-testing:AlasTests/CommitRowTests -only-testing:AlasTests/RightPaneGGLandTests test
```

Expected: FAIL because the submenu model and Unstack presentation do not exist.

- [ ] **Step 3: Implement menu wiring and remote review routing**

Keep generic Git actions and the top-level local `Review Commit...` unchanged. Render one `Menu("GG")` for mapped stack commits. Route Review PR/MR through `AppState.cliOpenProviderReview(worktree:target:)`; route Open to the existing browser action. Route mutations to the coordinator, with Drop and Land using explicit confirmations.

Collapse row wiring to one typed callback:

```swift
CommitRow(
    commit: commit,
    ggMenu: GGCommitMenuModel.make(context: menuContext),
    onGGAction: { action in rightPaneState.handleGGCommitAction(action, commit: commit) }
)
```

The provider review action uses the mapped review number:

```swift
case .reviewProviderRequest(let number):
    _ = await appState.cliOpenProviderReview(worktree: worktree, target: String(number))
```

- [ ] **Step 4: Implement Split Stack result handling**

Submit Unstack through the coordinator. When GG returns a created worktree, refresh project topology and select that worktree. Without `--worktree`, keep the current lower stack checked out, invalidate/refresh GG Inbox, and report `New stack created without a worktree`; do not switch branches.

Handle the two result paths without inferring a branch change:

```swift
if let worktreePath = result.worktreePath {
    await context.refreshProjectTopology()
    await context.selectWorktreeAtPath(worktreePath)
} else {
    precondition(result.currentStack == result.originalStack)
    context.invalidateInbox()
    completionMessage = "New stack created without a worktree"
}
```

- [ ] **Step 5: Regenerate and run focused tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGCommitMenuModelTests -only-testing:AlasTests/CommitRowTests -only-testing:AlasTests/RightPaneGGLandTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit commit-scoped workflows**

```bash
rtk git add Alas/Sources/Integrations/GG/GGCommitMenuModel.swift Alas/Sources/Integrations/GG/GGUnstackSheet.swift Alas/Sources/Right/CommitRow.swift Alas/Sources/Right/CommitsSectionView.swift Alas/Sources/Right/ChangesTabView.swift Alas/Sources/Right/RightPaneState.swift Alas/Sources/Right/RightPaneStore.swift Alas/Sources/App/RootView.swift AlasTests/Integrations/GGCommitMenuModelTests.swift AlasTests/CommitRowTests.swift AlasTests/RightPaneGGLandTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(gg): add commit workflow menu"
```

### Task 6: Build The Native Split Commit Tab

**Prerequisite:** Tasks 1-3 of `docs/superpowers/plans/2026-07-20-gg-native-client-protocols.md` must be implemented and the resulting GG version must support both Split flags. Alas development can use protocol fixtures until that binary is installed.

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGSplitCommitModel.swift`
- Create: `Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift`
- Modify: `Alas/Sources/Center/Tab.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift`
- Create: `AlasTests/Integrations/GGSplitCommitModelTests.swift`
- Create: `AlasTests/Center/GGSplitTabsManagerTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` (generated)

**Interfaces:**

`GGSplitCommitModel` loads `GGSplitDescription`, stores target SHA/tree/GG ID and plan token, groups hunks by file, tracks `Set<String>` selected hunk IDs, and exposes two message fields plus first/remainder previews. Apply requires a non-empty selection, non-empty trimmed messages, and either unselected textual hunks or at least one non-textual remainder file.

Files in `description.nonTextualFiles` appear in a `Remainder only` group and are never added to `selectedHunkIDs`.

Add a codable/restorable tab case carrying only stable identity:

```swift
case ggSplitCommit(GGSplitCommitTabState)

struct GGSplitCommitTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let targetGGID: String?
    let targetSHA: String

    init(worktreeId: String, targetGGID: String?, targetSHA: String) {
        self.id = "gg-split:\(worktreeId):\(targetGGID ?? targetSHA)"
        self.worktreeId = worktreeId
        self.targetGGID = targetGGID
        self.targetSHA = targetSHA
    }
}
```

- [ ] **Step 1: Write failing model tests**

Cover initial Describe loading, file grouping, selection toggles, empty/all-selected refusal, independent message validation, first/remainder preview partitioning, and capability-disabled presentation. Simulate Apply returning stale plan and assert selected IDs and both messages remain intact.

```swift
@Test func staleApplyPreservesEditablePlan() async throws {
    let service = SplitServiceStub(description: .twoHunks, applyError: .staleSplitPlan)
    let model = GGSplitCommitModel(service: service, target: .fixture)
    try await model.load()
    model.selectedHunkIDs = [model.description.hunks[0].id]
    model.firstMessage = "Extract parser"
    model.remainderMessage = "Keep renderer"

    await #expect(throws: GGServiceError.staleSplitPlan(message: "stale split plan")) {
        try await model.apply()
    }
    #expect(model.selectedHunkIDs.count == 1)
    #expect(model.firstMessage == "Extract parser")
    #expect(model.remainderMessage == "Keep renderer")
}
```

- [ ] **Step 2: Write failing tab-manager tests**

Cover opening, focusing an existing Split tab for the same worktree/target, distinct targets, Codable round trip, and graceful restore when structured Split is unavailable.

```swift
@Test func openingSameSplitTargetFocusesExistingTab() {
    let tabs = TabsManager()
    let first = tabs.openGGSplitCommit(worktreeId: "wt", targetGGID: "change-2", targetSHA: "abc")
    let second = tabs.openGGSplitCommit(worktreeId: "wt", targetGGID: "change-2", targetSHA: "abc")
    #expect(first == second)
    #expect(tabs.tabs(for: "wt").filter { $0.id == first }.count == 1)
}
```

- [ ] **Step 3: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGSplitCommitModelTests -only-testing:AlasTests/GGSplitTabsManagerTests test
```

Expected: FAIL because the Split model and tab case do not exist.

- [ ] **Step 4: Implement the model and secure plan-file lifecycle**

Build the v1 plan directly from the Describe DTO. Write it atomically in a temporary directory with mode `0600`, call the coordinator, and delete it with `defer` after success or failure. On stale-plan refusal, reload only after explicit user action; do not discard edits or silently remap hunk IDs.

```swift
func apply() async throws {
    let plan = try validatedPlan()
    let url = try privatePlanWriter.write(plan, permissions: 0o600)
    defer { try? FileManager.default.removeItem(at: url) }
    try await coordinator.apply(
        .applySplit(planURL: url, target: plan.target, planToken: plan.planToken),
        confirmedAgainst: description.stackIdentity
    )
}
```

- [ ] **Step 5: Implement the native tab**

Use existing Alas diff parsing/rendering components for two stable preview panes. The selection pane lists files and hunk checkboxes; the editor exposes two message fields and fixed-size Apply/Cancel controls. Do not shell out to GG's TUI and do not duplicate patch application or history rewriting in Swift.

```swift
HStack(spacing: 0) {
    splitHunkSelection
        .frame(minWidth: 240, idealWidth: 300)
    VSplitView {
        splitPreview(title: "First commit", diff: model.firstPreview)
        splitPreview(title: "Remainder", diff: model.remainderPreview)
    }
}
```

When capabilities are absent, disable `Split Commit...` in the GG submenu with `Update GG to use native Split Commit`; do not hide or disable other GG actions.

- [ ] **Step 6: Regenerate and run focused tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGSplitCommitModelTests -only-testing:AlasTests/GGSplitTabsManagerTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit native Split**

```bash
rtk git add Alas/Sources/Integrations/GG/GGSplitCommitModel.swift Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift Alas/Sources/Center/Tab.swift Alas/Sources/Center/TabsManager.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/Right/RightPaneState.swift AlasTests/Integrations/GGSplitCommitModelTests.swift AlasTests/Center/GGSplitTabsManagerTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(gg): add native split commit editor"
```

### Task 7: Add Config-aware Drawer Actions, Reorder, Restack, And Undo

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGReorderSheet.swift`
- Create: `Alas/Sources/Integrations/GG/GGRestackSheet.swift`
- Modify: `Alas/Sources/Integrations/GG/GGStackReadinessModel.swift`
- Modify: `Alas/Sources/Integrations/GG/GGStackDrawer.swift`
- Modify: `Alas/Sources/Integrations/GG/GGMutationCoordinator.swift`
- Modify: `Alas/Sources/Integrations/GG/GGMutationModels.swift`
- Modify: `Alas/Sources/Integrations/GG/GGUndoMarkerStore.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift`
- Modify: `Alas/Sources/Right/RightPaneStore.swift`
- Modify: `Alas/Sources/App/RootView.swift`
- Modify: `AlasTests/Integrations/GGStackReadinessModelTests.swift`
- Modify: `AlasTests/Integrations/GGMutationCoordinatorTests.swift`
- Modify: `AlasTests/Integrations/GGUndoMarkerStoreTests.swift`
- Modify: `AlasTests/RightPaneGGStackTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` (generated)

**Interfaces:**

Extend readiness inputs with `GGEffectiveConfig` and local-change statistics. Primary action precedence is exact: paused Continue/Abort; required manual Rebase; Sync; Land ready; otherwise status only. The drawer overflow order is Reorder Stack, Restack, Undo Last GG Operation, Clean Merged Commits.

`GGUndoCandidate` contains operation ID, kind, status, `touchedRemote`, and `isUndoable`. `GGUndoMarkerStore` persists the last Alas-initiated local operation ID by worktree ID. The coordinator may surface a candidate only when the persisted ID matches GG's newest completed local operation, reports undoable, and did not touch remote state.

- [ ] **Step 1: Write failing readiness tests**

Cover `sync_auto_rebase = true` while behind, manual Rebase at and above threshold, Sync below threshold, paused precedence, Sync with local changes and `Local changes are not included`, publishable commits, landable commits, and no forced action when fresh.

Extend the existing `stack`/`entry` helpers with exact primary-action assertions:

```swift
@Test func autoRebaseKeepsSyncPrimaryWhileBehind() {
    let model = GGStackReadinessModel.make(
        stack: stack([entry(position: 1, prState: nil)], behind: 3),
        action: GGStackActionState(),
        effectiveConfig: .init(syncAutoRebase: true, syncBehindThreshold: 1),
        localChanges: .zero
    )
    #expect(model.primaryActions.map(\.kind) == [.sync])
    #expect(model.primaryActions[0].detail == "Includes rebase onto main")
}

@Test func thresholdSelectsManualRebase() {
    let model = GGStackReadinessModel.make(
        stack: stack([entry(position: 1, prState: nil)], behind: 2),
        action: GGStackActionState(),
        effectiveConfig: .init(syncAutoRebase: false, syncBehindThreshold: 2),
        localChanges: .zero
    )
    #expect(model.primaryActions.map(\.kind) == [.rebase])
}
```

- [ ] **Step 2: Write failing Reorder/Restack/Undo tests**

Cover drag only within each contiguous mutable region, immutable rows fixed in place, exact ID order submitted, no Drop affordance in Reorder, Restack dry-run before Apply, and rejection when the stack changed after preview. Cover Undo appearing after a local rewrite, disappearing after any later GG mutation, never appearing for Sync/Land/remote-touched operations, and restoration after relaunch only when `undo --list --limit 1` matches the persisted operation ID.

```swift
@Test func reorderRejectsMoveAcrossImmutableBoundary() {
    var model = GGReorderModel(entries: [.mutable("a"), .immutable("b"), .mutable("c")])
    #expect(model.move(from: 0, to: 2) == .immutableBoundary)
    #expect(model.orderedIDs == ["a", "b", "c"])
}

@Test func relaunchRestoresOnlyMatchingPersistedOperation() async {
    let store = GGUndoMarkerStore(storage: .inMemory)
    store.set(operationID: "op_1", worktreeId: "wt")
    let coordinator = makeCoordinator(markerStore: store, newestOperation: .localUndoable(id: "op_2"))
    await coordinator.restoreUndoCandidate()
    #expect(coordinator.undoCandidate == nil)
}
```

- [ ] **Step 3: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGStackReadinessModelTests -only-testing:AlasTests/GGMutationCoordinatorTests -only-testing:AlasTests/GGUndoMarkerStoreTests -only-testing:AlasTests/RightPaneGGStackTests test
```

Expected: FAIL because config-aware readiness and the three drawer workflows are absent.

- [ ] **Step 4: Implement config-aware primary action selection**

When auto-rebase is enabled and the stack is behind, keep Sync primary and say `Includes rebase onto <base>`. When disabled and behind count reaches the threshold, replace Sync with Rebase. Below the threshold, keep Sync. Pass no policy overrides to `gg sync`.

```swift
if stack.behindBase > 0,
   !effectiveConfig.syncAutoRebase,
   effectiveConfig.syncBehindThreshold > 0,
   stack.behindBase >= effectiveConfig.syncBehindThreshold {
    primaryActions = [.rebase(base: stack.base)]
} else if stack.hasUnsyncedCommits || stack.behindBase > 0 {
    primaryActions = [.sync(includesRebase: effectiveConfig.syncAutoRebase && stack.behindBase > 0)]
} else if stack.hasLandableCommits {
    primaryActions = [.land]
} else {
    primaryActions = []
}
```

Keep Sync available with unrelated local changes whenever GG permits; display the explicit exclusion note. A stale-base GG refusal triggers refresh and no automatic retry.

- [ ] **Step 5: Implement Reorder and Restack sheets**

Reorder uses drag handles and stable row dimensions, constrains moves to mutable regions, and submits GG IDs in the final complete order. Restack always runs dry-run first, displays the exact rewrite plan, then requires explicit Apply against the same fresh stack identity. Drop remains only in the commit submenu.

```swift
func move(from source: Int, to destination: Int) -> GGReorderMoveResult {
    guard mutableRegion(containing: source).contains(destination) else { return .immutableBoundary }
    entries.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
    return .moved
}

func loadRestackPreview() async throws {
    preview = try await service.restack(worktreePath: worktreePath, dryRun: true)
    let stack = try await context.loadFreshStack()
    previewStackIdentity = stack.identity
}
```

- [ ] **Step 6: Implement durable local Undo eligibility**

After each successful local mutation, persist its operation ID and reconcile it with GG's newest operation record; GG's operation log remains authoritative. Any subsequent GG mutation clears the marker and visible candidate before launch. On relaunch, query the newest operation once and restore only when its ID matches the persisted marker and it is local, completed, undoable, and non-remote. For remote-touched refusals, surface GG's recovery hint without attempting rollback.

```swift
func restoreUndoCandidate() async {
    guard let marker = undoMarkerStore.operationID(worktreeId: worktreeId),
          let newest = try? await service.listUndoOperations(worktreePath: worktreePath, limit: 1).first,
          newest.id == marker,
          newest.status == .completed,
          newest.isUndoable,
          !newest.touchedRemote else {
        undoCandidate = nil
        return
    }
    undoCandidate = GGUndoCandidate(operation: newest)
}
```

- [ ] **Step 7: Regenerate and run focused tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGStackReadinessModelTests -only-testing:AlasTests/GGMutationCoordinatorTests -only-testing:AlasTests/GGUndoMarkerStoreTests -only-testing:AlasTests/RightPaneGGStackTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit stack lifecycle workflows**

```bash
rtk git add Alas/Sources/Integrations/GG/GGReorderSheet.swift Alas/Sources/Integrations/GG/GGRestackSheet.swift Alas/Sources/Integrations/GG/GGStackReadinessModel.swift Alas/Sources/Integrations/GG/GGStackDrawer.swift Alas/Sources/Integrations/GG/GGMutationCoordinator.swift Alas/Sources/Integrations/GG/GGMutationModels.swift Alas/Sources/Integrations/GG/GGUndoMarkerStore.swift Alas/Sources/Right/RightPaneState.swift Alas/Sources/Right/RightPaneStore.swift Alas/Sources/App/RootView.swift AlasTests/Integrations/GGStackReadinessModelTests.swift AlasTests/Integrations/GGMutationCoordinatorTests.swift AlasTests/Integrations/GGUndoMarkerStoreTests.swift AlasTests/RightPaneGGStackTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(gg): add native stack lifecycle workflows"
```

### Task 8: Document And Verify The Complete Workflow

**Files:**
- Modify: `docs/manual-test.md`
- Modify implementation files only when verification exposes a defect; keep fixes in the commit that introduced the behavior with `gg amend` or `gg absorb`.

- [ ] **Step 1: Add manual acceptance scenarios**

Document setup and expected outcomes for: GG/non-GG Prepare; staged-only Amend/Absorb; PR review versus local Review Commit; Drop; Unstack with and without worktree; capability-disabled Split; successful Split; stale Split preservation; mutable-region Reorder; Restack preview; config-aware Sync/Rebase; paused Continue/Abort; local Undo; remote Undo refusal; and Sync with uncommitted changes.

Use one numbered subsection per workflow with this concrete format:

```markdown
### GG staged-only Amend

1. In a GG worktree, stage one file and leave a second file unstaged.
2. Expand Prepare and select `Amend current`.
3. Confirm the current stack commit includes only the staged diff.
4. Confirm the unstaged file remains under Changes and the stack refreshes.
5. Run `Undo Last GG Operation` and confirm the prior commit is restored.
```

- [ ] **Step 2: Scan user-facing terminology and forbidden flags**

Run:

```bash
rtk rg -n 'Entry|Entries|entry|entries' Alas/Sources/Integrations/GG Alas/Sources/Right
rtk rg -n -- '--force|--ignore-immutable' Alas/Sources AlasTests
```

Expected: the first command reports only internal type/property/wire names or raw GG diagnostics; the second reports no new GG UI command construction.

- [ ] **Step 3: Regenerate the project and run the quiet build**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit status `0` with no build errors.

- [ ] **Step 4: Run the complete test suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Review the final stack and commit documentation**

Run:

```bash
rtk git status --short
rtk git diff --check
rtk git log --oneline --decorate -10
```

Fold verification-only fixes into their owning stack commits with `gg absorb` or `gg amend`. Then commit the manual test guide:

```bash
rtk git add docs/manual-test.md
rtk git commit -m "docs(gg): add native workflow acceptance checks"
```

- [ ] **Step 6: Confirm the stack is clean**

Run:

```bash
rtk git status --short --branch
```

Expected: the branch header and no changed paths.
