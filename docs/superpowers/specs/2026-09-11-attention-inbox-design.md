# Attention inbox and persistent event history

**Issue:** #1160  
**Date:** 2026-09-11  
**Status:** Approved in conversation

## Goal

Alas should tell the user which events still need action without changing the existing project and worktree tree into a filtered navigation mode. A badged warning button in the sidebar toolbar opens a center-pane attention inbox. The inbox lists current attention items and addressed history, with direct navigation to the relevant session, conflict, script failure, review request, or remote worktree.

The badge counts attention items, not worktrees. Several items may belong to one worktree.

## Product behavior

### Entry point and inbox

The sidebar header gains a warning button between Search and Settings. The button is always available. Its badge shows the number of unresolved attention items and disappears at zero.

Selecting the button opens `AttentionInboxView` in the center pane. The worktree tree remains visible and unchanged. Closing the inbox restores the center destination that was visible before the inbox opened.

The inbox has two chronological sections:

- **Needs attention** contains unresolved items, newest first.
- **History** contains addressed and informational events, newest first.

Each unresolved row shows a reason, project and worktree attribution, occurrence time, and one jump action. Addressed rows also show when the user addressed them. The inbox does not add bulk dismissal or muting in this version.

Project rows show an unresolved-item count for their project. Worktree rows do not gain another permanent status treatment; existing agent badges and operation status remain intact.

### Attention signals

Each occurrence below creates one independently addressable item:

| Signal | Active wording | Jump target | Acknowledgment interaction |
|---|---|---|---|
| Agent awaiting input | `<Agent> is waiting for input` | Exact terminal leaf or ACP session | The exact session receives focus |
| Agent permission request | `<Agent> needs permission` | Exact terminal leaf or ACP session | The exact session receives focus |
| Run script failure | `<Script> failed with exit code <code>` | Existing failure details | Failure details open successfully |
| Merge, rebase, or cherry-pick | `<Operation> is in progress` | Changes pane operation section | The section becomes visible |
| Unresolved conflicts | `<count> unresolved conflict(s)` | Changes pane conflicts section or first conflict | The conflicts section or first conflict opens |
| Agent review reply | `<Agent> replied to review feedback` | Exact review session and comment | The comment receives focus |
| Failed review checks | `CI failed` | Matching review request in Changes | Review readiness becomes visible |
| Actionable review feedback | `Review feedback needs action` | Matching review request in Changes | Review readiness becomes visible |
| Review sync blockage | `Remote branch diverged` or `Remote branch is ahead` | Matching review request in Changes | Review readiness becomes visible |
| SSH host disconnected | `<host> is unreachable` | Remote worktree | The remote worktree is selected and its disconnected state is visible |

Unpushed commits, a branch merely behind its base, pending checks, running agents, and successful scripts do not need attention. They may already have existing status UI, but they do not add inbox items.

Agent-finished events are written to history for “what happened while I was away” but never increase the badge.

### Clearing and recurrence

Opening the inbox does not acknowledge anything. A jump acknowledges an item only after Alas resolves and focuses the intended destination. If the destination no longer exists, Alas selects the owning worktree where possible, leaves the item unresolved, and shows the navigation failure in the row.

Acknowledgment applies to one occurrence, not every future occurrence of that signal. Refreshing unchanged state cannot recreate or unacknowledge it. The source must first become inactive and then active again, or produce a new source-specific occurrence such as a different permission request or review reply, before Alas creates another item.

When live state disappears before the user opens it, the unresolved event remains in the inbox with historical wording such as `Codex waited for input at 14:32`. It records that the event still has not been reviewed without claiming that the agent remains blocked. This is the only fallback supplied by history; live state remains authoritative for present-tense status.

## Architecture

### `AttentionStore`

`AttentionStore` is an observable, main-actor service owned by `AppState`. It owns persistence and exposes immutable event history plus acknowledgment records. It does not mutate or replace any producer state.

The persisted document has a schema version and four bounded collections:

- `events`: immutable `AttentionEvent` values in occurrence order.
- `acknowledgments`: `AttentionAcknowledgment` values keyed by event ID.
- `observations`: the last active or inactive observation for each source key, including the current occurrence ID when active.
- `aliases`: legacy owner identities mapped to their lineage-based identity.

An observation is transition bookkeeping. Consumers must not use it to render current agent, Git, review, script, or SSH state. Its purpose is to deduplicate refreshes and to prevent an acknowledged active occurrence from returning after relaunch.

The store API is intentionally narrow:

```swift
func observe(_ observation: AttentionObservation, at date: Date)
func acknowledge(eventID: UUID, at date: Date)
func appendHistory(_ event: AttentionHistoryEvent)
var events: [AttentionEvent] { get }
var acknowledgments: [UUID: AttentionAcknowledgment] { get }
```

`AttentionObservation` contains the source key, active state, optional active fingerprint, event payload, and owner identity. `observe` compares it with the persisted observation. It appends only on an inactive-to-active transition or a changed active fingerprint. An inactive observation closes the transition but does not delete its event.

### `AttentionSignalAggregator`

`AttentionSignalAggregator` builds display items from two inputs:

1. Current snapshots from existing state owners.
2. Unacknowledged persisted events whose live source has disappeared.

Current snapshots decide present-tense state and wording. Persisted events provide the first-seen time, acknowledgment status, and historical fallback. The aggregator has no setters for producer state and cannot make an agent “awaiting,” create a conflict, or change review readiness.

The aggregator returns stable `AttentionItem` values containing:

- event ID and source key;
- stable owner identity;
- kind, title, timestamp, and live-versus-historical presentation;
- source-specific jump target;
- project and current worktree display attribution when resolvable.

### Producers

Small transition adapters call `AttentionStore.observe` where the app already receives authoritative changes:

- `HarnessService` for awaiting, permission, and finished transitions;
- run-script completion handling in `AppState+RunScripts`;
- `RightPaneState` refresh completion for Git operations, conflicts, and sync state;
- `ReviewLoopState` refresh completion for checks and actionable feedback;
- review draft comment change handling for agent replies;
- `RemoteHostStatusStore` online and offline transitions.

Adapters translate state but do not contain inbox presentation logic. Repeated refreshes pass the same source fingerprint and therefore do not append duplicate events.

### Presentation and navigation

`AttentionInboxView` receives items and callbacks. It does not reach into global singleton state.

`AppState` owns inbox presentation and jump routing. Routing reuses existing selection methods:

- `activateHarnessSession` for exact terminal or ACP sessions, including multiple matching sessions;
- run-script failure presentation for script failures;
- worktree selection plus `RightPaneState` conflict and operation navigation;
- review-loop or review-session navigation for review items;
- global worktree selection for local and SSH worktrees.

Each route returns success or failure. `AppState` acknowledges only successful routes.

## Stable attribution

`Worktree.id` derives from the absolute path, so it cannot be the durable event owner. `AttentionWorktreeIdentity` uses:

1. project ID;
2. normalized execution location, local or SSH destination;
3. worktree `lineageID` when present.

This identity survives branch changes and worktree path renames. Events keep a snapshot of the project name, branch, path, and host for history display, but lookup uses the stable identity.

Legacy or synthetic worktrees without a lineage ID use project ID, execution location, and canonical path. When Alas later observes a lineage ID for the same worktree, the store records an alias and rewrites lookup through the lineage identity without rewriting old events. Equal remote paths on different SSH hosts remain distinct.

If a worktree no longer exists, the event remains browsable under its snapshot attribution. Its jump action is unavailable and explains that the worktree is no longer present.

## Persistence and retention

The store writes `attention-events.json` under `Paths.appSupportRoot` through `PersistenceStore`, using atomic replacement and ISO-8601 dates. Data stays local and is never added to project repositories, sync payloads, remote protocols, or notifications.

Retention runs after each append and acknowledgment:

1. Remove addressed events older than 30 days, with their acknowledgments and unused observations.
2. If more than 2,000 events remain, remove the oldest addressed events.
3. If the document still exceeds 2,000 events, remove the oldest unresolved events to enforce the hard bound.

The UI does not imply that the 2,000-event cap is an archive guarantee.

If decoding fails, `PersistenceStore` moves the document to its existing `.broken-<timestamp>` form. `AttentionStore` enters a load-error state and does not synthesize already-active snapshots as fresh transitions during that launch. The inbox shows one non-dismissible `Attention history could not be loaded` row. New transitions that happen after startup may be recorded in a fresh document. This avoids turning unknown old state into new attention.

Writes are best effort from the producer’s perspective: a persistence error must not interrupt agent events, Git refresh, review refresh, script completion, or SSH status updates. The inbox shows the store error until a later write succeeds.

## Review-reply semantics

A review draft comment needs attention when its newest reply is authored by an agent and is newer than both the newest user reply and the latest acknowledgment for that comment. The source key uses review session ID plus comment ID. The fingerprint uses the reply ID, so a later agent reply creates a new occurrence even if an earlier reply was acknowledged.

Provider review threads continue to use `ReviewRequest.hasActionableFeedback` for review readiness. This design does not infer “unanswered” provider conversation state from author names.

## Accessibility and empty state

The warning button’s accessibility label includes the unresolved count, for example `Open attention inbox, 4 items`. The badge is not the only indication of state.

Rows expose the reason, attribution, timestamp, and action as one accessibility group. Relative timestamps have absolute-date help text. At zero unresolved items, the inbox says `Nothing needs attention` and still shows retained history.

## Test strategy

Tests use Swift Testing. Production clocks and persistence URLs are injected where time or relaunch behavior matters.

### Model and persistence tests

- Aggregate every supported signal with a reason and timestamp.
- Keep multiple simultaneous sessions as separate items.
- Count attention items globally and per project.
- Prefer live presentation and fall back to historical presentation after live state disappears.
- Acknowledge only the selected occurrence.
- Suppress an acknowledged occurrence across refresh and relaunch.
- Create a new item after an inactive-to-active transition or changed fingerprint.
- Preserve attribution across branch changes and path renames through lineage ID.
- Separate equal paths on different SSH hosts.
- Round-trip events, acknowledgments, observations, and aliases through disk persistence.
- Apply 30-day pruning and the 2,000-event hard cap.
- Fail closed on an unreadable document without resurrecting startup state.

### Integration and routing tests

- Record harness awaiting, permission, and finished transitions.
- Record local and remote run-script failures.
- Record Git operations, conflicts, review readiness, agent review replies, and SSH disconnection transitions without refresh duplicates.
- Focus the exact matching terminal leaf or ACP tab when several sessions are active.
- Route conflicts, script failures, review items, and disconnected hosts to their existing destinations.
- Acknowledge after successful focus and retain attention after failed focus.

### UI tests

- Render the header button with zero and nonzero counts and verify its accessibility label.
- Render every inbox row with reason, attribution, timestamp, and jump action.
- Verify active and addressed history sections and the empty state.
- Extend the existing sidebar hosting coverage so the new project count and toolbar button do not regress row or header layout.

## Verification

Run focused attention-store, aggregator, routing, and UI tests during development. Before completion, run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
git diff --check
```

## Out of scope

- Push notifications beyond the existing macOS notification behavior.
- Phone-client or remote-protocol inbox synchronization.
- Per-event mute rules.
- Cross-project digests or summaries.
- Bulk acknowledgment.
- Configurable retention.
- Changes to the existing worktree text filter proposed in #1164. That work should consume `AttentionSignalAggregator` rather than define another signal set.
