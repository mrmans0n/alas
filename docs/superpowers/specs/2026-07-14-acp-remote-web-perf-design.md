# ACP Remote Web: Incremental Transcript Delivery & Fast Stop

**Date:** 2026-07-14
**Status:** Approved

## Problem

Long ACP sessions make the remote web client nearly unusable:

1. **Slow transcript population.** Opening a session sends the entire
   transcript history as one `transcriptSnapshot`. Worse, every "delta" is a
   full re-snapshot: `RemoteSessionGateway.sendDelta` re-serializes the whole
   `session.transcript.messages` array on every 80 ms coalesce tick during
   streaming, on the MainActor, per connected browser, with a SQLite read per
   truncated tool call inside the loop. The browser then discards its message
   map, clears the DOM (`innerHTML = ""`), and re-markdown-renders every
   message on each delta.
2. **Stop takes minutes.** Client messages on a connection are processed
   strictly serially (`RemoteConnection.processingTail`). The web Stop button
   first sends a `takeOver` (writer-lease seize + forced full snapshot) and
   then `stop`, so the cancel queues behind full-transcript encodes on a
   saturated MainActor. The server stop path adds two more lease loads before
   the ACP `session/cancel` is sent.

The recent native fix (#771, "Bound ACP transcript restore window") bounds
only the SwiftUI render window; the web wire still serializes the full array.

Both symptoms share one root cause: the wire protocol has no incremental
delivery, no pagination, and no prioritization — everything is a full replay
serialized on the MainActor.

## Decisions

- **Full incremental protocol redesign.** Web assets and the Swift server
  ship together in the app build; no external wire compatibility to preserve.
- **Initial load = tail window + lazy backfill** on scroll-up, mirroring the
  native transcript's bounded window.
- **Fast-lane control messages** on the existing socket (no second
  WebSocket).
- **Stop bypasses the writer lease.** Cancel is a safe, idempotent emergency
  brake available to any authenticated subscriber; prompting still requires
  the lease.

## Section 1: Wire protocol

The `RemoteServerMessage` transcript vocabulary moves from
"snapshot + full-resnapshot-as-delta" to a versioned incremental model:

- **`transcriptSnapshot`** — carries only a tail window (last ~90 messages,
  matching the native `maxVisibleRows`), plus `totalCount` and `firstIndex`
  so the client knows how much older history exists. Sent on subscribe and on
  resync.
- **`transcriptDelta`** — a true delta:
  `{ upserts: [changed messages], removals: [ids], revision: n }`. During
  streaming this is typically one message. The gateway tracks per-message
  dirty state instead of re-emitting everything.
- **`transcriptPage`** — response to a new client request
  **`fetchOlder(sessionId, beforeIndex, limit)`** for lazy backfill. Pages
  come from the in-memory transcript (already fully loaded in the session
  manager): pure serialization, no new persistence.
- **Revision counter + resync.** Each delta carries a monotonically
  increasing `revision`. On a detected gap the client re-subscribes and gets
  a fresh tail snapshot. Correctness strategy is always "resync the tail
  window", never "diff harder".
- **Epoch.** Snapshots (and pages) carry an `epoch` identifying the
  transcript generation. The gateway bumps it on wholesale transcript
  replacement; a client holding a stale epoch resyncs.

**Dirty tracking.** `ACPTranscript` messages get a cheap monotonic `version`
stamp bumped on mutation (chunk append, status change, …). The gateway keeps
`lastSentVersion` per message id and, on each 80 ms tick, emits only messages
with `version > lastSentVersion`. Tracking is by id, not position, so late
mutations to older messages (e.g. tool-call completion) are still caught.

**Tool-call content caching.** Full tool-call content
(`fullToolCallContent` → SQLite) is fetched once when a tool call is first
serialized, cached on the gateway, and only re-fetched if that message's
version bumps. No more per-tick disk reads.

## Section 2: Server-side execution

**Serialization off the MainActor.** The gateway (MainActor) collects dirty
ids and copies the corresponding `ACPMessage` values (value types), then
hands them to a background serialization task that performs JSON encoding and
frame writing. Per-tick MainActor work becomes O(dirty), not O(N), per
connection.

**Fast-lane control dispatch.** `RemoteConnection.dispatchMessage` splits
incoming client messages into two classes:

- **Control** (`stop`, `ping`): executed immediately on arrival, bypassing
  the serial queue. Idempotent; no ordering dependency on transcript work.
- **Ordered** (everything else — `subscribe`, `prompt`, `takeOver`,
  `fetchOlder`, …): keeps the existing serial `processingTail` chain, which
  protects prompt/lease ordering semantics.

**Stop bypasses the lease.** The gateway's `.stop` handler drops the writer
check. `AppState.stop` → `ACPSessionManager.interrupt` gains a path that
skips `confirmedWriterLease`, and `ACPSessionRunner.userCancel` skips
`hasConfirmedLeaseForSideEffect` for the cancel case. Client side, `app.js`
drops the `ensureWriter()` call before `stop` — the takeOver-forced snapshot
disappears from the critical path.

**Immediate UI ack.** On receiving `stop`, the server pushes a lightweight
`stopping` state update to all subscribers before the ACP round-trip
completes, so the web UI flips to "stopping…" instantly.

## Section 3: Web client

**Keyed incremental rendering.** The client keeps `Map(id → message)` and
`Map(id → DOM node)`. On `transcriptDelta`, only upserted messages get their
node re-rendered (single-message markdown render); new nodes insert at the
correct position; removals drop their nodes. Untouched messages keep their
DOM. On `transcriptSnapshot` (subscribe/resync) a full rebuild is fine — it
is a bounded tail window.

**Scroll-up backfill.** Near the top with `firstIndex > 0`, the client sends
`fetchOlder(beforeIndex, limit≈90)`, shows a loading indicator, prepends the
page, and preserves scroll position by anchoring to the previously-topmost
node. An in-flight flag prevents duplicate page requests.

**Stop UX.** Stop button sends `stop` immediately (no `ensureWriter`), flips
locally to "stopping…", and reconciles when the server's state update
arrives.

**Streaming tail behavior** (auto-follow at bottom) is unchanged, just
cheaper: only the streaming message's node updates per tick.

## Section 4: Error handling & edge cases

**Resync correctness.** The single fallback for any inconsistency is
re-subscribe → fresh tail snapshot:

- Revision gap detected by the client → re-subscribe.
- WebSocket reconnect → re-subscribe (existing behavior, now cheap).
- Removals ride in deltas; if a change can't be expressed cheaply as
  upserts+removals (wholesale transcript replacement, e.g. session restore),
  the gateway bumps an epoch and pushes a fresh tail snapshot instead.

**Backfill edges.** `fetchOlder` clamps `beforeIndex`/`limit` server-side.
If the transcript changed underneath (epoch mismatch), the response says so
and the client resyncs. Pages are positional but messages are keyed by id, so
overlap upserts harmlessly.

**Stop edges.** `stop` on an idle session is a no-op ack; duplicate stops are
idempotent. If the ACP `session/cancel` round-trip fails, the still-running
session state reaches the client and the button reverts from "stopping…".

## Testing

Swift Testing (`import Testing`), per repo convention:

- **Gateway:** dirty tracking emits only changed messages; tail-window
  snapshot bounds; `fetchOlder` paging math (clamping, epoch mismatch);
  tool-call content cached across deltas (single persistence hit).
- **Dispatch:** control messages execute while an ordered message is blocked
  in the serial queue.
- **Stop path:** stop reaches `interrupt` without a writer lease.
- **Web assets:** extend `RemoteWebAssetTests` where the JS surface is
  checkable; manual browser verification for scroll backfill and stopping UX.

## Key files

| File | Change |
| --- | --- |
| `Alas/Sources/Remote/Protocol/RemoteProtocol.swift` | New wire messages: windowed snapshot metadata, true deltas with revision, `fetchOlder`/`transcriptPage`, `stopping` state |
| `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift` | Dirty tracking, tail-window snapshot, paging, tool-call content cache, off-main serialization, lease-free stop |
| `Alas/Sources/Remote/Server/RemoteConnection.swift` | Control vs ordered message dispatch classes |
| `Alas/Sources/ACP/Session/ACPTranscript.swift` | Per-message monotonic version stamp |
| `Alas/Sources/ACP/Session/ACPSessionManager.swift` | Lease-free interrupt entry point |
| `Alas/Sources/ACP/Session/ACPSessionRunner.swift` | Skip lease check on cancel |
| `Alas/Sources/App/AppState.swift` | Route lease-free stop |
| `Alas/Resources/RemoteWeb/app.js` | Keyed DOM reconciliation, scroll backfill, leaseless stop with local "stopping…" state |
