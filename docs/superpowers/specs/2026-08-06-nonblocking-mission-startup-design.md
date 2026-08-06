# Non-blocking Mission Startup

Date: 2026-08-06
Status: Approved design

## Context

Alas persists global Mission tabs, including the active tab, across launches.
The current startup sequence refreshes every project's worktree topology before
it restores those global tabs or loads the local Mission snapshot. Worktree
discovery is asynchronous but can take several seconds across multiple or
remote repositories. During that interval Alas cannot present the previously
focused Mission, and Mission reconciliation remains part of the startup
critical path.

The Mission database is already isolated behind `MissionPersistence`, and the
center pane can render useful saved Mission content before live worktree,
agent, change, or review data is available. Startup should take advantage of
those boundaries instead of waiting for all derived state.

## Goals

- Restore a persisted focused global Mission as soon as startup begins.
- Keep the app responsive while Mission data and project topology load.
- Show an explicit loading state until the persisted Mission snapshot is
  available.
- Fill in worktree-derived Mission status after topology discovery and startup
  reconciliation complete.
- Preserve existing legacy worktree-tab migration and Mission recovery
  behavior.

## Non-goals

- Optimizing Mission Markdown rendering or changing the Mission pane layout.
- Changing Mission persistence, lifecycle rules, or reconciliation semantics.
- Refactoring all application startup work into a new coordinator.
- Displaying stale worktree, agent, changes, or review data as if it were live.

## Startup Flow

Startup separates fast persisted presentation state from slower derived state:

1. Start the harness as today.
2. Read the persisted global-tabs file immediately, without attempting legacy
   worktree-tab migration. This restores the active Mission identity early.
3. Begin loading the local Mission snapshot concurrently with project topology
   discovery.
4. While the active Mission record is loading, present the Mission tab chrome
   and a centered loading indicator in its content area.
5. Refresh all project topologies and load per-worktree tabs.
6. Run the existing global-tab legacy migration now that worktree tabs are
   available. Migration merges legacy Mission tabs into the already loaded
   global set rather than replacing current persisted state.
7. Once the local Mission snapshot and topology are available, run the existing
   repository, base-remote, interrupted-setup, readiness, and missing-worktree
   reconciliation.
8. Continue the remaining startup work independently; reconciliation must not
   gate initial worktree selection, watcher startup, or agent scanning.

Publishing the loaded Mission aggregate replaces the loading view. Later
reconciliation updates the same aggregate and its derived status in place.

## State and UI

`MissionController` exposes an explicit load state with three observable
outcomes: loading, loaded, and failed. Loading begins before the persistence
request and ends only after the controller publishes either aggregates or an
error.

`MissionTabView` distinguishes these cases when its requested aggregate is not
present:

- While Mission data is loading, show a spinner and concise `Loading Mission…`
  copy.
- After a successful load with no matching record, show the existing
  `Mission unavailable` state.
- After a load failure, show a non-blocking unavailable state with the existing
  persistence error surfaced in concise form.

The loading state occupies only the center content area. The restored global
tab remains visible and active, and the rest of the app remains interactive.
When the aggregate is available before topology discovery finishes, the pane
renders its saved source and activity immediately. Worktree-dependent fields
continue to use their existing unavailable copy until live state arrives.

## Global Tab Restoration

`GlobalTabsManager` gains separate operations for loading its persisted global
file and for migrating legacy worktree Mission tabs. The normal combined entry
point may remain as a compatibility wrapper for tests and non-startup callers.

Early loading is idempotent. The later migration must preserve user-visible
changes made after early restoration, such as closing or activating a global
tab, and merge only legacy tabs that are not already present. Persistence after
migration remains unchanged.

## Error Handling

Failure to read global tabs keeps the existing empty-tab fallback and reports
through the existing persistence error path. Failure to load Missions does not
stall topology refresh or other startup work. A failed reconciliation retains
the last successfully loaded aggregate and uses the controller's existing
`loadError` reporting rather than replacing the pane with a spinner.

Cancellation caused by the root view disappearing must stop outstanding
startup work without publishing partial results into a replacement app state.

## Testing

Regression coverage will verify:

- Persisted global tabs and their active Mission restore before legacy
  migration is possible.
- Legacy migration merges into an already loaded global-tab state without
  duplicating tabs or undoing a newer active-tab choice.
- A requested Mission renders the loading presentation while persistence is in
  flight.
- A missing Mission becomes unavailable only after a successful load finishes.
- A Mission load failure produces the error presentation without blocking
  other startup completion.
- Startup can complete initial selection, watcher setup, and agent scanning
  without waiting for Mission reconciliation.
- Existing Mission startup recovery and global-tab migration tests remain
  green.

The implementation will follow test-driven development: each observable
startup-ordering behavior is introduced with a failing Swift Testing test
before production code changes.
