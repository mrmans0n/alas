# Sidebar Worktree Sort Menu Design

## Summary

Add a compact menu to the left sidebar header for changing the global worktree ordering. The control stays visually hidden until the user hovers anywhere over the header, avoiding permanent toolbar density while keeping sorting close to the list it affects.

The menu is a second surface for the existing **Settings → Worktrees → Default ordering** preference. It does not introduce a new sort model or per-project sort selector.

## Goals

- Make the global worktree ordering readily available from the sidebar.
- Communicate that the setting applies across repositories rather than to one repository.
- Avoid adding permanent visual density to the sidebar header.
- Preserve per-repository manual ordering created by drag-and-drop.
- Keep the sidebar menu and Settings picker synchronized through one mutation path.

## Non-goals

- Adding a separately chosen automatic sort mode for each repository.
- Removing or changing drag-and-drop manual ordering.
- Removing the repository context menu's **Reset Sort to Default** action.
- Changing the ordering algorithms or the rule that pins the main worktree first.

## Placement and visibility

Place the sort control in `SidebarHeaderView`'s existing trailing action cluster, immediately before Search. Use a compact semantic sort glyph and the help text **Sort worktrees**.

The sort control is visually hidden in the header's resting state. It fades in when the pointer is anywhere within the full sidebar header, not only when the pointer reaches the control's bounds. It remains visible while its menu is open and when reached through keyboard navigation. The control remains available to accessibility APIs while visually hidden. Search, Add Repository, Settings, and Hide Sidebar retain their current always-visible behavior.

The control must not change the header's height or shift the existing actions when its visibility changes. Its layout space remains reserved; only its visual presentation and pointer interaction change.

## Menu interaction

Use a standard macOS menu rather than a popover or cycling button. Show all existing `AppConfig.WorktreeSortMode` values directly:

- Last update time (most recent first)
- Last update time (least recent first)
- Creation time (newest first)
- Creation time (oldest first)
- Branch name
- Manual

Mark the current global mode with a checkmark. Opening the menu does not mutate state. Selecting the already-active mode is a no-op. Selecting another mode updates and persists the global preference immediately, then reapplies ordering to repositories that inherit the global default.

## Manual overrides

A repository becomes manually ordered when the user drags its worktrees. Changing the global mode from the header does not clear or alter such an override. The repository continues to display its manual order.

The existing **Reset Sort to Default** item in the repository context menu remains the way to clear that repository's manual override. After reset, the repository immediately follows whichever global mode is currently checked in the header menu and Settings picker.

The menu's checkmark always represents the global default. It does not attempt to summarize whether some repositories currently have manual overrides.

## State ownership and data flow

Add one `AppState` action for changing the default worktree ordering. It owns the complete mutation sequence:

1. Return without work when the requested mode already matches the configured mode.
2. Update `config.worktrees.defaultOrdering`.
3. Persist the app configuration.
4. Ask `ProjectsManager` to reapply ordering across projects.
5. Persist project state if reapplication normalizes stored worktree-order data.

Both `WorktreesPane` and the new sidebar menu call this action. The existing private Settings binding becomes a thin adapter around the shared action rather than duplicating persistence and reapplication logic.

`SidebarView` passes the configured mode and the change callback into `SidebarHeaderView`. `SidebarHeaderView` owns only menu presentation, hover/focus visibility, and accessibility metadata. Sorting and persistence remain outside the view.

## Failure behavior

This feature adds no new fallible operation or recovery UI. It follows the existing local config/project persistence behavior. The menu selection updates the observable in-memory state immediately, so both surfaces remain synchronized during the current app session.

## Accessibility

- Expose the control as a menu button with the label/help **Sort worktrees**.
- Keep it reachable through keyboard navigation even when it is not visually shown by hover.
- Reveal it visually while keyboard-focused.
- Preserve a stable hit target consistent with the other sidebar toolbar buttons.
- Use the native checked state of menu items to communicate the selected mode without relying on color.

## Verification

Add focused regression coverage for the shared mutation and sidebar presentation:

- Changing the global mode updates the config and reapplies ordering.
- Inherited repositories adopt the new ordering.
- Repositories with manual drag-order overrides remain unchanged.
- Resetting a repository override makes it follow the active global mode.
- The Settings picker and sidebar menu read and mutate the same global value.
- The sort control exposes the expected accessibility label/help.
- Reserving the hidden control's layout space keeps the sidebar header height stable.

Run the focused tests, regenerate the Xcode project if test or source membership changes, then run the project build and test checks required by `AGENTS.md`.
