---
task_id: 791
title: "Add Projects application menu"
date: 2026-05-12
project: alas
phase: groomed
prior_art:
  - Alas/Sources/App/AlasApp.swift
  - Alas/Sources/App/RootView.swift
  - Alas/Sources/App/AppState.swift
  - Alas/Sources/App/ProjectsManager.swift
  - Alas/Sources/Dialogs/NewProjectDialog.swift
  - Alas/Sources/Dialogs/NewWorktreeDialog.swift
  - AlasTests/ProjectsManagerTests.swift
---

## TL;DR

Straightforward feature. The app already has a `CommandMenu("Terminal")` and
several `CommandGroup` blocks in `AlasApp.swift`, plus notification-based
dispatch handled in `RootView.swift`. Adding a `CommandMenu("Projects")` follows
the identical pattern. All three requested actions — Create Project, New
Worktree, and Refresh Worktrees — already have code paths that can be triggered
via new notifications. The only net-new behavior is a "Refresh Worktrees" action
that calls `ProjectsManager.refreshAll()` from a menu item.

## Scope confirmation

### In scope (v1)

- New `CommandMenu("Projects")` in `AlasApp.swift` with three items:
  - "Create Project..." — opens the add-project dialog
  - "New Worktree..." — opens the new-worktree dialog (move from current
    toolbar group to Projects menu, or duplicate as a second entry)
  - "Refresh Worktrees" — forces a full worktree list refresh
- Two new `Notification.Name` constants: `.alasCreateProject`,
  `.alasRefreshWorktrees`
- Corresponding `.onReceive` handlers in `RootView.swift`
- Keyboard shortcuts for the new items
- Unit test for `ProjectsManager.refreshAll()` round-trip (already partially
  covered, but the explicit "force refresh from menu" path should be tested)

### Out of scope (v1)

- **Enable/disable based on selection state** — SwiftUI `CommandMenu` buttons
  don't have direct access to `@State` from the `App` struct. Doing this
  properly requires either `FocusedValue`-based key commands or passing state
  through the environment. This is a meaningful design effort and can follow
  in a separate task. For v1, all three items stay always-enabled; actions
  that require a project (New Worktree, Refresh) gracefully no-op when no
  projects exist.
- **Per-project worktree refresh** — Refresh Worktrees refreshes all projects
  via `refreshAll()`. A targeted "refresh worktrees for selected project"
  refinement can come later.
- **Moving the existing "New Worktree..." out of the toolbar group** — Keep
  it in both places to avoid breaking existing muscle memory (Cmd+Option+N).
  The Projects menu entry can share the same notification.

## Architectural alignment

### Menu definition pattern

All menus are defined in `AlasApp.swift` (lines 18-174) inside the `.commands`
modifier on the main `Window`. The existing `CommandMenu("Terminal")` at line
112 is the exact template — a standalone top-level menu with buttons posting
notifications.

### Notification dispatch pattern

1. **Define** a `Notification.Name` constant in `RootView.swift` (lines
   322-346).
2. **Post** it from the `Button` action in `AlasApp.swift`.
3. **Handle** it via `.onReceive` in `RootView.CommandsModifier` (lines
   219-319).

### Code paths to reuse

| Action | Trigger | Existing handler |
|--------|---------|------------------|
| Create Project | `showNewProject = true` | `RootView` line 7, sheet at line 19 |
| New Worktree | `.alasNewWorktree` notification | `RootView` line 226-228 |
| Refresh Worktrees | `projectsManager.refreshAll()` | `ProjectsManager` lines 101-110, `AppState.saveProjects()` line 82-84 |

For **Refresh Worktrees**, the handler should call:
```swift
Task {
    if await state.projectsManager.refreshAll() {
        state.saveProjects()
    }
}
```
This mirrors the refresh pattern already used in `AppState.addProject()` (line
89).

### Keyboard shortcuts

| Action | Suggested shortcut | Rationale |
|--------|-------------------|-----------|
| Create Project... | Cmd+Shift+N | Parallels "New File" (Cmd+N), "New Worktree" (Cmd+Opt+N) |
| New Worktree... | Cmd+Option+N | Same as existing, shared notification |
| Refresh Worktrees | Cmd+Shift+R | Common "refresh" convention |

Verify no collisions with existing shortcuts before finalizing.

## Acceptance criteria

1. A "Projects" menu appears in the macOS menu bar between View and Terminal
   (or after Terminal — whichever reads better).
2. "Create Project..." opens the same dialog as the sidebar "+" button.
3. "New Worktree..." opens the same dialog as the existing Cmd+Option+N.
4. "Refresh Worktrees" calls `refreshAll()` and the sidebar updates without
   app restart.
5. All three items work when triggered via keyboard shortcut.
6. Existing "New Worktree..." shortcut (Cmd+Option+N) in the toolbar group
   continues to work.
7. Tests: `ProjectsManagerTests` covers the refresh-all-then-save round-trip.
8. Project builds with no warnings (`xcodebuild` clean build).

## Open questions

1. **Menu ordering**: Should "Projects" appear before or after "Terminal"?
   - Recommendation: **before** Terminal, since projects are a higher-level
     concept. `CommandMenu` ordering in SwiftUI is declaration order, so
     place the `CommandMenu("Projects")` block before `CommandMenu("Terminal")`.

2. **Should "New Worktree..." move out of the toolbar group?**
   - Recommendation: **keep it in both** for now. Removing it from the
     toolbar group changes discoverability for existing users.

3. **Should "Refresh Worktrees" show a progress indicator?**
   - Recommendation: **no** for v1. `refreshAll()` is fast (sequential
     `git worktree list --porcelain` per project). If it becomes slow
     with many projects, add a spinner later.

## Implementation order

1. **Add notification constants** — `RootView.swift`, add `.alasCreateProject`
   and `.alasRefreshWorktrees` to the `Notification.Name` extension (line 346).

2. **Add `CommandMenu("Projects")`** — `AlasApp.swift`, insert a new
   `CommandMenu` block before the `CommandMenu("Terminal")` at line 112.
   Three buttons posting the three notifications.

3. **Add `.onReceive` handlers** — `RootView.swift`, inside
   `CommandsModifier.body`:
   - `.alasCreateProject` → `showNewProject = true`
   - `.alasRefreshWorktrees` → `Task { ... refreshAll() ... }`

4. **Verify keyboard shortcuts** — check no collision with existing bindings
   in `SurfaceViewShortcutTests.swift`.

5. **Add/update tests** — `ProjectsManagerTests.swift`:
   - Test that `refreshAll()` returns expected worktree state after external
     worktree creation.

6. **Build & smoke test** — `xcodebuild`, launch app, verify menu appears
   and all three items work.

## Risks / things to watch

- **SwiftUI CommandMenu ordering** — the position of custom menus in the menu
  bar depends on declaration order, but SwiftUI may reorder relative to system
  menus. Verify at runtime that "Projects" lands where expected.
- **FocusedValue for enable/disable** — deferred to a follow-up, but worth
  noting that without it, "Refresh Worktrees" will silently no-op if called
  with zero projects. This is acceptable but not ideal UX.
- **Shortcut collisions** — Cmd+Shift+R might collide with browser-style
  "hard refresh" expectations if users have muscle memory from web dev. Low
  risk in a native macOS code editor context.

## Definition of done (handoff sign-off)

- All code paths referenced above verified against current source.
- No ambiguity in the implementation — an implementer can follow the
  implementation order step-by-step with no design decisions left open.
- Ready for design phase.
