# ACP Broker Durable-State Deduplication

## Problem

`ACPBrokerClient` polls an active broker every 50 milliseconds while a prompt is pending. Each poll calls `setSnapshot`, which currently invokes `onDurableStateChanged` even when the broker ID, generation, and acknowledged cursor are unchanged.

The callback persists the state and mutates observable session-manager storage. Repeated identical snapshots therefore cause unnecessary SQLite writes and full-window SwiftUI invalidations. A live profile shows the main thread spending 50-85% CPU rebuilding the view graph, including `RepoGroupView` and `WorktreeRowView`, while the broker state is unchanged.

## Design

`ACPBrokerClient` will retain the last `ACPBrokerDurableState` queued for `onDurableStateChanged`. Both `setSnapshot` and successful durable acknowledgement handling will continue updating internal state, but they will enqueue a callback only when the derived state differs from the last queued value.

The comparison belongs in `ACPBrokerClient`, where the durable state is assembled and the callback contract is owned. A single helper used by every durable-state producer will perform the comparison and queue insertion under `stateLock`. This prevents redundant work for every callback consumer without weakening persistence checks downstream.

Callback delivery will be drained serially in queue order after releasing `stateLock`. Only one drainer may run at a time. Producers that arrive while a callback is running append their changed state for that drainer, which prevents callback reordering without invoking external code under the broker state lock. Reentrant callbacks are therefore also safe.

The existing 50 millisecond polling cadence remains unchanged. Polling latency and the broker transport protocol are outside this focused fix.

## State Flow

1. A broker poll returns a snapshot.
2. A snapshot or successful acknowledgement updates generation, cursor, cached handshake results, operations, and turn state as applicable under `stateLock`.
3. It derives the current durable state.
4. If that state differs from the last queued state, it records the new value and appends it to an ordered delivery queue.
5. The producer that becomes the queue drainer invokes callbacks in insertion order after unlocking. Other producers only append while a drainer exists.
6. Identical snapshots perform no persistence or observable-manager mutation.

The first valid durable state is always delivered. Cursor or generation changes continue to be delivered immediately.

## Testing

Broker-client tests will verify that an adopted active turn continues polling through multiple identical attach snapshots while producing one durable-state callback. A later snapshot-driven cursor change must produce exactly one additional callback. A durable acknowledgement that advances the cursor must also produce exactly one callback, and the next snapshot at that cursor must not duplicate it. A focused concurrent-producer test will verify callback delivery order. Existing broker send, replay, and turn-state tests remain unchanged.

## Verification

Run the focused `ACPBrokerClientTests`, the full macOS test suite, and a macOS build. Then sample a live pending broker turn and confirm that identical polls no longer schedule persistence writes or repeated sidebar body evaluation.
