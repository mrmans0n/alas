# Durable ACP 2 session-update receipt and replay

## Intent

Give Alas a durable local copy of the raw v2 `session/update` stream before installing a live v2 runner. A crash after receiving an update must not require reconstructing its contents from lossy message rows or assuming that a transport ACK proves model application.

This follows merged PR #2250 and umbrella #2213. The design branch is `nacho/acp-v2-update-journal`, based on main `e8323d19ca31c7e0c4085fa56e003f098ac86072`. The unrelated adapter research file remains outside this work.

## Bounded slice

The proposed scope is the existing `ACPV2SessionUpdateDelivery` stream: an additive SQLite journal, explicit durable receipt results, stable source identities, and paged raw replay. Preserve complete original frames, including identifiable updates whose decoding fails. Do not require successful interpretation before storing evidence.

RPC responses, prompt registration/acceptance, pending client requests and other diagnostic frames retain their existing transport owners. This slice does not claim a complete journal of all ACP traffic, reconstruction of pending submissions, a fully restorable user conversation, or permission to consume those other delivery types. Later runner work must supply their durable contracts before live v2 eligibility is enabled.

No v2 runner/UI activation, automatic queue advancement, upstream session resume, SSH replication, adapter changes, publication, automatic compaction or v1-to-v2 conversion. Production selection remains v1-only with the Debug flag either off or on.

## Raw authority and stream scope

Use the existing session database and an additive migration, using the next available version after 30 on the implementation base. Raw frame data is a BLOB; never parse/re-encode JSON as the storage representation. Whitespace, numeric tokens, duplicate-key JSON, invalid UTF-8 and empty evidence remain exact bytes. The current SQLite binder already supports Data, but empty Data must be verified to remain a zero-length BLOB rather than SQL NULL; a focused SQLite correction is permitted if the regression proves it necessary.

A registered journal stream binds:

- Local Alas session ID and the upstream ACP session ID.
- Explicit v2/raw wire context and a stable journal stream identity.
- Either broker ID plus positive generation, or a direct-stdio connection UUID.
- An initial receipt baseline, so creating a journal after a nonzero broker ACK cannot imply that older traffic is locally available.

Broker stream registration and append validate the persisted raw-v2 broker descriptor from #2250. The active journal cannot install or replace that descriptor, bypass the manager's v1-only restore policy, or change the session's ACK cursor. A changed broker generation is another stream; retained old streams remain historical evidence. Direct-stdio streams have no broker identity and must not manufacture one or interpret the broker-context column as a stdio protocol selection.

Local Alas and upstream ACP session IDs are nonempty opaque strings. Reuse the existing broker-ID validation for broker namespaces, without imposing that filesystem-oriented character restriction on upstream session IDs.

Reject contradictory stream registration, incompatible context, invalid IDs, nonpositive generations, negative ordinals/cursors and values outside SQLite's supported integer range. Do not clamp values or resolve malformed descriptors as v1. Loading unknown stored journal formats must fail explicitly while leaving their bytes untouched.

## Receipt identity and ordering

Broker event identity is journal stream plus broker cursor. A reconnect's new connection UUID and a different delivery origin do not make the same broker event a second update. Keep original broker provenance as metadata; `journal` versus `pendingSnapshot` is not an identity discriminator.

Direct stdio has no broker cursor. Give every newly constructed `ACPV2SessionUpdateDelivery` a stable receipt UUID which survives value copies and repeated persistence attempts. Distinct incoming deliveries receive distinct IDs, even when their bytes are equal. Do not deduplicate by JSON, text, bytes or a payload hash.

Assign a monotonic local journal ordinal only when inserting a new receipt. It records durable receive order and is the pagination key. An exact retry returns the existing durable receipt without another row or another append effect. The same source identity with different bytes, upstream session, context or other immutable source facts is a conflict and leaves storage unchanged. Connection UUID and observed transport origin may differ on a broker retry; they cannot replace the original evidence or create another append.

Expose ordered ingestion as a caller contract for this storage slice. The future stream owner must await one append at a time in delivery order. Do not claim concurrent arbitrary Task scheduling preserves transport order, and do not add a runner or a new asynchronous ingestion owner in this slice. Tests exercise controlled sequential ingestion plus concurrent retries of the same identity; ordinal allocation and uniqueness remain atomic in SQLite.

## Commit, receipt and acknowledgement

All journal mutations go through the existing persistence actor and a required current writer lease fence. Journal stream validation, immutable descriptor comparison, duplicate/conflict checks and insertion happen atomically inside the existing lease transaction.

For a broker append, read the current persisted row inside that transaction and match its broker ID, positive generation and effective raw-v2 wire context to the registered stream. The mutable acknowledged cursor is not part of that identity comparison. Do not require it to equal the registration-time cursor, and do not require callers to supply a fresh ACK expectation for each append. Validate the current descriptor's numeric/context shape using the existing policy, but ordinary ACK advancement cannot invalidate the stream. The initial baseline is captured only when creating a stream and never moves; reopening an existing stream returns its original baseline instead of replacing it with today's ACK cursor. Do not introduce nested BEGIN within `withLeaseFence`. A missing or replaced lease, mismatched descriptor or database failure cannot leave a partial record or produce a successful durable receipt.

An append returns an explicit durable receipt only after the transaction commits. It identifies the stream, original source identity and local ordinal. Its constructor is controlled by the persistence implementation; it is distinct from replayed journal rows.

Persisting, decoding, model application and replay must never invoke `acknowledgeDurableConsumption()` automatically. The receipt proves storage only. It does not carry or recreate a transport callback, grant ACK authority to a replay reader, or mean that the model saw the update. Future live owners can match this receipt to their still-current delivery and explicitly invoke the original single-use handle under their existing attachment/connection guards.

This boundary intentionally leaves ACK execution with the current delivery owner. Test fixtures demonstrate commit-before-explicit-ACK, no callback on failed/rolled-back writes, no callback from replay, and the crash windows before and after commit. An old owner that loses its lease cannot append; a receipt committed before detach remains stored, but never acknowledges on detach or replay. This slice does not claim to solve final runner callback ownership, helper ACK retries, or receipt-to-model checkpoint coordination.

The existing persisted broker acknowledged cursor continues to mean transport acknowledgement, updated through its existing durable-state callback. Local journal receipt is not that cursor and cannot advance it.

## Replay and completeness

Replay reads exact stored rows in local ordinal order for one explicit stream, with a continuation ordinal and bounded pages by count and bytes. Do not load the entire journal or silently truncate a frame. A single oversized record must either make one-record progress with an explicit oversized indication or return a typed size error; choose one documented policy during planning and pin it with a test.

Page metadata distinguishes end of the retained journal from completeness of the upstream conversation. A nonzero initial broker baseline is an explicit missing prefix. Never infer an upstream completion or an empty conversation from an empty page, an unavailable stream, a partial prefix or decode failure. Validate continuation ownership so one stream's cursor cannot be used as another's continuation.

Replay is passive. It cannot create deliveries with live consumption callbacks, send prompts, answer permissions, produce notifications, move a queue, update usage or declare a newly completed foreground turn. A fixture rebuilding known transcript/activity state uses the existing `ACPV2SessionState` with a fresh explicit replay context; historical foreground observations are supplied as `.snapshot`, not `.live`. Unknown updates remain available verbatim. Malformed known updates produce explicit replay interpretation failures rather than being discarded or silently claiming a complete canonical rebuild.

Production projection into message rows, optimistic correlation, checkpointing and binding a replay context to a new live runner remain separate work. This slice validates that stored ordered records are sufficient for known message/activity fixture reduction, not that all runner state can be reconstructed.

## Retention and lifecycle

Keep journal records after receipt/ACK, detach, broker generation replacement and explicit broker-tuple clear. These operations are not permission to erase conversation evidence. Actual local session deletion can cascade to its journal rows using the existing session lifecycle. Do not add journal tables to replica export or import in this slice.

No automatic pruning or compaction. The feature is not enabled in production yet; later retention policy must preserve unresolved request/submission evidence and checkpoint boundaries before journal data can be removed. Disk/SQLite limits surface as explicit persistence failures and cannot be converted into successful receipt or ACK.

## Validation

Use Swift Testing and the existing SQLite/store/persistence fixtures. Extend existing store and persistence suites for their new behavior; a new focused package suite is appropriate only for a new journal domain type rather than scenario-sliced store siblings.

- Migration from the current schema preserves existing sessions and v1 behavior; no journal changes on ordinary v1 paths.
- Exact bytes survive close/reopen and multiple bounded pages, including malformed/opaque JSON, huge numeric tokens, invalid UTF-8, empty Data and equal consecutive chunks.
- Broker duplicate delivery across new connection IDs returns one original receipt. Changed bytes under the same source identity conflict atomically. New generations stay distinct.
- Copies of one stdio delivery retry idempotently; separately received equal-byte chunks both persist and both replay.
- Lease replacement, changed persisted context/generation, failed transaction and out-of-range metadata leave the journal and ACK cursor unchanged.
- Commit/retry across simulated crash boundaries retains exactly one record. Replay cannot mint or invoke acknowledgement handles; explicit live consumption remains single-use.
- Paged replay preserves continuation ownership, explicit missing-prefix information and the chosen oversized-record policy. Unknown stored formats fail without deletion.
- Ordered replay through known v2 transcript/activity fixtures matches live reduction facts, while replayed state snapshots cannot complete foreground work or advance a queue.
- Run affected package tests first, then focused native store/schema/persistence suites as required. Inspect actual selected counts. Full SwiftFormat and whitespace checks complete the slice; CI and live v2 interoperability are separate evidence.

## Builder choices

My recommendation is to keep journal domain values in AlasACP and SQLite operations in the existing AlasSessions store/persistence boundary. Public type/API names, table/index layout, exact page size defaults and whether stream registration needs one or two tables are implementation choices. Preserve the contracts above; do not add a second database, replace session ownership, or broaden production eligibility.

The scope, strict evidence preservation, required fence, caller-owned ACK and excluded runner work were approved in conversation before implementation. Public API details remain the builder choices described above.

## Builder check outcome

One fresh builder check asked whether append compares the mutable ACK cursor. The existing descriptor/ACK separation answers this without a user decision: append compares current persisted ID/generation/context inside the lease transaction, while ACK remains mutable and the journal baseline stays fixed. The clarification above is my design call and must be covered by an append-after-ACK regression. No product code, test run or commit was made in this design phase.
