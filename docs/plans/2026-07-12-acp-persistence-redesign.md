# ACP Persistence Redesign

## Problem

`ACPSessionManager`, `ACPSessionRunner`, and `AppState` are main-actor types,
but they call the synchronous `ACPSessionStore` directly. SQLite's five-second
busy timeout therefore turns ordinary cross-process writer contention into a
main-thread hang.

Lowering the main-thread timeout is not a complete fix. It changes a hang into
failed reads and writes, and transparent background replay cannot preserve the
domain ordering, lease ownership, and lifecycle semantics of ACP sessions.

## Invariants

1. Production main-actor code never opens SQLite, migrates a database, executes
   SQL, waits for a busy handler, or sleeps while retrying persistence.
2. A single off-main persistence service owns the writable SQLite connection
   for each worktree and serializes local mutations.
3. Persistence APIs are honest: success means the operation committed; failure
   does not schedule an invisible raw-SQL replay.
4. Retries, when needed, repeat one typed domain operation without allowing a
   newer mutation to commit ahead of an older retry.
5. Writer-owned mutations are fenced by the lease token in the same SQLite
   transaction as the mutation. A preflight lease read is not a commit fence.
   The only post-takeover exception is typed compare-and-swap salvage of
   buffered transcript payloads against a base captured under the old token;
   it cannot overwrite a row changed by the new owner.
6. Manager and runner UI state remains main-actor isolated. Database inputs are
   immutable Sendable values and database outputs are Sendable snapshots.
7. Session creation is durable before a runner can attach or child rows can be
   written. Parent/child ordering is explicit rather than recovered later.
8. Shutdown performs a bounded flush of the existing ordered pipeline. It does
   not create an unrelated fallback writer that can overtake queued work.
9. SQLiteKit remains domain-neutral. It must not parse ACP SQL, know table
   names, inspect binding positions, or evaluate session leases.

## Target Boundaries

### `SQLiteDatabase`

Generic synchronous SQLite primitive. It keeps the configurable busy timeout
for focused tests and non-UI callers, but contains no retry scheduler.

### `ACPSessionStore`

Typed synchronous SQL and transactions. It is only used from persistence
executors in production. Lease-fenced store methods validate the expected
owner and token inside `BEGIN IMMEDIATE` before changing owner-scoped state.

### `ACPSessionPersistence`

Off-main serialized service, created from a database path without opening the
database in its initializer. Its first awaited operation opens and migrates the
store. It exposes typed reads, mutations, hydration snapshots, and lease
commands. Manager and runner queues provide moving-tail flush barriers.

### `ACPSessionManager` and `ACPSessionRunner`

Main-actor state owners. They keep synchronous operations for in-memory UI
changes, but persistence is submitted to `ACPSessionPersistence`. Operations
whose result controls behavior, including creation, lease acquisition, and
takeover, are awaited.

## Migration Sequence

1. Add Sendable persistence value types and the lazy persistence service.
2. Make production manager construction I/O-free and load recents off-main.
3. Replace synchronous placeholder lookup with the manager's persisted-row
   cache, populated by recents and explicit async row loads.
4. Move manager mutations and draft flushing to the ordered service.
5. Remove the runner's direct store dependency and persist immutable snapshots.
6. Add lease tokens and move claim, heartbeat, release, and takeover off-main.
7. Fence runner and manager owner-scoped mutations transactionally.
8. Replace synchronous shutdown flushes with a bounded persistence barrier.
9. Remove all production direct store access from main-actor files.

## Verification

- Hold a competing `BEGIN IMMEDIATE` transaction and prove a main-actor
  heartbeat continues to execute while persistence waits.
- Verify FIFO ordering for session creation followed by draft, queue, and
  transcript writes.
- Verify a mutation queued under an old lease token cannot commit after
  takeover.
- Verify delete/archive cannot be undone by older pending work.
- Verify draft submit, clear, eviction, and shutdown preserve the latest intent.
- Verify migration/open failures produce an explicit manager error state rather
  than a main-thread stall or a permanently missing manager.
