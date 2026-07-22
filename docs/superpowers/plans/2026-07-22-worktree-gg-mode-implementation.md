# Worktree GG Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make GG mode a stable worktree policy with repository defaults, main-worktree opt-out, branch-prefix eligibility, and consistent UI and agent integration for empty or temporarily unavailable stacks.

**Architecture:** Add a pure `GGWorktreeContextResolver` that separates persisted policy from runtime availability and branch eligibility. Persist sparse `Inherit / On / Off` worktree overrides in `ProjectConfig`, then feed the resolved context into the right pane, sidebar, ACP preamble, and GG MCP injection. Replace commit-trailer presentation gating with explicit stack-load state so empty and failed loads remain in GG mode.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation, Swift Testing, XcodeGen, existing GG CLI integration.

---

## File Map

- Create `Alas/Sources/Integrations/GG/GGWorktreeContext.swift` for policy and resolution.
- Modify `ProjectConfig`, `ProjectsManager`, and `AppState` for persistence and shared context.
- Modify `RightPaneStore`, `RightPaneState`, `ChangesTabView`, and `GGStackDrawer` for stable presentation.
- Modify `WorktreeRowView`, `RepoGroupView`, `SidebarView`, and `ChangesPane` for controls and status.
- Update ACP/MCP providers in `AppState` to use the same effective context.
- Add focused Swift Testing coverage and regenerate `Alas.xcodeproj/project.pbxproj`.

### Task 1: Persisted Policy And Pure Resolver

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGWorktreeContext.swift`
- Modify: `Alas/Sources/Persistence/ProjectConfig.swift`
- Modify: `Alas/Sources/App/ProjectsManager.swift`
- Create: `AlasTests/Integrations/GGWorktreeContextTests.swift`
- Modify: `AlasTests/GGConfigCodableTests.swift`

- [ ] **Step 1: Write failing resolver and Codable tests**

Cover linked `Off / Auto / On`, main inherited Off, explicit overrides both ways, global and remote hard stops, missing username, simple and nested prefixes, invalid `username/`, sparse encoding, and tolerant old-config decoding.

```swift
@Test func mainInheritsOffButCanBeEnabled() {
    let inherited = GGWorktreeContextResolver.resolve(
        masterEnabled: true, ggInstalled: true, isRemoteProject: false,
        projectMode: .on, worktreeOverride: .inherit, isMainWorktree: true,
        repoHasGGConfig: true, branchUsername: "nacho", branch: "nacho/stack"
    )
    #expect(inherited == .inactive(.policyOff))

    let enabled = GGWorktreeContextResolver.resolve(
        masterEnabled: true, ggInstalled: true, isRemoteProject: false,
        projectMode: .off, worktreeOverride: .on, isMainWorktree: true,
        repoHasGGConfig: true, branchUsername: "nacho", branch: "nacho/stack"
    )
    #expect(enabled == .active(stackName: "stack"))
}

@Test func nestedStackNamesAreEligible() {
    #expect(GGWorktreeContextResolver.stackName(
        branch: "nacho/team/feature", username: "nacho"
    ) == "team/feature")
    #expect(GGWorktreeContextResolver.stackName(branch: "nacho/", username: "nacho") == nil)
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGWorktreeContextTests \
  -only-testing:AlasTests/GGConfigCodableTests
```

Expected: compilation fails because the new policy types and persisted map do not exist.

- [ ] **Step 3: Implement policy types and resolver**

Create this module contract:

```swift
enum GGWorktreeMode: String, Codable, Equatable, CaseIterable {
    case inherit, on, off
}

enum GGWorktreeInactiveReason: Equatable {
    case masterDisabled, cliMissing, remoteProject, policyOff
    case branchUsernameMissing
    case branchPrefixMismatch(expectedPrefix: String)
}

enum GGWorktreeContext: Equatable {
    case active(stackName: String)
    case inactive(GGWorktreeInactiveReason)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}
```

`GGWorktreeContextResolver.resolve` must apply hard availability stops, resolve explicit override before the main/linked default, require `branchUsername + "/"`, and return the non-empty suffix as the stack name. Add `ggWorktreeModes: [String: GGWorktreeMode] = [:]` to `ProjectConfig`, with tolerant decoding and normal encoding. Add manager get/set/remove methods; setting `.inherit` removes the key.

- [ ] **Step 4: Run the Task 1 command and verify all selected tests pass**

### Task 2: Shared Context And Right-Pane Loading

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Right/RightPaneStore.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift`
- Modify: `AlasTests/RightPaneGGStackTests.swift`
- Create: `AlasTests/GGAppContextTests.swift`

- [ ] **Step 1: Write failing shared-context and empty-stack tests**

Test `AppState` context construction and prove an active context calls `currentStack` with no commits, nil becomes `.empty`, inactive does not call GG, and errors become `.failed` without deactivating context.

```swift
@Test @MainActor func activeContextQueriesGGWithoutGGIDCommits() async {
    let service = StubGGService(stack: nil)
    let state = makeState(ggService: service)
    state.ggContextProvider = { _ in .active(stackName: "empty-stack") }
    state.ggStackSourceCommits = []

    await state.refreshGGStack()

    #expect(service.currentStackCalls == 1)
    #expect(state.ggContext == .active(stackName: "empty-stack"))
    #expect(state.ggStackLoadState == .empty)
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGAppContextTests \
  -only-testing:AlasTests/RightPaneGGStackTests
```

Expected: compilation fails for the context provider and load state.

- [ ] **Step 3: Implement shared context and load lifecycle**

Add `AppState.ggWorktreeContext(project:worktree:branch:)` using app config, `GGAvailability`, main identity, repo config, username, override, and live branch. Replace `ggGateProvider` with `ggContextProvider` and add:

```swift
enum GGStackLoadState: Equatable {
    case inactive, loading, empty, loaded
    case failed(String)
}

var ggContext: GGWorktreeContext = .inactive(.policyOff)
var ggStackLoadState: GGStackLoadState = .inactive
var ggContextProvider: (@MainActor (_ branch: String) -> GGWorktreeContext)?
```

In `refreshGGStack`, publish current context first. Inactive clears stack, summary, cache, and load state. Active bypasses `isStackShaped`, calls `currentStack`, maps stack to `.loaded`, nil to `.empty`, and errors to `.failed(error.localizedDescription)` with cache key unset. Preserve cancellation, snapshot generation, paused-operation, and undo recovery guards.

- [ ] **Step 4: Run the Task 2 command and verify all selected tests pass**

### Task 3: Stable Changes And Drawer Presentation

**Files:**
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Modify: `Alas/Sources/Integrations/GG/GGStackDrawer.swift`
- Modify: `Alas/Sources/Right/ChangesPreparationModel.swift`
- Modify: `AlasTests/ChangesTabViewTests.swift`
- Modify: `AlasTests/Integrations/GGStackReadinessModelTests.swift`

- [ ] **Step 1: Write failing presentation tests**

Test active context shows GG drawer for loading, empty, and failed states; inactive without recovery does not. Test an active empty stack permits `New stack commit` while amend/absorb say `Create the first stack commit.` Test the retryable error presentation model.

```swift
@Test func activeEmptyContextShowsGGDrawer() {
    #expect(ChangesTabView.shouldShowGGDrawer(
        ggContextActive: true, stack: nil,
        pausedGGOperation: nil, hasUndoCandidate: false
    ))
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/ChangesTabViewTests \
  -only-testing:AlasTests/GGStackReadinessModelTests
```

Expected: drawer visibility still requires loaded stack or recovery.

- [ ] **Step 3: Implement stable presentation**

Include `rps.ggContext.isActive` in GG drawer and preparation selection. Add a pure placeholder model with `title`, `summary`, optional `detail`, and `canRetry`. Map loading to `Loading`, empty to `0 commits`, and failed to `Unavailable` plus the error and Retry. Reuse drawer layout and refresh button. Allow first commit for active empty context; keep amend and absorb disabled until a stack commit exists.

- [ ] **Step 4: Run the Task 3 command and verify all selected tests pass**

### Task 4: Sidebar Controls And Settings Copy

**Files:**
- Modify: `Alas/Sources/Sidebar/WorktreeRowView.swift`
- Modify: `Alas/Sources/Sidebar/RepoGroupView.swift`
- Modify: `Alas/Sources/Sidebar/SidebarView.swift`
- Modify: `Alas/Sources/Settings/ChangesPane.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Create: `AlasTests/GGWorktreeMenuModelTests.swift`
- Modify: `AlasTests/WorktreeRowHeightTests.swift`

- [ ] **Step 1: Write failing menu-model tests**

Create tests for selected raw mode, main inherited Off, prefix explanation, missing CLI, remote exclusion, and active empty-stack indicator using:

```swift
struct GGWorktreeMenuModel: Equatable {
    let selectedMode: GGWorktreeMode
    let effectiveActive: Bool
    let inactiveExplanation: String?
    let showsStatusIndicator: Bool
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGWorktreeMenuModelTests \
  -only-testing:AlasTests/WorktreeRowHeightTests
```

Expected: compilation fails because the menu model and row inputs do not exist.

- [ ] **Step 3: Implement menu, status, and settings UI**

Add `AppState.setGGWorktreeMode` to update the manager, save projects, and reevaluate gates. Pass the menu model, raw override, and setter through sidebar views. Add a `GG Mode` submenu with `Inherit repository default`, `On`, and `Off`, checkmark the raw selection, and show one disabled inactive explanation below a divider. Hide the submenu for remote worktrees. Show compact `GG` in the existing metadata row only when active and no loaded summary is present. Rename Settings copy to `Default for linked worktrees` and `Main worktrees default Off. Override individual worktrees from their sidebar menu.`

- [ ] **Step 4: Run the Task 4 command and verify all selected tests pass**

### Task 5: ACP, MCP, Inbox, And Deletion Consistency

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/App/ProjectsManager.swift`
- Modify: `AlasTests/ACP/ACPMCPPromptPreambleTests.swift`
- Modify: `AlasTests/Integrations/GGMCPInjectionTests.swift`
- Modify: `AlasTests/GGInboxTabsTests.swift`
- Modify: `AlasTests/GGConfigCodableTests.swift`

- [ ] **Step 1: Write failing integration tests**

Test active context attaches GG MCP and returns `.generic` preamble for an empty stack, inactive context attaches neither, loaded context returns `.stack`, Inbox availability ignores its hosting worktree override, deletion removes an override, and archive preserves it.

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/ACPMCPPromptPreambleTests \
  -only-testing:AlasTests/GGMCPInjectionTests \
  -only-testing:AlasTests/GGInboxTabsTests \
  -only-testing:AlasTests/GGConfigCodableTests
```

Expected: override and empty-stack cases fail against project-only gating.

- [ ] **Step 3: Route integrations through effective context**

Replace project-only guards in `ggMCPProvider` and `ggPreambleProvider` with shared worktree context. Return `.generic` for active context without loaded stack. Preserve configured MCP override precedence. Keep Inbox repository-capability driven: require the global switch, installed GG, a local project, and either local GG config, project mode `On`, or an explicit worktree `On`; do not consult the hosting worktree's effective mode. On successful deletion and failed optimistic removal, remove the override and save; preserve it on archive.

- [ ] **Step 4: Run the Task 5 command and verify all selected tests pass**

### Task 6: Full Verification

**Files:**
- Modify: `Alas.xcodeproj/project.pbxproj` via `xcodegen`

- [ ] **Step 1: Regenerate and check the diff**

```bash
xcodegen
git diff --check
git status --short
```

Expected: generation succeeds; only approved GG files, tests, project output, and plan are present.

- [ ] **Step 2: Run focused GG regressions**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/GGWorktreeContextTests \
  -only-testing:AlasTests/GGAppContextTests \
  -only-testing:AlasTests/RightPaneGGStackTests \
  -only-testing:AlasTests/ChangesTabViewTests \
  -only-testing:AlasTests/GGStackReadinessModelTests \
  -only-testing:AlasTests/GGWorktreeMenuModelTests \
  -only-testing:AlasTests/ACPMCPPromptPreambleTests \
  -only-testing:AlasTests/GGMCPInjectionTests
```

Expected: all selected tests pass.

- [ ] **Step 3: Run required repository verification**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: build and full test suite pass with exit code 0.

- [ ] **Step 4: Inspect final scope**

```bash
git status --short
git diff --check
git diff --stat
git diff
```

Expected: no unrelated changes and no tracked `.superpowers/brainstorm` files.
