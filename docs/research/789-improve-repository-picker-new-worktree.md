---
task_id: 789
title: "Improve repository picker in New Worktree dialog"
date: 2026-05-12
project: alas
phase: groomed
prior_art:
  - Alas/Sources/Dialogs/NewWorktreeDialog.swift
  - Alas/Sources/Dialogs/BranchPicker.swift
  - Alas/Sources/UI/Seg.swift
  - Alas/Sources/Persistence/ProjectConfig.swift
  - Alas/Sources/App/ProjectsManager.swift
  - AlasTests/NewWorktreeDialogTests.swift
---

## TL;DR

The repository selector in `NewWorktreeDialog` uses `Seg` — a horizontal
segmented control that renders every project as a button in an `HStack`.
This breaks with many repos: buttons overflow horizontally with no scroll,
truncation, or search. The fix replaces `Seg` with a popover-based picker
modeled on the existing `BranchPicker` pattern, which already handles
arbitrarily long lists with search, scroll, and a compact trigger button.

## Current state

### Seg component (`Alas/Sources/UI/Seg.swift`)

- Generic `HStack`-based segmented control, 32 lines.
- Renders **all** options as inline buttons — no max width, no scroll, no
  overflow handling.
- Works fine for ≤5 items; becomes cramped/clipped with 10+.

### NewWorktreeDialog usage (line 36-38)

```swift
Seg(value: $projectId,
    options: state.projects.map { ($0.id, $0.name) })
```

- Shown when `presetProject == nil` (global "New worktree" action).
- Hidden when a valid preset project is provided (context-menu creation).
- `projectId` drives branch loading and worktree creation downstream.

### BranchPicker (existing scalable pattern)

- Compact trigger button showing current selection + chevron.
- Popover with editable text field, search field, `ScrollView` + `LazyVStack`
  capped at 320pt height.
- Already battle-tested in the same dialog for branches.

## Proposed approach: `ProjectPicker` popover

Create a new `ProjectPicker` view following the `BranchPicker` pattern:

### Trigger button
- Shows selected project name (with optional color dot from `ProjectConfig.color`).
- Chevron down indicator, same styling as `BranchPicker`.

### Popover content
- **Search field** — filters projects by name (same `AlasField` pattern).
- **Scrollable list** — `ScrollView` + `LazyVStack`, `maxHeight: 320`.
- Each row: color dot + project name + checkmark for current selection.
- Click selects and dismisses popover.

### Ordering
- Default order: `state.projects` as-is (insertion order via `addedAt`).
- No frequency tracking exists today; adding `lastUsedAt` to `ProjectConfig`
  is out of scope for v1 — it would require persistence migration and touches
  every worktree-creation and terminal-open path. Can revisit in a follow-up.
- If a "most used first" tier is desired later, it layers cleanly on top of
  the picker's sort without UI changes.

### What NOT to do
- Don't add a "show 2 + more" hybrid — it introduces two selection modes
  for the same field, which is confusing when the popover alone handles all
  scales (1-100+ repos) uniformly.
- Don't modify `Seg` itself — it's still appropriate for small fixed option
  sets elsewhere (if any).

## Scope confirmation

### In scope (v1)
- New `ProjectPicker` view (popover-based, with search).
- Replace `Seg` usage in `NewWorktreeDialog` with `ProjectPicker`.
- Preserve all existing behavior: preset project hiding, `projectId` binding,
  `onChange` branch reloading, default selection logic.
- Unit tests for filtering/selection logic (pure functions, testable without
  UI harness).

### Out of scope
- Usage-frequency tracking / "most used" sorting (needs `ProjectConfig`
  schema change + persistence migration).
- Removing or changing the `Seg` component itself (may be used elsewhere or
  useful for other small option sets).
- Visual redesign of the dialog beyond the repository field.

## Key files to change

| File | Change |
|------|--------|
| `Alas/Sources/Dialogs/ProjectPicker.swift` | **New** — popover picker view |
| `Alas/Sources/Dialogs/NewWorktreeDialog.swift` | Replace `Seg` with `ProjectPicker` (lines 35-38) |
| `AlasTests/NewWorktreeDialogTests.swift` | Add tests for `ProjectPicker` filtering logic |

## Risks & considerations

- **Binding contract**: `ProjectPicker` must bind `$projectId` the same way
  `Seg` does — a `@Binding var value: String`. The `onChange(of: projectId)`
  in the dialog triggers branch reloading; this must keep working.
- **Popover stacking**: The dialog already uses `BranchPicker` with a popover.
  Two `.popover()` modifiers on different fields in the same sheet should work
  fine in SwiftUI (each is anchored to its own view), but worth a quick manual
  test.
- **Color dot**: `ProjectConfig.color` is a hex string. Need a small helper
  to convert to `Color` if one doesn't exist. Check before adding.

## Estimate

Small — ~150 lines of new code (mostly mirroring `BranchPicker`), a few-line
edit in the dialog, and a handful of new test cases. Single-PR scope.
