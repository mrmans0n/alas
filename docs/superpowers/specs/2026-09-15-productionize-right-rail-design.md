# Productionize the Right Pane Icon Rail

## Goal

Make the vertical icon rail the sole right-pane navigation and reveal surface.
The old horizontal tab bar and its persisted opt-out are retired. The Run tab
remains separately preview-gated.

## Scope

- Remove the `rightPaneRailEnabled` and `rightPaneRailDefaultApplied` config
  fields, their decoder migration, and the Advanced settings toggle.
- Remove `RightPaneTabBar` and its associated layout model and tests.
- Make `RightPaneView` and `RightPaneTransitionalView` always render the rail.
- Make `RightRailSizing` always reserve the 36pt rail whenever the right-pane
  body is hidden, including automatic narrow-window collapse.
- Keep the right pane's ordinary visibility preference, selected-tab behavior,
  rail badges, and collapsed-pane interactions unchanged.
- Keep Run availability controlled by `runTabEnabled`; do not graduate or alter
  that preview feature as part of this work.

## Architecture and Data Flow

`RootView` always passes `RightPaneRail.width` as the collapsed right-side
width for a selected worktree. `ThreePaneLayout` delegates the sizing decision
to `RightRailSizing`, which reserves that width only when the body cannot be
shown. The expanded pane continues to contain the rail within its own width.

`RightPaneView` owns the active worktree state and renders a body-plus-rail
`HStack`. `RightPaneTransitionalView` uses the same shape for creating,
deleting, and failed worktrees, preserving a reveal affordance when no active
`RightPaneState` exists. Both resolve clicks and tab shortcuts through the
existing pure rail reducer.

`AppState.acceptsRightPaneTabShortcut(_:)` accepts any available right-pane
tab. Availability continues to filter out Run while its independent preview
flag is disabled.

## Persistence and Compatibility

New config writes omit the retired rail keys. Existing config files that
contain either key still decode because Swift's keyed decoding ignores unknown
keys. No migration is required: the product behavior is now unconditional.

## Failure Handling

The rail remains mounted through user collapse and sizing-driven automatic
collapse, so the user always has a direct recovery path to reopen the right
pane. Transitional worktrees keep the same rail behavior without allocating a
`RightPaneState`. If Run is disabled, both rail rendering and shortcuts omit
that destination.

## Verification

- Replace persistence tests for the retired migration with an old-config
  compatibility test that includes the old keys and verifies normal decoding.
- Update sizing tests to cover expanded, user-collapsed, and narrow-window
  automatic-collapse rail reservation without a feature flag parameter.
- Update shortcut tests to assert that Changes, Files, and Agent are accepted
  unconditionally, while Run follows `runTabEnabled`.
- Retain reducer and rail model tests for selection, collapse, badges, and
  accessibility-related behavior.
- Run Xcode project generation, focused tests, formatting, `git diff --check`,
  and the required macOS build and test commands.
