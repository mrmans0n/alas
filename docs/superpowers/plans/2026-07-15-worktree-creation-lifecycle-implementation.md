# Worktree Creation Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent the changes/files panes from querying a new worktree until the create workflow has fully completed.

**Architecture:** `AppState.createWorktree` owns the `.creating` lifecycle because it is the only code path that awaits checkout, startup, and final refresh. `ProjectsManager.refreshWorktrees` continues reconciling live Git worktree rows but no longer treats Git visibility as creation completion.

**Tech Stack:** Swift 5.9+, SwiftUI app state, Swift Testing, Git worktree integration.

---

## File Structure

- Modify `AlasTests/ProjectsManagerTests.swift`
  - Update the existing creating-reconciliation regression so topology refresh preserves `.creating` after Git lists the worktree.
  - Assert the optimistic row is replaced by canonical live metadata.
- Modify `Alas/Sources/App/ProjectsManager.swift`
  - Preserve `.creating` during refresh even when the worktree is live in `git worktree list`.
  - Keep existing `.deleting`, `.createFailed`, and `.deleteFailed` reconciliation behavior.
- Modify `Alas/Sources/App/AppState.swift`
  - Explicitly clear `.creating` after the successful final refresh in `createWorktree`.
  - Keep failure paths setting `.createFailed`.
- Modify `docs/superpowers/plans/2026-07-15-worktree-creation-lifecycle-implementation.md`
  - Track implementation progress by checking off steps as they complete.

User requested one final conventional commit, so do not create per-task commits.

## Task 1: Lock Down Refresh Reconciliation

**Files:**
- Modify: `AlasTests/ProjectsManagerTests.swift`

- [x] **Step 1: Update the failing regression test**

Replace the existing `refreshReconcilesCreatingWorktree` test with this body:

```swift
@Test func refreshReconcilesCreatingWorktreeWithoutCompletingIt() async throws {
    let repo = try await makeRepo(name: "reconcile")
    defer { try? FileManager.default.removeItem(at: repo) }
    let mgr = ProjectsManager(persistedProjects: [])
    let project = try await mgr.addProject(path: repo, displayName: "reconcile", color: "#5fb7c4")
    try await mgr.refreshWorktrees(projectId: project.id)

    let svc = WorktreeService()
    let dest = repo.appendingPathComponent("wt-reconcile")
    let live = try await svc.add(
        repoPath: repo,
        base: "main",
        branch: "reconcile-b",
        destination: dest,
        projectId: project.id
    )

    let optimistic = Worktree(
        id: Worktree.makeId(path: dest),
        projectId: project.id,
        name: "optimistic-name",
        branch: "reconcile-b",
        path: dest,
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 0)
    )
    mgr.insertOptimisticWorktree(optimistic)
    mgr.setOperationState(id: optimistic.id, state: .creating)

    try await mgr.refreshWorktrees(projectId: project.id)

    let trees = mgr.worktrees(projectId: project.id)
    let reconciled = try #require(trees.first { $0.id == optimistic.id })
    #expect(reconciled.name == live.name)
    #expect(reconciled.lastActivity == live.lastActivity)
    #expect(mgr.operationState(for: optimistic.id) == .creating)
}
```

- [ ] **Step 2: Run the targeted test and verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ProjectsManagerTests/refreshReconcilesCreatingWorktreeWithoutCompletingIt
```

Expected: FAIL because `ProjectsManager.refreshWorktrees` still clears `.creating` when Git sees the worktree.

## Task 2: Preserve Creating State During Topology Refresh

**Files:**
- Modify: `Alas/Sources/App/ProjectsManager.swift`
- Test: `AlasTests/ProjectsManagerTests.swift`

- [x] **Step 1: Implement minimal reconciliation change**

In `ProjectsManager.refreshWorktrees(projectId:)`, replace the `.creating` switch branch with:

```swift
case .creating:
    if !liveIds.contains(id) {
        // Still pending; keep the optimistic row visible.
        if let optimistic = previousById[id] {
            reconciled.append(optimistic)
        }
    }
```

This leaves the live `trees` entry in `reconciled` when Git already lists the worktree, but preserves the operation state for `AppState.createWorktree` to clear.

- [ ] **Step 2: Run the targeted reconciliation tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ProjectsManagerTests/refreshReconcilesCreatingWorktreeWithoutCompletingIt -only-testing:AlasTests/ProjectsManagerTests/refreshKeepsCreatingWorktreeUntilGitSeesIt -only-testing:AlasTests/ProjectsManagerTests/refreshClearsCreateFailedWhenWorktreeAppears
```

Expected: PASS. This verifies live creating worktrees stay `.creating`, not-yet-live creating rows remain visible, and `.createFailed` recovery still clears when Git later shows the worktree.

## Task 3: Clear Creating on Successful Create Completion

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/AppStateCleanupTests.swift`

- [x] **Step 1: Add explicit success-path clearing**

In `AppState.createWorktree`, after the final `refreshWorktrees(projectId:)` succeeds, after the `guard projects.contains(where:)` check, and before `if wasHidden || gcDropped`, add:

```swift
projectsManager.setOperationState(id: optimistic.id, state: nil)
```

The resulting block should be:

```swift
let gcDropped = try await projectsManager.refreshWorktrees(projectId: project.id)
guard projects.contains(where: { $0.id == projectId }) else { return }
projectsManager.setOperationState(id: optimistic.id, state: nil)
if wasHidden || gcDropped {
    saveProjects()
}
```

- [ ] **Step 2: Run the targeted AppState create tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppStateCleanupTests/createWorktreeInsertsOptimisticRowImmediately -only-testing:AlasTests/AppStateCleanupTests/createWorktreeSelectsOptimisticRowImmediately -only-testing:AlasTests/AppStateCleanupTests/createWorktreeRetryAllowsFailedOptimisticDestination -only-testing:AlasTests/AppStateCleanupTests/createWorktreeFailureLeavesFailedRow
```

Expected: PASS. These tests cover immediate `.creating`, eventual success clearing, retry clearing, and failure preserving `.createFailed`.

## Task 4: Full Verification and Regression Sweep

**Files:**
- Modify: `docs/superpowers/plans/2026-07-15-worktree-creation-lifecycle-implementation.md`

- [x] **Step 1: Run project generation**

Run:

```bash
xcodegen
```

Expected: exit 0. If it changes `Alas.xcodeproj`, include that generated change.

- [ ] **Step 2: Run the macOS build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0 with no failing tests.

- [ ] **Step 4: Inspect the final diff**

Run:

```bash
git diff --check
git diff --stat
git diff -- Alas/Sources/App/AppState.swift Alas/Sources/App/ProjectsManager.swift AlasTests/ProjectsManagerTests.swift docs/superpowers/plans/2026-07-15-worktree-creation-lifecycle-implementation.md
```

Expected: no whitespace errors, and the diff is limited to the planned lifecycle fix, test update, and checked-off plan.

## Task 5: Final Commit, Rebase, PR, CI, and Codex Review

**Files:**
- Commit all implementation changes as one final conventional commit.

- [ ] **Step 1: Commit all changes as one conventional commit**

Use this commit message, adjusting the body only if the final diff differs materially:

```text
fix: keep new worktrees creating until ready

- Preserve creating state during topology refresh reconciliation
- Clear creating state from the create workflow after final refresh
- Cover live creating reconciliation and successful create completion
```

- [ ] **Step 2: Rebase on origin/main**

Run:

```bash
git fetch origin
git rebase origin/main
```

Expected: rebase completes cleanly. If conflicts occur, resolve them without dropping the lifecycle fix or tests, then rerun targeted tests impacted by conflict resolution.

- [ ] **Step 3: Push the branch**

Run:

```bash
git push --force-with-lease
```

Expected: branch updates on the remote.

- [ ] **Step 4: Open or update the PR**

Create or update the PR for `nacho/issue-creating-worktree` against `main`. The PR summary should mention:

- The root cause: topology refresh exposed a partial checkout by clearing `.creating`.
- The fix: refresh reconciles canonical row data but preserves `.creating`; the create task clears it after final refresh.
- Verification: `xcodegen`, build, and full test suite results.

- [ ] **Step 5: Loop until CI is green and Codex approves**

Check PR CI and Codex review status. If CI fails or Codex requests changes, inspect the failure/review, implement the smallest correct fix, rerun the relevant local verification command for that fix, rerun the full final gate before pushing, amend or add to the single final commit as needed, rebase on `origin/main`, push, and repeat until CI is green and Codex gives approval.
