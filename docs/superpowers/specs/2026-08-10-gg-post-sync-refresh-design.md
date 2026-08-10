# GG Post-Sync Refresh Completion Design

## Problem

Alas keeps a GG mutation marked in flight while it refreshes stack, Git, and
provider state after the GG command has already reached a terminal result. For
`gg sync`, the first follow-up operation is a direct `gg ls --json` call. That
call clears the visible stack into `.loading`, is not owned by the cancellable
background stack-refresh task, and inherits the ten-minute timeout intended for
mutating GG commands.

If the forge lookup inside `gg ls` stalls, the completed sync continues to look
active and the stack drawer can show a spinner for up to ten minutes. The 0.14.4
recovery only handles a stack-refresh task that is cancelled and unwinds; it
does not cover a live, un-cancelled read that is still waiting.

## Design

Treat mutation completion and follow-up presentation refresh as distinct
lifecycle phases.

When a GG command succeeds, Alas will record its summary, reconcile paused and
undo state, release the mutation reservation, and clear the action's in-flight
state before awaiting any follow-up refresh. When a GG command fails, Alas will
publish its terminal error and likewise release the reservation before running
the best-effort refresh. The returned mutation task may continue awaiting that
refresh for deterministic callers, but the observable action state is already
terminal and must not drive an action spinner.

The post-mutation stack refresh will use `RightPaneState`'s tracked
`ggStackRefreshTask` path. A watcher refresh or another explicit refresh can
therefore supersede and cancel it through the existing generation-aware
cancellation recovery instead of leaving an untracked `refreshGGStack` call
alive.

Read-only `gg ls --json` calls will use `Process.defaultTimeout` (30 seconds).
All other buffered GG commands and all streaming mutation commands retain the
existing 600-second timeout. Timeout selection belongs in
`ProcessGGCommandRunner`, so every current-stack read receives the bound
without changing the injectable `GGCommandRunning` protocol.

## Data Flow

1. Reserve the mutation and publish its action as in flight.
2. Load the preflight stack and execute the GG command.
3. Publish the command's terminal success, failure, summary, pause, and undo
   state.
4. Release `activeRequest` and clear `inFlightAction`.
5. Start the stack refresh through the tracked task and await it only as
   follow-up work.
6. Refresh Git changes and, for remote mutations, provider review state.
7. If `gg ls --json` exceeds 30 seconds, terminate it and publish the existing
   retryable stack-load failure. Do not turn a successful sync into a sync
   failure.

Watcher-triggered refreshes remain single-flight. Stack refresh generations
remain authoritative, so an older cancelled or delayed result cannot overwrite
a newer result.

## Error Handling

- A sync command failure remains a sync failure and retains its existing
  progress/error presentation.
- A successful sync followed by a stack-refresh failure remains a successful
  sync. The stack surface reports `Unavailable` with Retry.
- A timed-out `gg ls --json` maps through the existing stack-load error path.
- Cancellation recovery continues to restore a same-key stable stack or
  publish an interrupted, retryable failure.
- Releasing the mutation reservation is idempotent and must not clear a newer
  mutation's state if follow-up work overlaps with it.

## Testing

Add regression coverage at the two responsible boundaries:

1. Suspend the post-sync stack refresh after the sync summary arrives and
   verify `activeRequest` and `inFlightAction` are already clear, the sync
   summary is visible, and the action button no longer shows an in-flight
   spinner.
2. Resume the refresh and verify the mutation task completes and existing
   refresh ordering remains intact.
3. Verify `ProcessGGCommandRunner` selects 30 seconds for `gg ls --json`,
   including a client-operation prefix if one is ever present, and 600 seconds
   for mutating and streaming commands.
4. Keep the 0.14.4 cancellation regressions green to prove the tracked refresh
   still reaches a terminal state when superseded.

Run the focused GG coordinator, right-pane stack, service, and process-runner
tests before the full project build and test suite.

## Scope

This change does not alter GG's sync protocol, progress events, mutation
timeouts, forge authentication, retry policy, or the drawer's visual design. It
does not add automatic retry. It only separates terminal command state from
best-effort refresh state, makes the refresh cancellable through its existing
owner, and bounds read-only stack queries.
