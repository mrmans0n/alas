# Non-blocking Mission Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore a focused persisted Mission immediately at launch, render a non-blocking loading pane while its local snapshot is read, and keep the rest of startup independent of Mission reconciliation.

**Architecture:** Split global-tab restoration from legacy worktree-tab migration so the persisted active Mission is known before project discovery. `MissionController` owns a small observable loading state, which `MissionTabView` renders when an aggregate is not yet available. The root launch task starts Mission loading concurrently with topology discovery, completes selection/watchers/agent discovery once topology is ready, then performs reconciliation only after the loaded Mission snapshot is available.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation (`@Observable`), Swift Testing, macOS.

## Global Constraints

- Keep all code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Preserve legacy worktree Mission-tab migration, including its retry-safe persistence behavior.
- Do not change Mission persistence schema, lifecycle semantics, or Mission pane layout.
- Do not wait for Mission reconciliation before initial worktree selection, watcher startup, or agent scanning.
- Before handoff, run `xcodegen`, the macOS build, and the complete macOS test suite.

---

## File structure

- Modify: `Alas/Sources/Center/GlobalTabsManager.swift` — independently restore persisted global tabs and later migrate legacy worktree Mission tabs.
- Modify: `Alas/Sources/Missions/MissionController.swift` — publish `loading`, `loaded`, and `failed` Mission snapshot outcomes.
- Modify: `Alas/Sources/Missions/MissionTabView.swift` — render loading and failed-load content when an active tab has no aggregate yet.
- Modify: `Alas/Sources/App/AppState.swift` — expose startup-sized helpers for early global-tab restoration and reconciliation after a completed Mission load.
- Modify: `Alas/Sources/App/RootView.swift` — orchestrate the concurrent launch operations and keep an active persisted Mission visible before aggregates arrive.
- Modify: `AlasTests/GlobalTabsManagerTests.swift` — cover early restore and later migration merge semantics.
- Modify: `AlasTests/Missions/MissionCoordinatorTests.swift` — cover the Mission controller state machine on successful and failed snapshot loads.
- Modify: `AlasTests/Missions/MissionTabTests.swift` — cover loading, absent-after-load, and failed-load Mission tab rendering.
- Modify: `AlasTests/Missions/MissionSidebarTests.swift` — cover workspace visibility for an active persisted Mission while its aggregates load.

### Task 1: Split global-tab restore from legacy migration

**Files:**

- Modify: `Alas/Sources/Center/GlobalTabsManager.swift:44-154`
- Test: `AlasTests/GlobalTabsManagerTests.swift:1-314`

**Interfaces:**

- Produces: `func loadPersistedTabs() throws` that reads only `GlobalTabsFile`, deduplicates tabs, restores a valid active ID, and records `migrationVersion`.
- Produces: `func migrateLegacyMissionTabs(worktreeTabs:selectedWorktreeID:) throws` that loads legacy worktree tab files, imports unique Mission tabs into the current in-memory global tabs, preserves an already active global tab, extracts migrated tabs, and persists migration version 1.
- Produces: existing `loadAndMigrate(worktreeTabs:selectedWorktreeID:)` retained as a compatibility wrapper that calls the two methods in order.
- Consumes: `TabsManager.loadAllPersisted()`, `missionTabs()`, `activeMissionTab(preferredWorktreeID:)`, and `extractMissionTabs()`.

- [ ] **Step 1: Write the failing early-restore regression tests**

Add tests next to the existing `loadAndMigrate` coverage. First prove that restoring the global file does not inspect or remove legacy worktree Mission tabs:

```swift
@Test("persisted global tabs restore before legacy worktree-tab migration")
func restoresPersistedTabsBeforeMigration() throws {
    let harness = try GlobalTabsHarness(worktreeTabs: ["app": [.mission(.fixture)]])
    _ = harness.global.openOrFocusMission(
        missionID: MissionID(rawValue: "mission-2"), title: "Persisted Mission"
    )
    let restored = GlobalTabsManager(fileURL: harness.globalTabsFile)

    try restored.loadPersistedTabs()

    #expect(restored.activeMissionTab()?.missionID == MissionID(rawValue: "mission-2"))
    #expect(harness.tabs.tabs(forWorktree: "app") == [.mission(.fixture)])
}
```

Then prove later migration merges the legacy tab without replacing a newer active selection:

```swift
@Test("legacy migration merges into an already restored global-tab state")
func migrationMergesAfterEarlyRestore() throws {
    let harness = try GlobalTabsHarness(worktreeTabs: ["app": [.mission(.fixture)]])
    _ = harness.global.openOrFocusMission(
        missionID: MissionID(rawValue: "mission-2"), title: "Persisted Mission"
    )
    let restored = GlobalTabsManager(fileURL: harness.globalTabsFile)
    try restored.loadPersistedTabs()
    restored.activate(tabId: "mission:mission-2")

    try restored.migrateLegacyMissionTabs(worktreeTabs: harness.tabs)

    #expect(restored.tabs.map(\.id) == ["mission:mission-2", "mission:mission-1"])
    #expect(restored.activeTabId == "mission:mission-2")
    #expect(harness.tabs.tabs(forWorktree: "app").isEmpty)
}
```

- [ ] **Step 2: Run the focused tests and confirm the new API is absent**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GlobalTabsManagerTests test
```

Expected: the new tests fail to compile because `loadPersistedTabs()` and `migrateLegacyMissionTabs(worktreeTabs:selectedWorktreeID:)` do not yet exist.

- [ ] **Step 3: Implement separate restore and migration operations**

Refactor the existing method so the read-only early path is exactly the first half of the old combined method, and the migration path works from already-restored in-memory state:

```swift
func loadPersistedTabs() throws {
    let file = try store.readIfExists(GlobalTabsFile.self, from: fileURL) ?? GlobalTabsFile()
    tabs = Self.deduplicated(file.tabs)
    activeTabId = tabs.contains(where: { $0.id == file.activeTabId }) ? file.activeTabId : nil
    migrationVersion = file.migrationVersion
}

func migrateLegacyMissionTabs(
    worktreeTabs: TabsManager,
    selectedWorktreeID: String? = nil
) throws {
    guard migrationVersion < 1 else { return }
    worktreeTabs.loadAllPersisted()
    let activeLegacyMission = worktreeTabs.activeMissionTab(preferredWorktreeID: selectedWorktreeID)
    merge(worktreeTabs.missionTabs())
    if activeTabId == nil, let activeLegacyMission {
        activeTabId = activeLegacyMission.id
    }
    try persist()
    merge(try worktreeTabs.extractMissionTabs())
    migrationVersion = 1
    try persist()
}

func loadAndMigrate(worktreeTabs: TabsManager, selectedWorktreeID: String? = nil) throws {
    try loadPersistedTabs()
    try migrateLegacyMissionTabs(worktreeTabs: worktreeTabs, selectedWorktreeID: selectedWorktreeID)
}
```

Do not call `loadPersistedTabs()` from `migrateLegacyMissionTabs`; doing so would discard a tab close or activation the user made between early restore and migration.

- [ ] **Step 4: Run the focused tests and confirm they pass**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GlobalTabsManagerTests test
```

Expected: PASS, including existing retry-safety tests for failed migration writes.

- [ ] **Step 5: Commit the isolated tab-persistence change**

```bash
git add Alas/Sources/Center/GlobalTabsManager.swift AlasTests/GlobalTabsManagerTests.swift
git commit -m "refactor: split global Mission tab restoration"
```

### Task 2: Model Mission snapshot loading and show it in the pane

**Files:**

- Modify: `Alas/Sources/Missions/MissionController.swift:47-178`
- Modify: `Alas/Sources/Missions/MissionTabView.swift:416-492`
- Test: `AlasTests/Missions/MissionCoordinatorTests.swift`
- Test: `AlasTests/Missions/MissionTabTests.swift:806-850`

**Interfaces:**

- Produces: `enum MissionLoadState: Equatable { case loading; case loaded; case failed(String) }`.
- Produces: `MissionController.loadState`, initially `.loading`, published as `.loaded` only after aggregates are assigned or `.failed(message)` after a persistence error.
- Consumes: `MissionController.load()`; no caller needs a new persistence API.
- Produces: a Mission tab loading content view with accessibility identifier `mission-loading` and concise copy `Loading Mission…`.
- Produces: an unavailable error description that includes the failed-load message only for `.failed`.

- [ ] **Step 1: Write failing state and rendering tests**

In `MissionCoordinatorTests`, extend the current successful `load()` test to require a loaded state, and add a failing database path case:

```swift
await controller.load()

#expect(controller.loadState == .loaded)
#expect(controller.loadError == nil)
```

```swift
@Test("Mission load publishes a failed state without aggregates")
func loadFailurePublishesFailedState() async {
    let persistence = MissionPersistence(path: "/dev/null/missions.sqlite")
    let controller = MissionController(environment: .init(
        persistence: persistence,
        now: Date.init,
        makeID: { UUID().uuidString },
        worktreeAtDestination: { _, _ in nil },
        createWorktree: { _ in .failure(.init(message: "unused")) },
        startACP: { _, _ in .failure(.init(message: "unused")) },
        notifyChanged: { _ in }
    ))

    await controller.load()

    #expect(controller.aggregates.isEmpty)
    if case .failed = controller.loadState {
    } else {
        Issue.record("Expected a failed Mission load state")
    }
}
```

In `MissionTabTests`, construct a `MissionTabView` before calling `fixture.state.missions.load()` and assert `mission-loading` exists. Then load a nonexistent ID and assert the existing unavailable title; finally use `MissionPersistence(path: "/dev/null/missions.sqlite")` in an `AppState` fixture, call `load()`, and assert the unavailable description includes the published error.

- [ ] **Step 2: Run the focused tests and confirm they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/MissionCoordinatorTests -only-testing:AlasTests/MissionTabTests test
```

Expected: compilation fails because `MissionLoadState` and `MissionController.loadState` do not exist; the loading identifier is absent.

- [ ] **Step 3: Implement the controller state machine and pane branches**

Declare the state beside the controller and replace the current two-outcome `load()` implementation with cancellation-safe publishing:

```swift
enum MissionLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

private(set) var loadState: MissionLoadState = .loading

func load() async {
    loadState = .loading
    loadError = nil
    do {
        let loaded = try await persistence.list(includeCompleted: true)
        guard !Task.isCancelled else { return }
        aggregates = Self.sorted(loaded)
        loadState = .loaded
    } catch {
        guard !Task.isCancelled else { return }
        let message = error.localizedDescription
        loadError = message
        loadState = .failed(message)
    }
}
```

Keep all later mutation paths working with `aggregates` as today. In `MissionTabView.body`, retain the aggregate-first branch, then switch on `state.missions.loadState`: `.loading` renders a centered `ProgressView("Loading Mission…")` tagged with `.accessibilityIdentifier("mission-loading")`; `.loaded` renders the current unavailable view; `.failed(let message)` renders the same unavailable title with `Text(message)` as its description. Do not start a task from the view—the root owns the one startup load.

- [ ] **Step 4: Run the focused tests and confirm they pass**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/MissionCoordinatorTests -only-testing:AlasTests/MissionTabTests test
```

Expected: PASS. The view must not show `Mission unavailable` during `.loading`, and a failed read must not leave it spinning forever.

- [ ] **Step 5: Commit the Mission loading-state change**

```bash
git add Alas/Sources/Missions/MissionController.swift Alas/Sources/Missions/MissionTabView.swift AlasTests/Missions/MissionCoordinatorTests.swift AlasTests/Missions/MissionTabTests.swift
git commit -m "feat: show Mission loading state at startup"
```

### Task 3: Make launch concurrent without delaying the workspace

**Files:**

- Modify: `Alas/Sources/App/AppState.swift:899-916,1840-1875`
- Modify: `Alas/Sources/App/RootView.swift:73-91,106-115`
- Modify: `AlasTests/Missions/MissionSidebarTests.swift`
- Test: `AlasTests/Missions/MissionTabTests.swift`

**Interfaces:**

- Produces: `AppState.restoreGlobalTabsForStartup()` that calls `globalTabs.loadPersistedTabs()` and routes errors through `persistenceErrorHandler("Mission Tabs Save Failed", ...)`.
- Produces: `AppState.reconcileLoadedMissionsForStartup()` that performs the current repository refresh, legacy base-remote resolution, interrupted-Mission reconciliation, and missing-Mission recovery, but does not call `missions.load()`.
- Produces: `AppState.reconcileMissionsForStartup()` retained for existing callers as `await missions.load(); await reconcileLoadedMissionsForStartup()`.
- Consumes: `AppState.reloadTabs()` after topology discovery; it loads worktree tabs then invokes only `globalTabs.migrateLegacyMissionTabs(...)`.

- [ ] **Step 1: Write the failing launch-visibility and reconciliation-boundary tests**

Extend `RootWorkspaceVisibilityPolicy` so its test proves an active persisted global Mission makes the workspace visible even when projects and aggregates are both empty:

```swift
#expect(RootWorkspaceVisibilityPolicy.showsWorkspace(
    hasProjects: false,
    hasMissions: false,
    hasActiveMissionTab: true
))
```

In `MissionTabTests`, add a startup-boundary regression that preloads an aggregate, invokes `reconcileLoadedMissionsForStartup()`, and verifies the existing missing-worktree recovery behavior remains unchanged. Keep the existing `reconcileMissionsForStartup()` tests to prove the compatibility wrapper still loads first.

- [ ] **Step 2: Run the focused tests and confirm the new boundary is absent**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/MissionSidebarTests -only-testing:AlasTests/MissionTabTests test
```

Expected: compilation fails because the visibility-policy argument and `reconcileLoadedMissionsForStartup()` do not yet exist.

- [ ] **Step 3: Add startup-sized AppState helpers and reorder RootView.task**

Add the early restore helper and split reconciliation at the current `reconcileMissionsForStartup()` boundary:

```swift
func restoreGlobalTabsForStartup() {
    do {
        try globalTabs.loadPersistedTabs()
    } catch {
        persistenceErrorHandler("Mission Tabs Save Failed", error.localizedDescription)
    }
}

func reconcileMissionsForStartup() async {
    await missions.load()
    await reconcileLoadedMissionsForStartup()
}

func reconcileLoadedMissionsForStartup() async {
    await refreshRenamedMissionRepositories()
    await missions.resolveLegacyBaseRemoteNames { [weak self] projectID, baseRef in
        await self?.resolveLegacyMissionBaseRemoteName(projectID: projectID, baseRef: baseRef)
    }
    await missions.reconcileInterrupted()
    presentMissingMissionRecoveryIfNeeded()
}
```

In `reloadTabs()`, keep its worktree-tab load and terminal cleanup behavior, but replace `globalTabs.loadAndMigrate(...)` with `globalTabs.migrateLegacyMissionTabs(...)`.

Replace the root task sequence with concurrent Mission loading and topology refresh. The two `guard !Task.isCancelled` checks prevent a disappearing root view from applying a later startup phase:

```swift
.task {
    state.startHarness()
    state.restoreGlobalTabsForStartup()
    async let topologyRefresh: Bool = state.refreshAllProjectTopologies()
    async let missionLoad: Void = state.missions.load()

    _ = await topologyRefresh
    guard !Task.isCancelled else { return }
    state.reloadTabs()
    if state.selectedWorktreeId == nil {
        state.selectInitialWorktree(id: state.resolvedSelectionForActiveSpaceForStartup())
    }
    state.startAllProjectGitWatchers()
    state.rescanAgents()

    await missionLoad
    guard !Task.isCancelled else { return }
    await state.reconcileLoadedMissionsForStartup()
}
```

Update `RootWorkspaceVisibilityPolicy.showsWorkspace` to accept `hasActiveMissionTab: Bool` and return true for that third case. Pass `state.globalTabs.activeMissionTab() != nil` from `mainContent`. This is required for the loading pane to be reachable on a launch with no currently loaded projects or aggregates.

- [ ] **Step 4: Run focused tests and inspect launch ordering**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/MissionSidebarTests -only-testing:AlasTests/MissionTabTests -only-testing:AlasTests/GlobalTabsManagerTests test
```

Expected: PASS. Inspect the root task to confirm `startAllProjectGitWatchers()` and `rescanAgents()` occur before `await missionLoad` and `reconcileLoadedMissionsForStartup()`.

- [ ] **Step 5: Commit the non-blocking launch sequence**

```bash
git add Alas/Sources/App/AppState.swift Alas/Sources/App/RootView.swift AlasTests/Missions/MissionSidebarTests.swift AlasTests/Missions/MissionTabTests.swift
git commit -m "fix: avoid blocking startup on Mission reconciliation"
```

### Task 4: Run the complete regression suite and verify the app build

**Files:**

- Verify: all files changed in Tasks 1–3.

**Interfaces:**

- Verifies: combined global-tab persistence, Mission loading state, launch sequencing, and existing Mission recovery behavior.

- [ ] **Step 1: Run targeted Mission and tab regressions**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GlobalTabsManagerTests -only-testing:AlasTests/MissionCoordinatorTests -only-testing:AlasTests/MissionTabTests -only-testing:AlasTests/MissionSidebarTests test
```

Expected: PASS.

- [ ] **Step 2: Regenerate the Xcode project**

```bash
xcodegen
```

Expected: exits 0. If `project.yml` is unchanged, confirm the generated project has no unrelated diff before proceeding.

- [ ] **Step 3: Build the macOS app**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the complete macOS test suite**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: all tests pass.

- [ ] **Step 5: Inspect the final diff and commit any generated project update only if needed**

```bash
git diff --check
git status --short
```

If `xcodegen` changed `Alas.xcodeproj/project.pbxproj`, inspect that it is generated from the unchanged project definition; include it in a final commit only when it is a legitimate generated update:

```bash
git add Alas.xcodeproj/project.pbxproj
git commit -m "build: regenerate Xcode project"
```
