# GG Stack Refresh Cancellation Design

## Problem

The stacked-diffs drawer can remain on its `Loading` placeholder indefinitely after a sync or another refresh trigger. `RightPaneState.refreshGGStack` clears the cached stack and sets `ggStackLoadState` to `.loading` before awaiting `gg ls --json`. When that task is cancelled, both its success and error paths return without publishing another load state. If no newer refresh completes, the drawer has no transition out of `.loading`.

## Design

Treat cancellation as a terminal result only when the cancelled refresh still owns the current GG refresh generation and the surrounding right-pane snapshot has not been invalidated.

Before starting the load, retain the previous stack, cache key, load state, and published summary. If the load is cancelled while it is still current:

- Restore the previous snapshot when it was successfully loaded for the same branch/context/commit key.
- Otherwise publish `.failed` with a concise interruption message, keep the cache key unset, clear stack-derived summary state, and preserve the existing Retry path.

A refresh superseded by a newer GG refresh must not publish cancellation recovery. The existing refresh-generation guard remains authoritative. A refresh superseded by `markSnapshotUnknown()` must also remain silent because that invalidation owns the replacement state.

This design does not change successful loads, command failures, inactive contexts, or the policy that prevents a stack loaded for one key from being shown under another key.

## Data Flow

1. Capture the last stable GG stack snapshot.
2. Mark the current snapshot as loading and invoke `gg ls --json`.
3. On success, publish the new stack as today.
4. On a non-cancellation failure, publish the existing `.failed` state as today.
5. On cancellation, first verify refresh and snapshot ownership, then restore a matching stable snapshot or publish an interruptible failure with Retry.

## Testing

Add a Swift Testing regression test using the controlled GG runner:

1. Load a stable stack successfully.
2. Start and suspend a forced reload for the same key.
3. Verify the drawer state becomes `.loading`.
4. Cancel and complete the suspended reload without starting a successor.
5. Verify the prior loaded stack, cache key, load state, and summary are restored.

Add a second assertion path for a cancelled first load or changed-key load, verifying it becomes `.failed` rather than remaining `.loading`. Existing stale-refresh tests continue to prove that an older cancellation cannot overwrite a newer successful refresh.

## Out of Scope

- Changing the ten-minute timeout used by mutating GG commands.
- Altering `gg sync` streaming or progress presentation.
- Retrying cancelled refreshes automatically while a pane is inactive.
