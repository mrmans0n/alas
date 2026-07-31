# Progressive gg Sync Feedback Design

## Summary

Improve Alas's existing `gg sync --jsonl` integration so feedback begins as
soon as the user starts a sync and remains compact as each stack entry
progresses. This is an Alas-only change: it uses the JSONL events gg already
emits, caches JSONL support in the existing session capability probe, and
preserves the atomic `--json` fallback for older gg versions.

## Problem

Alas already selects `gg sync --jsonl` when the installed gg exposes the flag.
However, the user can still wait without useful status while Alas reloads the
stack, probes `gg sync --help`, and gg performs work before its first `start`
event. During this interval the drawer shows only the Sync button's small
spinner.

Once events arrive, Alas renders every transition as a separate row. A single
entry can therefore produce title, pushing, pushed, and PR rows instead of one
stable result. Alas also ignores existing `pr_updated` and
`pr_skipped_closed` events, so the visible history can be incomplete.

## Goals

- Show `Preparing sync…` immediately after Sync is reserved, including while
  Alas reloads the fresh stack snapshot.
- Use the session's cached gg capability result instead of running
  `gg sync --help` for every sync.
- Show one compact live status above stable, completed per-entry rows.
- Update a commit's row as later events for the same position arrive rather
  than appending another row for every transition.
- Present gg's existing `pr_updated`, `pr_skipped_closed`, and `push_error`
  events.
- Preserve completed rows from the current attempt when sync fails.
- Keep the final `summary` event as the success boundary.
- Preserve the atomic `gg sync --json` fallback for older gg versions.

## Non-goals

- Do not change git-gud or propose a new gg JSONL schema.
- Do not claim visibility into gg's internal provider, fetch, rebase, lint, or
  metadata-normalization phases before `start`.
- Do not generalize this into an application-wide mutation progress system.
- Do not add cancellation or change sync command semantics.
- Do not change Inbox streaming or progress behavior.
- Do not require new source files or Xcode project membership changes.

## Architecture

The existing boundaries remain in place:

1. `GGService` selects the output mode and streams stdout lines.
2. `GGSyncEvent` parses the supported sync event set.
3. `GGStackActionState` owns events and action lifecycle for the worktree.
4. `GGStackReadinessModel` reduces action state into presentation values.
5. `GGStackDrawer` renders those values.

Raw CLI events remain the source of truth. Alas does not insert a fake
`GGSyncEvent` to represent preparation. Instead, the readiness model derives
the initial status whenever `.sync` is in flight and the event list is empty.
This keeps client lifecycle state separate from the gg protocol.

### Cached JSONL Capability

Add `syncJSONL` to `GGCapabilities`. The existing session-scoped
`GGAvailability.probe` determines it alongside the other CLI capabilities by
inspecting `gg sync --help`. The result remains cached until the existing
forced reprobe after installing or upgrading gg.

Sync execution receives that resolved capability. Supported installations run:

```text
gg sync --jsonl
```

Unsupported installations run the existing fallback:

```text
gg sync --json
```

`GGService.sync` no longer launches its own `sync --help` subprocess. Tests and
other injected service users pass the capability explicitly, so output-mode
selection remains deterministic and does not depend on hidden global state.

### Event Model

Keep the existing sync event cases and add typed support for:

- `pr_updated(position, prNumber, action)`
- `pr_skipped_closed(position, prNumber)`

The existing suffix-based error handling continues to convert `push_error` and
future `*_error` events into a typed error carrying the event position when one
is present. This lets the presentation mark the affected row as failed while
still surfacing the command error.

Unknown non-error events remain ignorable for forward compatibility. Blank or
malformed lines remain ignored under the current tolerant sync contract. This
change does not adopt Inbox's stricter stream validation because sync already
supports older response shapes and tolerant event evolution.

The service does enforce the terminal boundary: a successful JSONL process
must yield a `summary` event. A clean exit without one is malformed output, and
data received after `summary` is also malformed. This prevents a truncated
stream from looking successful without making intermediate-event parsing
strict.

## Progress Reduction

Replace the readiness model's append-only `[String]` projection with a compact
sync presentation containing:

- an optional live status;
- stable completed rows ordered by stack position;
- whether the live status should display a spinner.

The reducer processes the accumulated events in order. Per-position state
retains the entry title once learned and upgrades the same row as later events
arrive.

### Live Status

The live status transitions as follows:

| State or event | Live status |
|---|---|
| Sync reserved, before the first event | `Preparing sync…` |
| `start(totalEntries)` | `Syncing 0 of N commits…` |
| `entry_started(position, title)` | `Syncing [position] title…` |
| `push_started(position)` | `Pushing [position] title…` |
| `push_done(position)` while awaiting the entry result | `Finishing [position] title…` |
| Terminal `summary` | No live status |
| Command failure | No live status |

When a title is not yet known, the reducer uses `[position]` without inventing
one. The wording describes only state Alas or gg has actually established.

### Stable Entry Rows

Each position contributes at most one row. Later events replace its status:

- `push_done`: `[1] Pushed`
- `pr_created`: `[1] Pushed · PR #42 created`
- `pr_updated`: `[1] Pushed · PR #42 updated`
- `pr_skipped_closed`: `[1] PR #42 already closed`
- `push_error`: `[1] Failed to push`

The title is kept in reducer state for the live line, while completed rows stay
short enough for the existing drawer width. A PR number remains plain status
text; this design does not add a new link interaction to progress rows.

Rows are sorted by position rather than event completion order. A new event for
an existing position updates that row in place, preserving stable SwiftUI
identity and preventing the drawer from growing by several rows per commit.

## Lifecycle and Presentation

`GGMutationCoordinator.reserve` already marks `.sync` in flight before the
fresh-stack reload. That is the immediate presentation boundary: the drawer
switches from actions and facts to the compact progress surface and shows
`Preparing sync…` without waiting for process launch.

During a JSONL sync, the drawer renders the spinner and live status first, then
any completed entry rows below it. Existing action buttons remain unavailable
while the mutation is reserved.

On a successful terminal `summary`, the coordinator derives the existing
one-line result such as `Synced · 2 pushed · 1 PR created`, clears transient
progress, refreshes stack and provider state, and returns to the normal drawer.

For the atomic JSON fallback, the drawer shows `Preparing sync…` for the whole
command. It then shows the existing final result or error. Alas does not invent
per-entry states that the fallback response cannot provide incrementally.

## Failure Semantics

An in-band `*_error` event records the message and marks the associated entry
failed when a position is available. If the process later exits nonzero, that
process error remains the authoritative command failure.

When sync fails, the spinner and live line stop. Completed and failed rows from
that attempt remain visible above the existing error message so the user can
see how far the command progressed. Starting any later action clears this
attempt's retained progress through the existing action lifecycle.

If sync pauses on conflicts, the same retained progress appears in the paused
recovery surface above Continue and Abort. No success summary is produced
without the terminal `summary` event.

Malformed or unknown non-error lines do not manufacture progress or success.
The command's exit status and terminal summary continue to decide the result.

## Component Changes

- `GGMutationModels.swift`: add the cached `syncJSONL` capability.
- `GGService.swift`: populate that capability during the session probe, accept
  it for sync output-mode selection, and remove the per-sync help probe.
- `GGActionEvents.swift`: model PR update/closed events and positional errors.
- `GGStackActionState.swift`: retain failed-attempt progress until the next
  action while preserving existing summary lifecycle.
- `GGStackReadinessModel.swift`: reduce raw events into one live status and
  stable per-position rows.
- `GGStackDrawer.swift`: render the live status with a spinner and completed
  rows with stable identity.
- Focused tests for each boundary above.

## Testing

### Event Parsing

- Decode `pr_updated` and preserve position, PR number, and action.
- Decode `pr_skipped_closed`.
- Preserve the position and message from `push_error`.
- Continue ignoring blank, malformed, and unknown future non-error events.

### Service and Capability Selection

- The startup capability probe detects `sync --jsonl` support.
- A supported capability launches `sync --jsonl` directly.
- An unsupported capability launches `sync --json` directly.
- Neither sync path launches `sync --help` during the mutation.
- The atomic fallback retains existing summary and error decoding.
- A JSONL process that exits cleanly without `summary` fails as malformed
  output.
- A JSONL event after `summary` fails as malformed output.

### Progress Reduction

- An in-flight sync with no events yields `Preparing sync…`.
- Start and entry events produce the specified live statuses.
- Multiple events for one position produce one upgraded row.
- Rows remain ordered by position when events arrive out of order.
- PR created, updated, closed, and push-failed states render correctly.
- Summary removes the live status and supports the existing final summary.
- A failed attempt retains completed rows without a spinner.

### Coordinator and Drawer

- `Preparing sync…` is observable while the fresh-stack reload is suspended.
- JSONL events update the drawer incrementally.
- Success clears transient rows and shows the result summary.
- Failure and paused-conflict states retain relevant rows with the error or
  recovery controls.
- Starting a later action clears retained failed-attempt progress.

## Verification

Run the focused Swift Testing cases for sync event parsing, service actions,
action state, readiness modeling, coordinator behavior, and right-pane GG stack
presentation. Then run the repository-required generation, build, and test
commands before completing the implementation change.
