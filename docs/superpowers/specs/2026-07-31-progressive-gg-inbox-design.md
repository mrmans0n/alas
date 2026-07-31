# Progressive gg Inbox Design

## Summary

Use the streaming inbox output added in gg 0.9.12 so Alas can show entries as
their remote refreshes complete instead of waiting for the entire inbox command.
Alas will require gg 0.9.12 or newer for its Inbox tab, expose an inline Homebrew
upgrade action for older installations, and treat the final JSONL `summary` as
the authoritative complete snapshot.

## Problem

Alas currently runs `gg inbox --json` and publishes the decoded snapshot only
after the process exits. Even though gg 0.9.12 refreshes candidates concurrently
and can flush each completion through `--jsonl`, Alas does not consume that
stream. One slow provider request therefore keeps the entire Inbox tab waiting.

The desired behavior is to make completed results useful immediately without
mixing entries from different refresh generations or weakening the correctness
of the final inbox.

## Goals

- Render included inbox entries as their JSONL completion events arrive.
- Show monotonic `Refreshing N/M` progress during a refresh.
- Keep stale and fresh refresh generations isolated.
- Reconcile progressive state with gg's final deterministic `summary`.
- Support gg 0.9.12's `refresh_failed` bucket and per-entry refresh errors.
- Keep a previously completed snapshot available if a refresh fails fatally.
- Require gg 0.9.12 or newer and offer a one-click Homebrew upgrade.
- Preserve the existing project-scoped cache, invalidation, and refresh deduplication behavior.

## Non-goals

- Do not fall back to `gg inbox --json` for older gg versions.
- Do not change gg itself or its JSONL schema.
- Do not add persistent inbox caching.
- Do not add an Inbox `--all` mode or display merged entries.
- Do not generalize this work into a new application-wide streaming framework.
- Do not change remote-project support or the existing gg project/worktree gates.

## Version Gate and Upgrade UX

The existing `GGAvailability` probe remains the source of the installed version.
Alas compares its raw version string with `0.9.12` using the existing
`SemanticVersion` type. Any parsed version greater than or equal to `0.9.12` is
supported.

The `gg Inbox` action remains discoverable whenever the project otherwise
qualifies for Inbox. Opening it with an older or unparseable installed version
shows an upgrade-required state instead of starting a command. The state shows
the detected version, states that gg 0.9.12 or newer is required, and provides
an `Upgrade gg…` action.

The upgrade action extends the existing Homebrew-backed gg install controller
with an upgrade operation that runs:

```text
brew upgrade mrmans0n/tap/gg-stack
```

After a successful command, Alas force-reprobes `GGAvailability`. If the new
version is supported, the tab automatically starts its Inbox refresh. Command
or reprobe failures remain visible inline and can be retried. This version gate
applies only to Inbox; older gg installations can continue using other Alas gg
features according to their existing capability gates.

## Architecture

The integration has three boundaries: typed event decoding in the model layer,
process streaming in `GGService`, and generation-scoped reduction in
`GGInboxStore`. `GGInboxTabView` only renders the resulting observable state.

### Typed Inbox Events

Add a `GGInboxEvent` model for the exact gg 0.9.12 event set:

- `start(totalCandidates, totalStackErrors)`
- `stackError(GGInboxStackError)`
- `entry(completed, totalCandidates, included, bucket, remoteState, entry)`
- `entryError(completed, totalCandidates, included, bucket, candidate, error)`
- `summary(GGInboxSnapshot)`
- `error(message)`

Every decoded line must have schema `version: 1` and `command: "inbox"`.
Unknown events, malformed event payloads, unsupported schema versions, or a
wrong command envelope are malformed output rather than ignorable progress.
This prevents a newer or damaged stream from being presented as a complete
inbox.

`GGInboxSnapshot` gains a `refreshFailed` bucket. `GGInboxEntry` gains an
optional `refreshError`, and its PR URL is represented as optional at the Alas
model boundary so an `entry_error` candidate can be presented before the final
summary. Empty URLs in summary entries normalize to `nil`.

### Streaming Service

`GGService.inboxStream(repoPath:)` launches:

```text
gg inbox --jsonl
```

at the project repository path through the existing true incremental
`GGCommandRunning.runStreaming` implementation. It decodes and yields one typed
event per flushed line.

The service validates stream-level completion in addition to individual lines:

- `start` must be the first event for a non-fatal run. A fatal `error` may be
  the sole event when the command fails before discovery.
- At most one `summary` may occur.
- A successful stream must contain a final `summary`.
- No data events may follow `summary`.
- An explicit `error` event is terminal and fatal; no later event is accepted.
  The process stream is still drained to termination before the refresh
  completes.
- A nonzero exit, malformed line, or clean exit without `summary` fails the
  stream.

The store does not need to understand process exit codes or raw JSONL.

### Generation-scoped Store Reduction

`GGInboxStore.refresh` continues to deduplicate concurrent refresh requests and
uses the existing invalidation generation as its publication guard. At refresh
start it captures the current completed snapshot as the rollback snapshot and
initializes a separate empty progressive generation. The existing snapshot
stays visible while gg performs local discovery.

Events reduce as follows:

1. `start` records `totalCandidates` and resets completed progress to zero.
2. `stackError` appends a discovery error to the progressive generation.
3. Every `entry` records gg's `completed` value. Included entries with a bucket
   are inserted into that progressive bucket. Excluded merged or closed entries
   advance progress but are not displayed.
4. `entryError` records progress and inserts an immediately visible entry into
   the `refreshFailed` bucket with its error text.
5. The first candidate completion (`entry` or `entryError`, including an
   excluded entry) switches the visible snapshot from the old generation to the
   new progressive generation. The two generations are never merged.
6. `summary` atomically replaces all progressive content with gg's authoritative
   snapshot, sets `fetchedAt`, clears refresh state and errors, and discards the
   rollback snapshot.

Partial bucket contents use stable stack-name and position ordering rather than
network completion order. gg's final summary supplies the authoritative bucket
and entry order.

If there are no candidate completions, the existing snapshot remains visible
until `summary` arrives. This covers an empty inbox and discovery-only stack
errors without a needless blank transition.

If an invalidation occurs during the stream, the old generation is prevented
from publishing any further partial or final state, matching the store's current
stale-completion protection.

## Presentation

During a supported refresh, the header keeps the existing spinner and adds
`Refreshing N/M` after the `start` event. Before `start`, it shows the spinner
without a count. The normal updated timestamp returns only after the final
summary succeeds.

The bucket order becomes:

1. Refresh failed
2. Ready to land
3. Changes requested
4. Blocked on CI
5. Awaiting review
6. Behind base
7. Draft

Progressive entries appear in these existing grouped sections as they arrive.
A refresh-failed row shows its stack, position, title, PR number, and concise
error text. The PR number is a browser action only when a valid URL is
available; otherwise it is non-interactive text.

The final summary remains the only state that updates `fetchedAt` or supports an
"Inbox is clear" claim. Partial state with zero currently included entries does
not show the clear-inbox empty state while refresh is active.

## Failure Semantics

Per-stack discovery errors and per-entry provider refresh errors are in-band
partial results. They do not fail the overall refresh:

- `stack_error` values appear in the existing Stack Errors section.
- `entry_error` values appear in Refresh failed.
- The final `summary` reconciles both collections.

A malformed event, unsupported schema, explicit fatal error event, nonzero
process exit, or missing final summary is a command-level failure. On such a
failure the store restores the last completed snapshot, if one existed, clears
progress, and shows the existing error banner. If no completed snapshot existed,
the content area remains empty beneath the error rather than claiming the inbox
is clear.

## Component Changes

- `GGInboxModels.swift`: event envelopes, event decoding, `refreshFailed`,
  optional URL, and refresh-error modeling.
- `GGService.swift`: `inboxStream(repoPath:)`, stream protocol validation, and
  removal of the Inbox dependency on atomic `--json`.
- `GGInboxStore.swift`: progressive generation state, progress, reduction,
  rollback, final reconciliation, and invalidation guards.
- `GGInboxTabView.swift`: minimum-version state, progressive header, Refresh
  failed presentation, optional PR link, and upgrade action.
- `GGInstallController.swift`: explicit Homebrew upgrade operation plus forced
  reprobe.
- Focused tests for each boundary above.

No project membership changes are expected unless implementation places the
event model in a new source file. If it does, `xcodegen` must regenerate and
commit the project file as required by the repository.

## Testing

### Event and Service Tests

- Decode every gg 0.9.12 Inbox JSONL event shape.
- Reject wrong versions, wrong commands, unknown events, and malformed payloads.
- Verify `gg inbox --jsonl` arguments and the project-root working directory.
- Prove lines are yielded before process completion with the incremental runner.
- Reject missing or duplicate `start`/`summary`, events after summary, explicit
  fatal errors, nonzero exits, malformed lines, and clean EOF without summary.

### Store Tests

- Retain the old snapshot through discovery and switch on the first candidate
  completion.
- Never mix stale and fresh generations.
- Insert successful and failed entries into the reported buckets immediately.
- Advance progress for included and excluded entries.
- Keep partial entries stably ordered despite out-of-order completions.
- Reconcile partial state with the final summary and timestamp only then.
- Restore the completed snapshot after fatal failure.
- Preserve invalidation-during-refresh and refresh-deduplication behavior.

### Version, Upgrade, and Presentation Tests

- Accept 0.9.12, later patch versions, 0.10.0, and later major versions.
- Reject 0.9.11, older versions, and unparseable versions for Inbox only.
- Keep the Inbox action discoverable while showing the upgrade-required state.
- Verify upgrade command success, failure, forced reprobe, retry, and automatic
  refresh after reaching a supported version.
- Verify progress-label formatting, Refresh failed bucket metadata, optional PR
  link behavior, and suppression of the clear-inbox state during partial refresh.

### Verification

Run focused Swift Testing cases while implementing. Before finishing the change,
run the repository-required verification:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Also run SwiftFormat lint on the changed Swift files before publication.

## Rollout and Compatibility

The feature intentionally raises only the Alas Inbox minimum to gg 0.9.12.
There is no migration or persisted-state change. Existing complete snapshots
remain usable as rollback state within the running app, but every new Inbox
refresh uses JSONL. Other gg integrations retain their existing availability
and capability behavior.
