# Worktree Creation Lifecycle Design

## Context

Alas inserts and selects an optimistic worktree row before running `git
worktree add`. While the row has a `.creating` operation state, the center and
right panes show creation progress instead of querying the incomplete
worktree.

`ProjectGitWatcher` independently watches the repository Git directory. A new
linked worktree appears in `git worktree list` early in `git worktree add`,
before checkout has necessarily materialized every file. The watcher can call
`ProjectsManager.refreshWorktrees` during this interval. The current
reconciliation logic treats presence in the Git worktree list as creation
completion and clears `.creating`, allowing `RightPaneState` to run `git
status` and `git diff HEAD` against a partial checkout.

This is highly visible in `android_stb` because its checkout takes longer than
the project topology watcher's debounce. A measured temporary-worktree probe
showed:

- Git listed the worktree after 0.162 seconds while `git worktree add` was
  still running.
- At 0.198 seconds, 3,470 files existed while `git diff --numstat HEAD`
  reported all 9,632 tracked paths as deleted, totaling 668,177 deleted
  lines.
- The worktree became clean around 3.2 seconds.
- `git worktree add` returned around 4.9 seconds.

Smaller repositories usually finish checkout before the 0.5-second topology
debounce fires, which hides the race.

The repository also runs asynchronous post-checkout setup, but a second probe
confirmed the worktree remains clean after `git worktree add` returns while
that setup runs. The false snapshot comes from exposing the worktree during
checkout, not from the background setup phase.

## Goals

- Keep the creation-progress UI visible for the complete create workflow:
  checkout, configured startup script, and final project refresh.
- Prevent the changes and files pipelines from querying a partially checked
  out worktree.
- Continue allowing project topology refreshes while creation is in progress.
- Preserve optimistic row insertion, immediate selection, failure recovery,
  and canonical worktree metadata reconciliation.
- Use lifecycle ownership instead of debounce intervals, delays, or
  repository-specific heuristics.

## Non-Goals

- Change Git worktree creation commands or repository hooks.
- Wait for repository-owned background post-checkout jobs after `git worktree
  add` returns.
- Add a new user-visible finalizing state.
- Suppress or reinterpret legitimate large deletions outside worktree
  creation.
- Change delete-worktree lifecycle behavior.

## Design

The task started by `AppState.createWorktree` owns the `.creating` lifecycle.
Only that task may clear `.creating` after the complete workflow succeeds.

`ProjectsManager.refreshWorktrees` remains responsible for discovering live
Git worktrees and reconciling row data. When a worktree with a `.creating`
operation state appears in the Git list, the manager replaces the optimistic
row with the live `Worktree` value but preserves `.creating`. Git discovery
means the worktree exists; it does not mean the owning checkout workflow has
completed.

The successful create flow becomes:

1. Insert the optimistic row, set `.creating`, and select it.
2. Run the optional pre-create fetch.
3. Await `git worktree add`.
4. Await the configured worktree startup script when enabled.
5. Refresh project worktrees so the optimistic row is replaced with canonical
   Git metadata.
6. Explicitly clear `.creating` in `AppState.createWorktree`.
7. Re-select the canonical row and perform the requested launch action.

The right-pane selection resolver already maps `.creating` to the progress UI.
Preserving that state prevents `RightPaneView` and `RightPaneState` from being
created during checkout, avoiding both the false snapshot and the expensive
status/diff work that caused visible lag.

No arbitrary settling delay is added. The owner already has the authoritative
completion signal: return from the awaited create, startup, and refresh
operations.

## Error Handling

Existing failure behavior remains:

- A fetch failure remains best-effort and does not fail creation.
- A checkout, startup orchestration, or final refresh error changes the
  operation state to `.createFailed` with the original base branch for retry.
- A later topology refresh may clear `.createFailed` if Git shows that the
  worktree exists, preserving recovery from a transient final refresh failure.
- Removing a project while creation is running continues to make the owning
  task return without mutating removed project state.

The success path clears `.creating` only after the final refresh succeeds.
There is no fallback in generic topology reconciliation that can expose the
worktree early.

## Testing

Focused Swift Testing coverage will verify:

- Refreshing topology while a `.creating` worktree is already visible to Git
  preserves the `.creating` operation state.
- That refresh still replaces optimistic row metadata with the canonical live
  `Worktree` data.
- The complete `AppState.createWorktree` success path explicitly clears the
  operation state.
- Existing create-failure and retry behavior continues to work.
- Existing selection resolver coverage continues to prove that `.creating`
  renders progress rather than the active right pane.

The standard project generation, build, and test commands remain the final
verification gate.

## Alternatives Considered

### Add a Finalizing State

A separate `.finalizing` state could distinguish Git discovery from full
workflow completion. It would produce the same UI behavior but expand the
operation state model and all exhaustive switches without a current product
need.

### Suppress Suspicious Diff Snapshots

Alas could reject all-delete snapshots while checkout indicators such as
`index.lock` exist. This would treat the visible symptom, still run expensive
Git commands during checkout, and depend on Git implementation details that do
not express the actual application lifecycle.

### Delay Topology Refresh

Increasing the watcher debounce or adding a fixed post-discovery delay would
only move the race. Checkout duration varies by repository, storage, filters,
and hooks, so no fixed interval provides a correctness guarantee.
