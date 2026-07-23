# New Worktree GG Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the new-worktree GG Boolean with an `Inherit` / `On` / `Off` policy picker that drives both creation behavior and the persisted worktree override.

**Architecture:** Extract the linked-worktree policy decision already used by `GGWorktreeContextResolver` and reuse it from `GGStackCreateMode` so dialog creation and runtime gating cannot drift. Apply the raw policy to the optimistic worktree before selection, persist explicit overrides only after successful reconciliation, and make the dialog render creation fields and validation from the effective policy while retaining the raw selection.

**Tech Stack:** Swift 5.9+, SwiftUI for macOS, Swift Observation, Swift Testing (`import Testing`), XcodeGen/Xcode.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest.
- The raw selection is exactly `GGWorktreeMode.inherit`, `.on`, or `.off`; `Inherit` stays visibly selected while helper text reports its current effective value.
- `Inherit` persists no `ggWorktreeModes` entry; `On` and `Off` persist explicit overrides under the stable worktree identity.
- A selected policy that effectively enables GG uses the existing stack-name field, `<branch_username>/<stack-name>` composition, and configured GG base.
- A selected policy that effectively disables GG uses the existing regular branch field and freely selected base.
- App-wide disablement, missing gg installation, and remote projects are hard creation stops; an explicit `On` must remain available when only the project default is Off.
- Missing `branch_username` blocks confirmation only when the effective creation behavior is GG.
- The optimistic worktree receives its in-memory mode before immediate selection; explicit modes are saved only after successful topology reconciliation and removed on failure.
- Do not introduce architectural changes outside this creation/policy flow.
- Do not add agent or model attributions to code, documentation, commits, or the PR.
- `project.yml` is not expected to change. If it does, run `xcodegen` and commit both `project.yml` and `Alas.xcodeproj` changes.

---

### Task 1: Share GG policy resolution with worktree creation

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGWorktreeContext.swift`
- Modify: `Alas/Sources/Integrations/GG/GGStackCreateMode.swift`
- Test: `AlasTests/Integrations/GGWorktreeContextTests.swift`
- Test: `AlasTests/GGStackCreateModeTests.swift`

**Interfaces:**
- Consumes: `GGProjectMode`, `GGWorktreeMode`, repository GG-config presence, and the existing app/CLI/remote hard gates.
- Produces: `GGWorktreeContextResolver.isPolicyEnabled(projectMode:worktreeOverride:isMainWorktree:repoHasGGConfig:) -> Bool` and `GGStackCreateMode.createsStack(masterEnabled:ggInstalled:isRemoteProject:projectMode:worktreeMode:repoHasGGConfig:) -> Bool` for Task 3.

- [ ] **Step 1: Add direct failing tests for the extracted policy resolver**

Add tests that exercise linked inheritance, the main-worktree implicit Off default, and explicit overrides:

```swift
@Test func policyResolverPreservesWorktreeSemantics() {
    #expect(GGWorktreeContextResolver.isPolicyEnabled(
        projectMode: .auto,
        worktreeOverride: .inherit,
        isMainWorktree: false,
        repoHasGGConfig: true
    ))
    #expect(!GGWorktreeContextResolver.isPolicyEnabled(
        projectMode: .on,
        worktreeOverride: .inherit,
        isMainWorktree: true,
        repoHasGGConfig: true
    ))
    #expect(GGWorktreeContextResolver.isPolicyEnabled(
        projectMode: .off,
        worktreeOverride: .on,
        isMainWorktree: false,
        repoHasGGConfig: false
    ))
    #expect(!GGWorktreeContextResolver.isPolicyEnabled(
        projectMode: .on,
        worktreeOverride: .off,
        isMainWorktree: false,
        repoHasGGConfig: true
    ))
}
```

- [ ] **Step 2: Add failing creation-policy matrix tests**

Add `GGStackCreateModeTests` cases proving all raw modes, inherited project modes, and hard stops:

```swift
@Test func creationPolicyUsesRawModeAndLinkedRepositoryDefault() {
    #expect(createsStack(projectMode: .auto, worktreeMode: .inherit, hasConfig: true))
    #expect(!createsStack(projectMode: .auto, worktreeMode: .inherit, hasConfig: false))
    #expect(!createsStack(projectMode: .off, worktreeMode: .inherit, hasConfig: true))
    #expect(createsStack(projectMode: .on, worktreeMode: .inherit, hasConfig: false))
    #expect(createsStack(projectMode: .off, worktreeMode: .on, hasConfig: false))
    #expect(!createsStack(projectMode: .on, worktreeMode: .off, hasConfig: true))
}

@Test func creationPolicyHonorsHardStops() {
    #expect(!createsStack(masterEnabled: false))
    #expect(!createsStack(ggInstalled: false))
    #expect(!createsStack(isRemoteProject: true))
}

private func createsStack(
    masterEnabled: Bool = true,
    ggInstalled: Bool = true,
    isRemoteProject: Bool = false,
    projectMode: GGProjectMode = .auto,
    worktreeMode: GGWorktreeMode = .inherit,
    hasConfig: Bool = true
) -> Bool {
    GGStackCreateMode.createsStack(
        masterEnabled: masterEnabled,
        ggInstalled: ggInstalled,
        isRemoteProject: isRemoteProject,
        projectMode: projectMode,
        worktreeMode: worktreeMode,
        repoHasGGConfig: hasConfig
    )
}
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGWorktreeContextTests \
  -only-testing:AlasTests/GGStackCreateModeTests
```

Expected: compilation fails because `isPolicyEnabled` and `createsStack` do not exist.

- [ ] **Step 4: Extract the existing policy switch and add the creation resolver**

Add this pure helper to `GGWorktreeContextResolver` and replace the inline `policyEnabled` switch in `resolve` with a call to it:

```swift
static func isPolicyEnabled(
    projectMode: GGProjectMode,
    worktreeOverride: GGWorktreeMode,
    isMainWorktree: Bool,
    repoHasGGConfig: Bool
) -> Bool {
    switch worktreeOverride {
    case .on:
        return true
    case .off:
        return false
    case .inherit:
        if isMainWorktree { return false }
        switch projectMode {
        case .off: return false
        case .auto: return repoHasGGConfig
        case .on: return true
        }
    }
}
```

Add this creation-specific hard-gate wrapper to `GGStackCreateMode`:

```swift
static func createsStack(
    masterEnabled: Bool,
    ggInstalled: Bool,
    isRemoteProject: Bool,
    projectMode: GGProjectMode,
    worktreeMode: GGWorktreeMode,
    repoHasGGConfig: Bool
) -> Bool {
    guard masterEnabled, ggInstalled, !isRemoteProject else { return false }
    return GGWorktreeContextResolver.isPolicyEnabled(
        projectMode: projectMode,
        worktreeOverride: worktreeMode,
        isMainWorktree: false,
        repoHasGGConfig: repoHasGGConfig
    )
}
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the Step 3 command again.

Expected: both suites pass with zero failures.

- [ ] **Step 6: Commit Task 1**

```bash
git add Alas/Sources/Integrations/GG/GGWorktreeContext.swift \
  Alas/Sources/Integrations/GG/GGStackCreateMode.swift \
  AlasTests/Integrations/GGWorktreeContextTests.swift \
  AlasTests/GGStackCreateModeTests.swift
git commit -m "refactor: share GG worktree policy resolution"
```

---

### Task 2: Carry and persist GG mode through worktree creation

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/AppStateCleanupTests.swift`

**Interfaces:**
- Consumes: the existing `ProjectsManager.setGGWorktreeMode`, `removeGGWorktreeMode`, `saveProjects`, and `RightPaneStore.reevaluateGGGate` APIs.
- Produces: `AppState.createWorktree(..., launchSurface:ggWorktreeMode:)` with a default of `.inherit`, used by Task 3 without changing CLI or delegated callers.

- [ ] **Step 1: Add failing success and failure lifecycle tests**

Add real-repository tests beside the existing `createWorktree` tests:

```swift
@Test func createWorktreeAppliesAndKeepsExplicitGGMode() async throws {
    let repo = try await makeRepo(name: "create-gg-off")
    defer { try? FileManager.default.removeItem(at: repo) }
    let state = AppState()
    let project = try await state.projectsManager.addProject(
        path: repo,
        displayName: "create-gg-off",
        color: "#5fb7c4"
    )
    try await state.projectsManager.refreshWorktrees(projectId: project.id)

    let id = await state.createWorktree(
        projectId: project.id,
        base: "main",
        branch: "regular-branch",
        destination: repo.appendingPathComponent("wt-gg-off"),
        runStartup: false,
        launchSurface: .none,
        ggWorktreeMode: .off
    )

    #expect(state.selectedWorktreeId == id)
    #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: id) == .off)
    try await waitForOperationState(state.projectsManager, id: id, equals: nil)
    #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: id) == .off)
}

@Test func failedCreateRemovesUnpersistedGGMode() async throws {
    let repo = try await makeRepo(name: "create-gg-fail")
    defer { try? FileManager.default.removeItem(at: repo) }
    let state = AppState()
    let project = try await state.projectsManager.addProject(
        path: repo,
        displayName: "create-gg-fail",
        color: "#5fb7c4"
    )
    try await state.projectsManager.refreshWorktrees(projectId: project.id)

    let id = await state.createWorktree(
        projectId: project.id,
        base: "missing-base",
        branch: "failed-stack",
        destination: repo.appendingPathComponent("wt-gg-fail"),
        runStartup: false,
        launchSurface: .none,
        ggWorktreeMode: .on
    )

    try await waitForOperationStateMatching(state.projectsManager, id: id) {
        if case .createFailed = $0 { return true }
        return false
    }
    #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: id) == .inherit)
}
```

- [ ] **Step 2: Run the lifecycle tests and verify RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/AppStateCleanupTests/createWorktreeAppliesAndKeepsExplicitGGMode \
  -only-testing:AlasTests/AppStateCleanupTests/failedCreateRemovesUnpersistedGGMode
```

Expected: compilation fails because `createWorktree` has no `ggWorktreeMode` argument.

- [ ] **Step 3: Add the raw mode to the creation API and optimistic phase**

Extend the signature without breaking existing callers:

```swift
func createWorktree(
    projectId: String,
    base: String,
    branch: String,
    destination: URL,
    runStartup: Bool,
    launchSurface: WorktreeLaunchSurface,
    ggWorktreeMode: GGWorktreeMode = .inherit
) async -> String
```

Immediately after `insertOptimisticWorktree(optimistic)` and before selection, apply the raw value directly through `ProjectsManager`:

```swift
projectsManager.setGGWorktreeMode(
    projectId: projectId,
    worktreeId: optimistic.id,
    mode: ggWorktreeMode
)
```

- [ ] **Step 4: Persist only after successful reconciliation**

After `refreshProjectWorktrees` succeeds and before launch handling, reapply the mode to `newWorktree.id`, save explicit overrides, and reevaluate the affected gate:

```swift
projectsManager.setGGWorktreeMode(
    projectId: project.id,
    worktreeId: newWorktree.id,
    mode: ggWorktreeMode
)
if ggWorktreeMode != .inherit {
    saveProjects()
}
rightPaneStore.reevaluateGGGate(worktreeId: newWorktree.id)
```

Add a focused cleanup helper and call it from both creation failure paths before publishing `.createFailed`:

```swift
private func discardUnpersistedGGWorktreeMode(
    projectId: String,
    worktreeId: String,
    mode: GGWorktreeMode
) {
    guard mode != .inherit else { return }
    projectsManager.removeGGWorktreeMode(projectId: projectId, worktreeId: worktreeId)
    rightPaneStore.reevaluateGGGate(worktreeId: worktreeId)
}
```

- [ ] **Step 5: Run the focused lifecycle tests and verify GREEN**

Run the Step 2 command again.

Expected: both tests pass with zero failures.

- [ ] **Step 6: Run all AppState cleanup tests**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/AppStateCleanupTests
```

Expected: the suite passes with zero failures.

- [ ] **Step 7: Commit Task 2**

```bash
git add Alas/Sources/App/AppState.swift AlasTests/AppStateCleanupTests.swift
git commit -m "feat: persist GG mode during worktree creation"
```

---

### Task 3: Replace the GG creation toggle with the three-state picker

**Files:**
- Modify: `Alas/Sources/Dialogs/NewWorktreeDialog.swift`
- Test: `AlasTests/NewWorktreeDialogTests.swift`

**Interfaces:**
- Consumes: `GGStackCreateMode.createsStack(...)` from Task 1 and the `ggWorktreeMode` creation argument from Task 2.
- Produces: a single raw `GGWorktreeMode` dialog selection that controls the displayed input, base pinning, validation, helper copy, and persisted creation request.

- [ ] **Step 1: Replace Boolean-helper tests with failing three-state tests**

Remove `stackModeSurvivesOnlyWhenAvailabilityEnabled` and update `activeName` calls to use `createsGGStack:`. Add tests for explanatory copy, repository reset, and validation:

```swift
@Test func inheritedGGDescriptionReportsEffectiveMode() {
    #expect(NewWorktreeDialog.ggModeDescription(mode: .inherit, createsGGStack: true) ==
        "Uses repository default: On.")
    #expect(NewWorktreeDialog.ggModeDescription(mode: .inherit, createsGGStack: false) ==
        "Uses repository default: Off. Creates a regular Git branch.")
}

@Test func explicitGGDescriptionsExplainCreation() {
    #expect(NewWorktreeDialog.ggModeDescription(mode: .on, createsGGStack: true) ==
        "GG enabled for this worktree.")
    #expect(NewWorktreeDialog.ggModeDescription(mode: .off, createsGGStack: false) ==
        "GG disabled for this worktree. Creates a regular Git branch.")
}

@Test func repositoryChangeResetsGGModeToInherit() {
    #expect(NewWorktreeDialog.ggModeAfterRepositoryChange(current: .on) == .inherit)
    #expect(NewWorktreeDialog.ggModeAfterRepositoryChange(current: .off) == .inherit)
}

@Test func canCreateBlocksMissingUsernameOnlyForEffectiveGG() {
    #expect(!NewWorktreeDialog.canCreate(
        projectsEmpty: false,
        branchEmpty: false,
        ggConfigurationMissing: true
    ))
    #expect(NewWorktreeDialog.canCreate(
        projectsEmpty: false,
        branchEmpty: false,
        ggConfigurationMissing: false
    ))
}
```

- [ ] **Step 2: Run dialog tests and verify RED**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/NewWorktreeDialogTests
```

Expected: compilation fails because the three new helpers and `ggConfigurationMissing` argument do not exist.

- [ ] **Step 3: Replace dialog state and compute effective creation policy**

Replace the Boolean state with:

```swift
@State private var ggMode: GGWorktreeMode = .inherit
```

Make availability depend only on the hard prerequisites, not `project.ggMode`, so explicit `On` remains possible:

```swift
let gatePassed = state.config.changes.stackedDiffsEnabled
    && GGAvailability.shared.isInstalled
    && project.host == nil
```

Add an effective creation property using Task 1's shared resolver:

```swift
private var createsGGStack: Bool {
    guard let project = state.projects.first(where: { $0.id == projectId }) else { return false }
    return GGStackCreateMode.createsStack(
        masterEnabled: state.config.changes.stackedDiffsEnabled,
        ggInstalled: GGAvailability.shared.isInstalled,
        isRemoteProject: project.host != nil,
        projectMode: project.ggMode,
        worktreeMode: ggMode,
        repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path)
    )
}
```

Use `createsGGStack` everywhere the old Boolean selected the active field, effective branch, or pinned base. Preserve `branch` and `stackName` as separate state values.

- [ ] **Step 4: Render the segmented picker and helper state**

Replace the old toggle row with a labeled segmented picker whenever availability is not hidden:

```swift
DialogField(label: "GG mode") {
    Picker("GG mode", selection: $ggMode) {
        Text("Inherit").tag(GGWorktreeMode.inherit)
        Text("On").tag(GGWorktreeMode.on)
        Text("Off").tag(GGWorktreeMode.off)
    }
    .pickerStyle(.segmented)
}
```

Add and use these pure helpers:

```swift
nonisolated static func ggModeDescription(
    mode: GGWorktreeMode,
    createsGGStack: Bool
) -> String {
    switch mode {
    case .inherit:
        createsGGStack
            ? "Uses repository default: On."
            : "Uses repository default: Off. Creates a regular Git branch."
    case .on:
        "GG enabled for this worktree."
    case .off:
        "GG disabled for this worktree. Creates a regular Git branch."
    }
}

nonisolated static func ggModeAfterRepositoryChange(current _: GGWorktreeMode) -> GGWorktreeMode {
    .inherit
}
```

Render the description beneath the picker. When effective GG is enabled and an `.enabled(username:)` availability exists, also retain the existing composed branch preview and add the pinned base when present. When effective GG is enabled but availability is `.disabled(hint:)`, render that hint and set `ggConfigurationMissing` to true. Explicit or inherited Off remains creatable.

- [ ] **Step 5: Reset on repository changes, validate, and pass the raw mode**

In the project change handler, set:

```swift
ggMode = Self.ggModeAfterRepositoryChange(current: ggMode)
```

Extend `canCreate` with `ggConfigurationMissing: Bool = false` and include `!ggConfigurationMissing` in its guard. Pass that value from both the confirm button and submit path.

Pass the raw mode into creation:

```swift
let id = await state.createWorktree(
    projectId: project.id,
    base: base,
    branch: effectiveBranch,
    destination: dest,
    runStartup: runStartup,
    launchSurface: surface,
    ggWorktreeMode: ggMode
)
```

Remove `stackModeSurvives`, rename `activeName(createAsGGStack:...)` to `activeName(createsGGStack:...)`, and update its callers and tests.

- [ ] **Step 6: Run dialog and GG policy tests and verify GREEN**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/NewWorktreeDialogTests \
  -only-testing:AlasTests/GGStackCreateModeTests \
  -only-testing:AlasTests/GGWorktreeContextTests
```

Expected: all three suites pass with zero failures.

- [ ] **Step 7: Commit Task 3**

```bash
git add Alas/Sources/Dialogs/NewWorktreeDialog.swift AlasTests/NewWorktreeDialogTests.swift
git commit -m "feat: add GG mode to new worktree creation"
```

---

### Task 4: Run project-wide verification

**Files:**
- Modify only files required to fix failures caused by Tasks 1-3.

**Interfaces:**
- Consumes: the complete implementation from Tasks 1-3.
- Produces: a regenerated project and a build/test-verified branch ready for final review and publication.

- [ ] **Step 1: Regenerate the Xcode project**

```bash
xcodegen
```

Expected: generation succeeds. If the generated project changes, inspect and commit it only when the source project definition requires that change.

- [ ] **Step 2: Build the macOS app**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit status 0 with no compiler errors.

- [ ] **Step 3: Run the full test suite**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **` with zero failures.

- [ ] **Step 4: Inspect and commit any verification-only corrections**

If Steps 1-3 required corrections, rerun the affected focused suite before the full commands and commit only those corrections:

```bash
git add Alas/Sources/App/AppState.swift \
  Alas/Sources/Dialogs/NewWorktreeDialog.swift \
  Alas/Sources/Integrations/GG/GGStackCreateMode.swift \
  Alas/Sources/Integrations/GG/GGWorktreeContext.swift \
  AlasTests/AppStateCleanupTests.swift \
  AlasTests/GGStackCreateModeTests.swift \
  AlasTests/Integrations/GGWorktreeContextTests.swift \
  AlasTests/NewWorktreeDialogTests.swift
git commit -m "fix: complete new worktree GG mode integration"
```

If no correction or generated-project diff exists, do not create an empty commit.
