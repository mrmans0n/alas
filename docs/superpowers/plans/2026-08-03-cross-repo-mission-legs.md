# Cross-Repository Mission Legs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a running issue-driven Mission add independently coordinated repository legs and present the complete Mission in one global aggregate tab.

**Architecture:** Move setup, attention, and readiness state from `MissionRecord` to each `MissionLeg`, then drive the existing restart-safe setup engine by leg ID. Persist Mission tabs globally instead of under a primary worktree, and render ordered leg cards whose actions enter the corresponding worktree-specific agent or changes surface.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation, Swift Testing, SQLite through `SQLiteDatabase`, existing ACP/worktree/code-host services, XcodeGen.

## Global Constraints

- One Mission owns one provider issue snapshot shared by all legs.
- Add legs one at a time only while the Mission is `Running`.
- Allow at most one leg per Alas project in a Mission.
- Coordinate legs independently and in parallel; do not add dependency ordering.
- Never rebuild retry prompts from runtime state; reuse the persisted prepared prompt.
- Do not include agent transcripts or full diffs in shared prompt context.
- Mission readiness requires sticky readiness evidence on every persisted leg.
- Completion must not cancel external work already in flight, but no next external checkpoint may start afterward.
- Completion never stops agents, merges reviews, archives worktrees, or mutates the issue.
- Global Mission tabs must survive Space, project, and worktree changes.
- Keep code, comments, logs, and UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Add no new third-party dependencies.

---

### Task 1: Multi-Leg Domain Model and SQLite Migration

**Files:**
- Modify: `Alas/Sources/Missions/MissionModels.swift`
- Modify: `Alas/Sources/Missions/MissionStore.swift`
- Modify: `Alas/Sources/Missions/MissionPersistence.swift`
- Modify: `AlasTests/Missions/MissionTestFixtures.swift`
- Modify: `AlasTests/Missions/MissionStoreTests.swift`

**Interfaces:**
- Produces: `MissionLegState`, `MissionLegReadinessEvidence`, multi-leg `MissionAggregate.primaryLeg`, schema version 4, and store validation for ordered unique-project legs.
- Produces: `MissionPersistence.addLeg(_:event:)`, `aggregate(missionID:legID:)`, and leg-addressed update methods used by Tasks 2-5.

- [ ] **Step 1: Add failing model and migration tests**

Add tests that create a version-3 database with each legacy Mission state, open it through `MissionStore`, and assert the migrated leg state:

```swift
@Test("v4 migrates legacy Mission attention onto its leg")
func migratesLegacyAttentionToLeg() throws {
    let path = temporaryPath()
    let legacy = try MissionStoreTestDatabase.v3(
        path: path,
        missionState: "needsAttention",
        checkpoint: "startingAgent",
        attentionReason: "Install Codex"
    )
    legacy.close()

    let store = try MissionStore(path: path)
    let aggregate = try #require(try store.aggregate(id: MissionID(rawValue: "mission-1")))

    #expect(try store.currentSchemaVersion() == 4)
    #expect(aggregate.mission.state == .running)
    #expect(aggregate.primaryLeg?.state == .needsAttention)
    #expect(aggregate.primaryLeg?.setupCheckpoint == .startingAgent)
    #expect(aggregate.primaryLeg?.attentionReason == "Install Codex")
}
```

Add round-trip tests with two legs, rejection tests for duplicate project IDs, noncontiguous ordinals, a missing primary leg, and an event whose leg belongs to another Mission.

Add a private `MissionStoreTestDatabase` helper in `MissionStoreTests.swift` so the migration fixture is fully local to this suite:

```swift
private enum MissionStoreTestDatabase {
    static func v3(
        path: URL,
        missionState: String,
        checkpoint: String,
        attentionReason: String?
    ) throws -> SQLiteDatabase
}
```

The helper creates the v1 schema through `MissionStore`, advances it to v3, inserts one complete legacy aggregate with IDs `mission-1` and `leg-1`, then rewrites the Mission state/checkpoint/reason using `SQLiteDatabase.exec`. Keep all fixture dates and UUIDs fixed so migration assertions are deterministic.

- [ ] **Step 2: Run the Mission store suite and confirm red**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/MissionStoreTests test
```

Expected: FAIL because schema version 4 and leg lifecycle fields do not exist and the store still rejects more than one leg.

- [ ] **Step 3: Add the leg lifecycle types and remove Mission-level operational state**

Implement these domain shapes in `MissionModels.swift`:

```swift
enum MissionLegState: String, Codable, Equatable, Hashable, Sendable {
    case creating
    case running
    case needsAttention
    case ready
}

enum MissionLegReadinessKind: String, Codable, Equatable, Sendable {
    case mergedReview
    case archivedWorktree
    case legacy
}

struct MissionLegReadinessEvidence: Codable, Equatable, Sendable {
    let kind: MissionLegReadinessKind
    let observedAt: Date
}
```

Remove `.needsAttention` from `MissionState`. Remove `setupCheckpoint` and `attentionReason` from `MissionRecord`; leave the legacy SQLite columns in place for migration compatibility. Add these fields to `MissionLeg`:

```swift
var state: MissionLegState
var setupCheckpoint: MissionSetupCheckpoint
var attentionReason: String?
var readinessEvidence: MissionLegReadinessEvidence?
let createdAt: Date
var updatedAt: Date
```

Add `.legAdded` to `MissionEventKind`; its event always carries the newly persisted leg ID.

Change `primaryLeg` to an ID lookup without a count guard:

```swift
var primaryLeg: MissionLeg? {
    legs.first { $0.id == mission.primaryLegID }
}
```

- [ ] **Step 4: Implement schema v4 and multi-leg validation**

Set `MissionStore.targetSchemaVersion = 4`. Add columns to `mission_legs`, populate them from the legacy Mission columns, and normalize legacy `needsAttention` Missions to `running` in one migration transaction. Use this exact mapping:

| Legacy Mission state | Migrated Mission state | Migrated leg state | Readiness evidence |
|---|---|---|---|
| `creating` | `creating` | `creating` | nil |
| `running` | `running` | `running` | nil |
| `needsAttention` | `running` | `needsAttention` | nil |
| `readyToComplete` | `readyToComplete` | `ready` | `.legacy` at the Mission's `updatedAt` |
| `completed` with checkpoint `running` | `completed` | `running` | nil |
| `completed` with checkpoint `creatingWorktree` or `startingAgent` | `completed` | `creating` | nil |

Every row inherits the legacy checkpoint and attention reason, even when the terminal Mission makes those values informational. Use the Mission's `createdAt` and `updatedAt` for the new leg timestamps. Persist readiness evidence as sorted JSON.

Replace `exactlyOneLeg` validation with explicit errors:

```swift
case invalidLegCollection
case duplicateLegProject
case invalidEventLeg
```

Validate nonempty legs, primary membership, matching Mission IDs, contiguous unique ordinals, unique project IDs, and event leg membership. Insert every leg in ordinal order rather than `aggregate.legs[0]`.

- [ ] **Step 5: Add leg-addressed persistence methods**

Expose the following actor-safe wrappers through `MissionPersistence` and matching transactional store methods:

```swift
func addLeg(_ leg: MissionLeg, event: MissionEvent) throws
func leg(missionID: MissionID, legID: MissionLegID) throws -> MissionLeg?
func updateLegSetup(
    missionID: MissionID,
    leg: MissionLeg,
    event: MissionEvent?
) throws
```

`addLeg` must require Mission state `running`, assign no implicit ordinal, reject a duplicate project, insert the event atomically, and update `missions.updated_at`.

- [ ] **Step 6: Run store tests green**

Run the focused command from Step 2. Expected: PASS with all v1 migration cases and multi-leg invariants covered.

- [ ] **Step 7: Commit the domain migration**

```bash
git add Alas/Sources/Missions/MissionModels.swift \
  Alas/Sources/Missions/MissionStore.swift \
  Alas/Sources/Missions/MissionPersistence.swift \
  AlasTests/Missions/MissionTestFixtures.swift \
  AlasTests/Missions/MissionStoreTests.swift
git commit -m "feat(missions): persist independent leg lifecycle"
```

---

### Task 2: Per-Leg Setup Engine

**Files:**
- Create: `Alas/Sources/Missions/MissionLegCoordinator.swift`
- Modify: `Alas/Sources/Missions/MissionCoordinator.swift`
- Modify: `AlasTests/Missions/MissionCoordinatorTests.swift`
- Modify: `project.yml`
- Modify: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: leg-addressed persistence from Task 1.
- Produces: `MissionLegCoordinator.advance(missionID:legID:)`, `retry(missionID:legID:recreateWorktree:)`, and `reconcileInterrupted()`.
- Produces: `MissionCoordinator.addLeg(missionID:draft:)` facade used by Task 4 and the Add Leg UI.

- [ ] **Step 1: Add failing parallel and isolated-failure tests**

Extend the coordinator fake to store calls by `MissionLegID`. Add tests that create a two-leg aggregate and start both legs before either fake operation is released:

```swift
@Test("secondary legs advance independently")
func secondaryLegsAdvanceIndependently() async throws {
    let fake = MissionCoordinatorFake(suspendWorktreeCreation: true)
    let coordinator = MissionCoordinator(environment: fake.environment)
    let missionID = try await coordinator.create(Self.primaryDraft)
    _ = await fake.waitUntilSettled(missionID)

    async let first = coordinator.addLeg(missionID: missionID, draft: Self.sdkDraft)
    async let second = coordinator.addLeg(missionID: missionID, draft: Self.serverDraft)
    let legIDs = try await [first, second]

    await fake.waitForWorktreeStarts(count: 2)
    #expect(Set(fake.startedLegIDs) == Set(legIDs))
}
```

Add a second test where SDK worktree creation fails and the server leg reaches `running`; assert the Mission remains `running` and only the SDK leg needs attention.

Define the referenced support in `MissionCoordinatorTests.swift`: add fixed `primaryDraft`, `sdkDraft`, and `serverDraft` values; extend `MissionCoordinatorFake.init(suspendWorktreeCreation:)`; record `startedLegIDs`; and add `waitForWorktreeStarts(count:)`. The fake must hold one continuation per leg, expose `resumeWorktreeCreation(for:)`, and isolate configured failures by leg ID so the test cannot pass through a single shared gate.

- [ ] **Step 2: Run coordinator tests red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/MissionCoordinatorTests test
```

Expected: FAIL because coordination is keyed by Mission ID and `addLeg` does not exist.

- [ ] **Step 3: Extract the setup state machine by leg ID**

Move worktree reservation, creation, lineage validation, ACP reservation, prompt delivery, retry, and restart reconciliation into `MissionLegCoordinator`. Use leg-keyed serialization:

```swift
private var advancing: Set<MissionLegID> = []
private var advanceWaiters: [MissionLegID: [CheckedContinuation<Void, Never>]] = [:]

func advance(missionID: MissionID, legID: MissionLegID) async
func retry(missionID: MissionID, legID: MissionLegID, recreateWorktree: Bool) async
```

Every reload must select the requested leg explicitly. Never use `primaryLeg` inside the setup engine. Preserve the existing durable prompt receipt and lineage rules.

- [ ] **Step 4: Keep MissionCoordinator as the aggregate facade**

`MissionCoordinator.create` builds the initial leg with ordinal zero and delegates its setup. Add:

```swift
func addLeg(missionID: MissionID, draft: MissionLegDraft) async throws -> MissionLegID
```

It loads the running Mission, assigns `ordinal = aggregate.legs.count`, persists the complete leg and `legAdded` event, publishes the aggregate, launches `MissionLegCoordinator.advance`, and returns the durable leg ID.

When primary setup settles, transition the Mission from `creating` to `running`. Secondary transitions never rewrite Mission state.

- [ ] **Step 5: Guard completion between external checkpoints**

After each worktree or ACP call returns, persist that operation's result, reload the Mission, and return without starting the next external call when Mission state is `completed`. Add a test that completes while Git is suspended and asserts `startACPCalls == 0` after Git returns.

- [ ] **Step 6: Regenerate the project and run coordinator tests**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/MissionCoordinatorTests test
```

Expected: PASS, including existing single-leg startup and retry cases.

- [ ] **Step 7: Commit the per-leg coordinator**

```bash
git add project.yml Alas.xcodeproj/project.pbxproj \
  Alas/Sources/Missions/MissionLegCoordinator.swift \
  Alas/Sources/Missions/MissionCoordinator.swift \
  AlasTests/Missions/MissionCoordinatorTests.swift
git commit -m "feat(missions): coordinate legs independently"
```

---

### Task 3: Shared Context and Add-Leg Form Model

**Files:**
- Create: `Alas/Sources/Missions/MissionLegPromptBuilder.swift`
- Create: `Alas/Sources/Missions/AddMissionLegModel.swift`
- Create: `AlasTests/Missions/MissionLegPromptBuilderTests.swift`
- Create: `AlasTests/Missions/AddMissionLegModelTests.swift`
- Modify: `Alas/Sources/Missions/MissionModels.swift`
- Modify: `project.yml`
- Modify: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `MissionLegDraft` consumed by `MissionCoordinator.addLeg`.
- Produces: `MissionLegPromptBuilder.build(issue:existingLegs:projectName:branch:instructions:)`.
- Produces: `AddMissionLegModel` consumed by Task 8's SwiftUI sheet.

- [ ] **Step 1: Add failing prompt tests**

```swift
@Test("added leg prompt contains issue manifest and focused instructions")
func buildsAddedLegPrompt() {
    let prompt = MissionLegPromptBuilder.build(
        issue: MissionFixtures.issue(),
        existingLegs: [MissionFixtures.runningLeg(projectId: "alas", branch: "nacho/1842-app")],
        projectName: "alas-sdk",
        branch: "nacho/1842-sdk",
        instructions: "Update the Swift client API."
    )

    #expect(prompt.contains("## Issue context"))
    #expect(prompt.contains("alas · nacho/1842-app · Running"))
    #expect(prompt.contains("Update the Swift client API."))
    #expect(!prompt.contains("Transcript"))
}
```

Also assert deterministic leg ordering and stable output across retry.

- [ ] **Step 2: Add failing form-model tests**

Test that the model excludes every project already used by the Mission across all Spaces, rejects ready/completed/creating Missions, uses the selected project's base and branch-prefix defaults, and produces a draft only after branch/destination validation succeeds.

- [ ] **Step 3: Run both new suites red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/MissionLegPromptBuilderTests \
  -only-testing:AlasTests/AddMissionLegModelTests test
```

Expected: FAIL because the builder, model, and draft type do not exist.

- [ ] **Step 4: Implement `MissionLegDraft` and prompt generation**

Add this domain type:

```swift
struct MissionLegDraft: Equatable, Sendable {
    let projectId: String
    let baseRef: String
    let baseRemoteName: String?
    let branch: String
    let destinationPath: String
    let agentId: String
    let initialPromptId: UUID
    let preparedPrompt: String
}
```

The builder emits only the shared issue snapshot, canonical URL, ordered leg manifest, repository-specific instructions, and existing focused-change guidance.

- [ ] **Step 5: Implement the observable form model**

Follow `NewMissionDialogModel` conventions for loading projects, base refs, branch generation, destination validation, agent selection, and error presentation. The model accepts the complete configured project list rather than active-Space projects.

Expose:

```swift
func prepare(
    aggregate: MissionAggregate,
    projects: [ProjectConfig],
    selectedProjectID: String,
    instructions: String
) async throws -> MissionLegDraft
```

- [ ] **Step 6: Regenerate and run prompt/form tests green**

Run `xcodegen`, then the focused command from Step 3. Expected: PASS.

- [ ] **Step 7: Commit shared-context preparation**

```bash
git add project.yml Alas.xcodeproj/project.pbxproj \
  Alas/Sources/Missions/MissionModels.swift \
  Alas/Sources/Missions/MissionLegPromptBuilder.swift \
  Alas/Sources/Missions/AddMissionLegModel.swift \
  AlasTests/Missions/MissionLegPromptBuilderTests.swift \
  AlasTests/Missions/AddMissionLegModelTests.swift
git commit -m "feat(missions): prepare focused cross-repo legs"
```

---

### Task 4: Per-Leg Controller Operations and Readiness

**Files:**
- Modify: `Alas/Sources/Missions/MissionController.swift`
- Modify: `Alas/Sources/Missions/MissionReadinessEvaluator.swift`
- Modify: `AlasTests/Missions/MissionIntegrationTests.swift`
- Modify: `AlasTests/Missions/MissionReadinessEvaluatorTests.swift`

**Interfaces:**
- Consumes: `MissionLegCoordinator` and `MissionLegDraft` from Tasks 2-3.
- Produces: `MissionController.addLeg`, leg-addressed retry/review/archive/missing-project methods, and aggregate readiness recomputation.

- [ ] **Step 1: Write failing leg-readiness tests**

Change evaluator input to `MissionLegState` and assert sticky evidence:

```swift
@Test("Mission becomes ready only after every leg is ready")
func allLegsReady() async throws {
    let fake = MissionControllerFake(existing: [MissionFixtures.twoLegMission()])
    let controller = MissionController(environment: fake.environment)

    await controller.observeReview(
        worktreeId: "sdk-worktree",
        baseRef: "origin/main",
        snapshot: .mergedFixture
    )
    #expect(controller.aggregate(id: .fixture)?.mission.state == .running)

    await controller.recordArchive(worktreeId: "app-worktree")
    #expect(controller.aggregate(id: .fixture)?.mission.state == .readyToComplete)
}
```

Add tests for one missing worktree affecting only one leg, project removal affecting every matching leg, and provider refresh failure preserving prior leg readiness.

Add a private fixture extension in `MissionIntegrationTests.swift` defining `MissionID.fixture`, `MissionLegID.app`, `MissionLegID.sdk`, `ReviewLoopSnapshot.mergedFixture`, and `MissionFixtures.twoLegMission()`. Use fixed IDs and timestamps, and make the app leg ordinal zero/primary while SDK is ordinal one, so the assertions do not depend on test creation order. Configure the fake environment so `app-worktree` is archived and both fixture worktrees pass the existing branch and lineage guards.

- [ ] **Step 2: Run readiness and integration suites red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/MissionReadinessEvaluatorTests \
  -only-testing:AlasTests/MissionIntegrationTests test
```

Expected: FAIL because readiness and controller callbacks still use `primaryLeg` and Mission-level attention.

- [ ] **Step 3: Make readiness decisions leg-scoped**

Define:

```swift
enum MissionLegReadinessDecision: Equatable, Sendable {
    case unchanged(reviewIdentity: MissionReviewIdentity?)
    case ready(reviewIdentity: MissionReviewIdentity?, evidence: MissionLegReadinessEvidence, message: String)
    case needsAttention(String)
}
```

Evaluate signals against `MissionLegState`; preserve `.ready` and its evidence. After a leg mutation, transactionally set Mission state to `readyToComplete` only when all legs are ready.

- [ ] **Step 4: Refactor controller callbacks to find matching legs**

Iterate `aggregate.legs` for worktree, project, archive, review, and missing-worktree callbacks. Address mutations by `(missionID, legID)`. Add:

```swift
func addLeg(_ draft: MissionLegDraft, to missionID: MissionID) async throws -> MissionLegID
func retry(_ missionID: MissionID, legID: MissionLegID, agentId: String? = nil) async
```

Retain the existing single-argument retry as a temporary wrapper targeting `primaryLegID` until Task 8 replaces all UI call sites.

- [ ] **Step 5: Run controller suites green**

Run the focused command from Step 2. Expected: PASS.

- [ ] **Step 6: Commit controller/readiness changes**

```bash
git add Alas/Sources/Missions/MissionController.swift \
  Alas/Sources/Missions/MissionReadinessEvaluator.swift \
  AlasTests/Missions/MissionIntegrationTests.swift \
  AlasTests/Missions/MissionReadinessEvaluatorTests.swift
git commit -m "feat(missions): evaluate readiness per leg"
```

---

### Task 5: Global Mission Tab Store and Idempotent Migration

**Files:**
- Create: `Alas/Sources/Center/GlobalTabsManager.swift`
- Create: `AlasTests/GlobalTabsManagerTests.swift`
- Modify: `Alas/Sources/Center/Tab.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `Alas/Sources/Persistence/Paths.swift`
- Modify: `AlasTests/TabsManagerTests.swift`
- Modify: `project.yml`
- Modify: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `MissionTabState(missionID:title:)` without a worktree ID.
- Produces: `GlobalTabsManager.openOrFocusMission`, `close`, `activate`, and `loadAndMigrate(worktreeTabs:)`.
- Produces: `TabsManager.extractMissionTabs()` for one-time migration.

- [ ] **Step 1: Add failing global persistence and migration tests**

Use temporary `PersistenceStore` paths. Cover global round trip, stable Mission IDs, deduplication of the same Mission from two worktree files, removal from worktree files, and rerunning migration after a simulated partial write.

```swift
@Test("migration deduplicates Mission tabs across worktrees")
func migratesWorktreeMissionTabs() throws {
    let harness = GlobalTabsHarness(
        worktreeTabs: ["app": [.mission(.fixture)], "sdk": [.mission(.fixture)]]
    )

    try harness.global.loadAndMigrate(worktreeTabs: harness.tabs)

    #expect(harness.global.tabs.map(\.id) == ["mission:mission-1"])
    #expect(harness.tabs.tabs(forWorktree: "app").isEmpty)
    #expect(harness.tabs.tabs(forWorktree: "sdk").isEmpty)
}
```

Define `GlobalTabsHarness` in the test file with a temporary persistence root, one `TabsManager`, one `GlobalTabsManager`, and a fixed `MissionTabState.fixture` whose Mission ID is `mission-1`. Its initializer writes the supplied worktree `Tab` arrays through the production persistence encoding before managers load them.

- [ ] **Step 2: Run tab suites red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/GlobalTabsManagerTests \
  -only-testing:AlasTests/TabsManagerTests test
```

Expected: FAIL because tabs are still worktree-owned.

- [ ] **Step 3: Implement global tab persistence**

Add `Paths.globalTabsFile` and these persistence boundaries:

```swift
enum GlobalTab: Codable, Equatable, Identifiable {
    case mission(MissionTabState)
}

struct GlobalTabsFile: Codable {
    var version: Int = 1
    var migrationVersion: Int = 0
    var tabs: [GlobalTab]
    var activeTabId: TabID?
}
```

Give `GlobalTabsFile` a custom decoder with a private `FailableGlobalTab` wrapper identical in behavior to `TabsFile.FailableTab`, so an unknown future global case does not discard known Mission tabs. `GlobalTabsManager` is `@Observable @MainActor`, persists after each mutation, and exposes ordered `[GlobalTab]` plus the active ID.

Remove `worktreeId` from `MissionTabState`. Keep the stable ID derived from Mission ID during decoding.

- [ ] **Step 4: Implement migration extraction**

Add:

```swift
func extractMissionTabs() -> [MissionTabState]
```

It removes Mission tabs from every loaded worktree file, repairs active worktree tab IDs, persists changed files, and returns the states. `GlobalTabsManager.loadAndMigrate` merges them by Mission ID before marking migration version 1. A rerun after partial completion must be harmless.

- [ ] **Step 5: Regenerate and run tab tests green**

Run `xcodegen`, then the focused command from Step 2. Expected: PASS.

- [ ] **Step 6: Commit the global tab store**

```bash
git add project.yml Alas.xcodeproj/project.pbxproj \
  Alas/Sources/Center/GlobalTabsManager.swift \
  Alas/Sources/Center/Tab.swift Alas/Sources/Center/TabsManager.swift \
  Alas/Sources/Persistence/Paths.swift \
  AlasTests/GlobalTabsManagerTests.swift AlasTests/TabsManagerTests.swift
git commit -m "feat(missions): persist Mission tabs globally"
```

---

### Task 6: Global Center Selection and Worktree Handoff

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/App/CenterSelectionState.swift`
- Modify: `Alas/Sources/App/RootView.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `AlasTests/CenterSelectionStateResolverTests.swift`
- Modify: `AlasTests/AppStatePersistenceTests.swift`
- Modify: `AlasTests/AppStateCleanupTests.swift`

**Interfaces:**
- Consumes: `GlobalTabsManager` from Task 5.
- Produces: `CenterContentSelection.globalMission(MissionTabState)` and `.worktree(Worktree, Tab?)`.
- Produces: global `AppState.openMission(id:)` and leg-addressed worktree handoff helpers.

- [ ] **Step 1: Add failing selection and persistence tests**

Test that opening a Mission does not change `selectedWorktreeId`, selecting a worktree makes its tab active while leaving the Mission tab open, clicking the global Mission tab returns without reselecting its primary worktree, and a global Mission tab survives restart when its primary worktree is missing.

Add fixed `MissionTabState.fixture` and two `Worktree` fixture extensions in `CenterSelectionStateResolverTests.swift`; reuse them from the AppState tests rather than relying on shorthand that is not defined by production code.

- [ ] **Step 2: Run selection tests red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/CenterSelectionStateResolverTests \
  -only-testing:AlasTests/AppStatePersistenceTests \
  -only-testing:AlasTests/AppStateCleanupTests test
```

Expected: FAIL because active center content is derived only from selected worktree tabs.

- [ ] **Step 3: Introduce explicit center-content selection**

Add:

```swift
enum CenterContentSelection: Equatable {
    case globalMission(MissionTabState)
    case worktree(Worktree)
    case creating(Worktree)
    case deleting(Worktree)
    case deleteFailed(Worktree, message: String)
    case empty
}
```

`AppState` owns `globalTabs` and resolves the global active tab before worktree content. Selecting a worktree explicitly clears global activation but does not close global tabs.

- [ ] **Step 4: Make Mission opening global**

Replace worktree-bound `openMission` with:

```swift
@discardableResult
func openMission(id: MissionID) -> Result<MissionTabState, MissionOpenError>
```

It loads the aggregate, opens/focuses the global tab, suppresses the right pane using transient UI state, and never calls `focusGlobalWorktree`. Missing/project-removed Missions use the same global tab.

Add leg-specific actions:

```swift
func openMissionAgent(missionID: MissionID, legID: MissionLegID)
func openMissionChanges(missionID: MissionID, legID: MissionLegID) async
```

They resolve the leg's durable worktree, select it, restore the prior right-pane preference, and activate the requested worktree surface.

- [ ] **Step 5: Compose the center tab strip**

Render global Mission tabs before current-worktree tabs. Closing or reordering a Mission tab mutates only `GlobalTabsManager`. A worktree switch preserves global tabs and active Mission content only when the user clicked a global tab; clicking a worktree row returns to that worktree's active tab.

- [ ] **Step 6: Run selection tests green**

Run the focused command from Step 2. Expected: PASS.

- [ ] **Step 7: Commit global navigation**

```bash
git add Alas/Sources/App/AppState.swift Alas/Sources/App/CenterSelectionState.swift \
  Alas/Sources/App/RootView.swift Alas/Sources/Center/CenterPaneView.swift \
  AlasTests/CenterSelectionStateResolverTests.swift \
  AlasTests/AppStatePersistenceTests.swift AlasTests/AppStateCleanupTests.swift
git commit -m "feat(missions): navigate Missions independently of worktrees"
```

---

### Task 7: Aggregate Presentation and Cross-Space Sidebar State

**Files:**
- Create: `Alas/Sources/Missions/MissionLegPresentation.swift`
- Modify: `Alas/Sources/Missions/MissionTabView.swift`
- Modify: `Alas/Sources/Missions/MissionSidebarSection.swift`
- Modify: `AlasTests/Missions/MissionPresentationTests.swift`
- Modify: `AlasTests/Missions/MissionSidebarTests.swift`
- Modify: `AlasTests/Missions/MissionTabTests.swift`
- Modify: `project.yml`
- Modify: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `MissionLegPresentation`, `MissionAggregateSummary`, and stacked leg-card rendering consumed by Task 8.
- Produces: Space visibility when any existing leg project intersects active Space projects.

- [ ] **Step 1: Add failing presentation and Space-filter tests**

Create a three-leg fixture with running, attention, and ready legs. Assert summary text `"1 working · 1 needs attention · 1 ready"`, combined diff totals, ordered cards, and attention targets. Assert the Mission is visible from a Space containing only the SDK leg and hidden from an unrelated Space.

- [ ] **Step 2: Run presentation suites red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/MissionPresentationTests \
  -only-testing:AlasTests/MissionSidebarTests \
  -only-testing:AlasTests/MissionTabTests test
```

Expected: FAIL because presentation and filtering read only `primaryLeg`.

- [ ] **Step 3: Build aggregate presentation models**

`MissionLegPresentation` resolves project/worktree/session/review/diff state for exactly one leg. `MissionAggregateSummary` folds ordered cards into working, creating, attention, ready, change, and review counts without changing domain state.

Update `MissionSpaceFilter`:

```swift
let legProjectIDs = Set(aggregate.legs.map(\.projectId))
let retainedMissingProject = !legProjectIDs.isSubset(of: existingProjectIds)
return retainedMissingProject || !legProjectIDs.isDisjoint(with: activeProjectIds)
```

- [ ] **Step 4: Render stacked leg cards**

Replace the single `MissionLegSection` with `ForEach(presentation.legs)` using stable leg IDs. Each card renders its own state, actions, and retry affordances. Add aggregate header badges and attention links using `ScrollViewReader` and `scrollTo(legID)`.

Remove Mission-tab right-pane activation and default-base restoration; those now occur only during leg worktree handoff in Task 6.

- [ ] **Step 5: Update sidebar aggregate status**

Replace single-state `.running`/`.needsAttention` rows with aggregate copy while retaining `Creating`, `Ready to complete`, and `Completed` for Mission-level states. Keep provider glyphs and completed grouping unchanged.

- [ ] **Step 6: Regenerate and run presentation suites green**

Run `xcodegen`, then the focused command from Step 2. Expected: PASS.

- [ ] **Step 7: Commit aggregate presentation**

```bash
git add project.yml Alas.xcodeproj/project.pbxproj \
  Alas/Sources/Missions/MissionLegPresentation.swift \
  Alas/Sources/Missions/MissionTabView.swift \
  Alas/Sources/Missions/MissionSidebarSection.swift \
  AlasTests/Missions/MissionPresentationTests.swift \
  AlasTests/Missions/MissionSidebarTests.swift AlasTests/Missions/MissionTabTests.swift
git commit -m "feat(missions): present aggregate leg status"
```

---

### Task 8: Add Leg Sheet and Per-Leg Actions

**Files:**
- Create: `Alas/Sources/Missions/AddMissionLegDialog.swift`
- Modify: `Alas/Sources/Missions/MissionTabView.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Create: `AlasTests/Missions/AddMissionLegDialogTests.swift`
- Modify: `AlasTests/Missions/MissionTabTests.swift`
- Modify: `project.yml`
- Modify: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AddMissionLegModel`, `MissionController.addLeg`, aggregate presentation, and leg-addressed navigation/retry APIs.
- Produces: complete user-facing Add Leg flow and leg-card actions.

- [ ] **Step 1: Add failing dialog and action-routing tests**

Test form enablement for running versus creating/ready/completed Missions, project exclusion across Spaces, instructions validation, submission de-duplication, and routing each card's Agent/Changes/Retry action with its own `MissionLegID`.

- [ ] **Step 2: Run dialog and Mission tab tests red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/AddMissionLegDialogTests \
  -only-testing:AlasTests/MissionTabTests test
```

Expected: FAIL because the sheet and leg-addressed closures do not exist.

- [ ] **Step 3: Implement the Add Leg sheet**

Follow existing dialog chrome and field primitives from `NewMissionDialog`. Show the shared issue and manifest read-only, then project, base, branch, agent, and instructions fields. Disable confirmation during preparation/submission and display sanitized errors without dismissing the sheet.

On confirmation:

```swift
let draft = try await state.preparedMissionLegDraft(
    missionID: missionID,
    projectID: selectedProjectID,
    baseRef: baseRef,
    branch: branch,
    agentID: agentID,
    instructions: instructions
)
_ = try await state.missions.addLeg(draft, to: missionID)
```

Dismiss only after the leg is durable.

- [ ] **Step 4: Wire per-leg card actions**

Pass `MissionLegID` through Agent, Changes, Review, Retry Worktree, Retry Agent, and recovery closures. Remove primary-leg wrappers once all call sites compile. `Add Leg` appears after cards only for `MissionState.running`.

- [ ] **Step 5: Regenerate and run UI-model tests green**

Run `xcodegen`, then the focused command from Step 2. Expected: PASS.

- [ ] **Step 6: Commit the user-facing Add Leg flow**

```bash
git add project.yml Alas.xcodeproj/project.pbxproj \
  Alas/Sources/Missions/AddMissionLegDialog.swift \
  Alas/Sources/Missions/MissionTabView.swift Alas/Sources/App/AppState.swift \
  AlasTests/Missions/AddMissionLegDialogTests.swift AlasTests/Missions/MissionTabTests.swift
git commit -m "feat(missions): add repository legs from Mission tabs"
```

---

### Task 9: End-to-End Multi-Leg Recovery and Compatibility

**Files:**
- Modify: `AlasTests/Missions/MissionIntegrationTests.swift`
- Modify: `AlasTests/AppStatePersistenceTests.swift`
- Modify: `AlasTests/Missions/NewMissionDialogTests.swift`
- Modify: `AlasTests/Missions/MissionCoordinatorTests.swift`
- Modify implementation files only when a new integration assertion exposes a defect.

**Interfaces:**
- Consumes: all earlier tasks.
- Produces: acceptance-level proof for parallel creation, restart, global navigation, readiness, and v1 compatibility.

- [ ] **Step 1: Add an end-to-end multi-leg acceptance test**

Build a fake Mission with app and SDK legs. Start both, fail SDK ACP after its worktree succeeds, restart the controller, retry SDK, merge app review, archive SDK worktree, and assert:

```swift
#expect(fake.worktreeCreationsByLeg[.app] == 1)
#expect(fake.worktreeCreationsByLeg[.sdk] == 1)
#expect(fake.promptDeliveriesByLeg[.sdk] == 1)
#expect(aggregate.legs.allSatisfy { $0.state == .ready })
#expect(aggregate.mission.state == .readyToComplete)
```

Extend the existing `MissionIntegrationFake` with dictionaries keyed by `MissionLegID` for `worktreeCreationsByLeg` and `promptDeliveriesByLeg`, plus targeted failure/resume controls. Reuse the fixed `.app`, `.sdk`, and `twoLegMission()` fixtures introduced in Task 4; do not create a second incompatible fixture vocabulary.

- [ ] **Step 2: Add global-tab migration and cross-Space acceptance tests**

Start with a persisted v1 Mission tab under the app worktree, load after migration, switch to a Space containing only SDK, and assert the same global tab and full two-leg presentation remain available.

- [ ] **Step 3: Add single-leg compatibility assertions**

Run existing issue creation, duplicate confirmation, worktree retry, agent replacement, review readiness, archive readiness, and explicit completion tests without special multi-leg setup. Update expectations only where state moved from Mission to its sole leg.

- [ ] **Step 4: Run the complete affected test matrix**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/MissionStoreTests \
  -only-testing:AlasTests/MissionCoordinatorTests \
  -only-testing:AlasTests/MissionIntegrationTests \
  -only-testing:AlasTests/MissionReadinessEvaluatorTests \
  -only-testing:AlasTests/MissionPromptBuilderTests \
  -only-testing:AlasTests/MissionLegPromptBuilderTests \
  -only-testing:AlasTests/AddMissionLegModelTests \
  -only-testing:AlasTests/AddMissionLegDialogTests \
  -only-testing:AlasTests/MissionPresentationTests \
  -only-testing:AlasTests/MissionSidebarTests \
  -only-testing:AlasTests/MissionTabTests \
  -only-testing:AlasTests/NewMissionDialogTests \
  -only-testing:AlasTests/GlobalTabsManagerTests \
  -only-testing:AlasTests/TabsManagerTests \
  -only-testing:AlasTests/CenterSelectionStateResolverTests \
  -only-testing:AlasTests/AppStatePersistenceTests test
```

Expected: PASS.

- [ ] **Step 5: Commit acceptance coverage and fixes**

```bash
git add Alas AlasTests project.yml Alas.xcodeproj/project.pbxproj
git commit -m "test(missions): cover cross-repo lifecycle"
```

---

### Task 10: Repository Verification and Handoff

**Files:**
- Modify only files required by formatter, project generation, or test failures attributable to this feature.

**Interfaces:**
- Consumes: completed feature from Tasks 1-9.
- Produces: clean generated project, formatted sources, passing build/tests, and reviewable commit history.

- [ ] **Step 1: Regenerate and verify generated project consistency**

```bash
rtk xcodegen
rtk git diff --check
```

Expected: no uncommitted generated-project drift other than intentional corrections.

- [ ] **Step 2: Run SwiftFormat lint**

```bash
swiftformat --lint Alas/Sources/Missions Alas/Sources/Center \
  Alas/Sources/App AlasTests/Missions AlasTests/GlobalTabsManagerTests.swift
```

Expected: `0/N files require formatting`.

- [ ] **Step 3: Run the required macOS build**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 4: Run the required full test suite**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0. If a pre-existing unrelated failure appears, rerun it in isolation, record exact evidence, and do not describe the full suite as green.

- [ ] **Step 5: Review final diff and commit verification corrections**

```bash
rtk git status --short
rtk git diff --check
rtk git log --oneline origin/main..HEAD
```

If verification produced tracked corrections:

```bash
git add Alas/Sources/Missions Alas/Sources/App Alas/Sources/Center \
  Alas/Sources/Persistence AlasTests/Missions \
  AlasTests/GlobalTabsManagerTests.swift AlasTests/TabsManagerTests.swift \
  AlasTests/CenterSelectionStateResolverTests.swift \
  AlasTests/AppStatePersistenceTests.swift AlasTests/AppStateCleanupTests.swift \
  project.yml Alas.xcodeproj/project.pbxproj
git commit -m "fix(missions): finish cross-repo verification"
```

Expected: clean worktree and small, ordered commits matching Tasks 1-9.
