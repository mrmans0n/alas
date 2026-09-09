# Live gg landing UI

## Goal

Show a long-running `gg land` operation inside Alas while it waits for CI,
approval, or a GitLab merge train. Users can leave the initiating worktree,
return to the operation, cancel it, and restart after cancellation or failure.

Alas allows one active landing per repository. Landing continues when its tab
is closed or another worktree is selected. Quitting Alas cancels the process;
sessions do not survive an app restart.

## Compatibility

Alas detects live landing support by checking `gg land --help` for `--jsonl`.
With gg 0.10.2 or newer, confirmed lands use the live flow. Older gg versions
keep the existing `gg land --json --no-clean` behavior and final-result-only UI.
The upgrade does not remove or disable the existing landing action.

## User interface

### Landing tab

Starting a supported land opens or focuses one center tab named
`Land · <stack>`. The tab is scoped to the repository's active landing session,
even though TabsManager hosts it under the initiating worktree.

The header shows the stack name, completed count, total count, elapsed time,
and a Cancel button while the process runs. Each target entry has one row:

- Completed entries show their terminal outcome, such as merged, queued, or
  skipped.
- The active entry shows its current readiness or merge-train state, elapsed
  wait time, and any available CI, approval, pipeline, or queue-position data.
- Later entries remain pending.

Transient provider errors appear below the active row as warnings. A later
healthy heartbeat clears the transient warning. They do not mark the session
failed.

Cancel changes the button and header to a non-interactive Cancelling state.
Once gg exits, the tab shows Cancelled, the number already completed, the
number remaining, and Restart landing. A failed or partial result keeps all
reported outcomes visible, shows the stopping error, and offers the same
restart action. A successful result shows the final summary and no restart
button.

Closing the tab never cancels landing. Landing tabs are transient and are not
written to the restored-tabs file, so relaunching Alas does not reopen a stale
session.

### Prepare card

While any worktree from the repository is selected, the existing Prepare area
shows a compact landing card. It contains the completed and total counts, the
active PR or MR and its short state, and an Open landing button. It has no
duplicate timeline or Cancel button. Open landing returns to the existing tab,
using the initiating worktree as its host.

After success, cancellation, or failure, the compact card disappears. The
Landing tab retains the terminal result until the user closes it or starts a
replacement session.

## Process ownership

A main-actor repository-scoped landing store owns the active session, its
presentation state, and the task that consumes gg output. It is keyed by
project ID, matching the repository scope already used by `GGInboxStore`.
This placement keeps the process alive independently of worktree selection and
lets every worktree's Prepare view find the same session.

The session records:

- Project, initiating worktree, stack, base, and original `--until` target.
- The preflight stack entries used to seed the tab rows.
- Start time, lifecycle state, latest wait heartbeat, terminal entry outcomes,
  warnings, and summary.
- The streaming task and a cancellation-request flag.

The existing mutation coordinator remains responsible for stack preflight,
stale-target protection, mutation gating, post-operation refreshes, inbox
invalidation, and result summaries. Live landing adds an event callback to the
land execution path rather than creating a second mutation pipeline.

The store refuses a second land for the same project and focuses the existing
tab. It does not block sync or other gg work in another stack while landing is
waiting. gg 0.10.2 releases its repository operation lock between provider
polls and reacquires it for mutations.

## Command and event flow

After the existing confirmation and fresh-stack validation succeed, Alas runs:

```text
gg land --until <stable-target> --wait --jsonl --no-clean
```

The runner reads and flushes each NDJSON line without imposing Alas's existing
ten-minute streaming timeout. gg's configured landing wait timeout remains the
only operation timeout.

Alas accepts version 1 events whose command is `land`:

- `start` confirms the stack, base, and total entry count.
- `wait` updates the active position and heartbeat fields. `phase` selects
  readiness or merge-train presentation.
- `entry` records a terminal outcome for one position.
- `summary` completes the normal result path. Alas inspects the summary's error
  field because a partial failure may still exit successfully.
- `error` terminates the session when setup fails before a summary.

The parser rejects a mismatched command or version, duplicate start events,
events before start, invalid positions, duplicate terminal outcomes, and any
event after summary or fatal error. A stream that ends without a terminal event
is a protocol failure unless the user requested cancellation.

The preflight snapshot supplies titles and pending rows because `start` contains
only the total. `wait` locates the active row by position and PR or MR number.
`entry` replaces the corresponding pending or active row with gg's reported
outcome. The summary is authoritative for final counts, warnings, and error.

## Cancellation and restart

Cancel sends SIGINT to the gg process group, matching terminal Ctrl-C behavior.
The process runner waits for gg and its descendants to exit, then uses SIGKILL
only after the existing grace period. Alas does not report user cancellation as
a command error and never attempts to undo remote merges.

The session remains Cancelling until process exit. Any terminal entry event
received before exit is applied, so the final cancelled view reflects work that
completed before gg reached its safe interruption point.

Restart discards the previous attempt's event history and reruns the normal
preflight with the original stable target. gg skips entries already merged. If
the stack or target no longer matches the confirmed scope, Alas does not launch
gg and shows the stale-target error. The user must then close the tab and start
a new landing action from the current stack.

## Errors

- Transient `wait` errors are warnings and clear after a healthy heartbeat.
- An `entry` error marks that row failed and remains visible through the final
  summary.
- A summary error produces a terminal partial-failure state with Restart.
- A fatal `error`, nonzero exit without a terminal event, malformed event, or
  premature EOF produces a terminal failure with the decoded message.
- Cancellation requested by the user takes precedence over the expected
  interrupted-process exit status.
- Refresh failures after a terminal gg result do not rewrite the landing
  outcome. They use the existing mutation error presentation.

## Testing

Use Swift Testing for model, service, store, and routing coverage:

- Decode every version 1 event and reject invalid ordering, identity, and
  positions.
- Project heartbeats into readiness, approval, CI, merge-train, warning, and
  elapsed-time presentation.
- Apply terminal entry and summary outcomes, including queued entries and
  partial failures.
- Enforce one active landing per project while allowing other projects.
- Keep a session alive across tab closure and worktree selection changes.
- Cancel once, wait for exit, suppress the expected interruption error, and
  retain completed outcomes.
- Restart through fresh preflight and reject a stale or missing target.
- Keep the existing final-only service path when `--jsonl` is unavailable.
- Open or focus one Landing tab and render the compact Prepare card only while
  the session is active.
- Verify a streaming subprocess receives SIGINT and that its descendants exit.

The normal project build and test suite remain the final verification.
