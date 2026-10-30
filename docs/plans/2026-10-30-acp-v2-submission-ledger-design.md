# ACP 2 durable submission ledger

## Intent and scope

Continue umbrella #2213 after merged raw RPC delivery PR #2265, merge `348e0595af36111148466730f5e1b04fadc40702`. The new branch is `nacho/acp-v2-submission-ledger`, based on main `077638c565dc859965d36368e0c3da999f382cc6`.

The update journal durably retains incoming session updates. RPC deliveries now expose their full original response and consumption handle. What is missing is durable association between a local optimistic user row, one specific prompt attempt, and its exact response. Without that association, a restart loses acceptance evidence even when transport bytes survive.

This chunk adds the persistence contract for submission registration, exact RPC outcome retention, and passive recovery. It does not dispatch prompts or install a second canonical state owner. The next orchestration chunk will reserve real transport identities before handoff and integrate this ledger with the ordered update owner. Registration APIs here require those identities explicitly; accepting invented IDs or claiming the existing send API already supplies a safe handoff would hide that outstanding work.

Production stays v1-only. No queue advancement, automatic resend, upstream resume, pending adapter-request recovery, permission answering, UI projection, SSH replication, helper changes, adapter publication or live v2 activation. The existing v1 runner and prompt hook-review retry behavior remain unchanged.

## Design choice

Use a separate submission ledger in AlasSessions, owned by the existing session SQLite store and persistence actor. Reuse the existing lease fence and raw RPC delivery contracts. Keep update ordinals and submission identities independent.

An in-memory-only submission owner would lose the evidence this chunk is intended to preserve. Adding submissions to the update journal would falsely impose update-stream ordering on independently returned RPC responses. A complete sender and pending-request recovery implementation would combine several different ownership contracts in one change. The separate ledger is the bounded next step.

This is my scope choice based on the repository's current interfaces. No product code is written until the full design is approved.

## Registration and identity

A registration contains a fresh caller-supplied submission UUID, local session ID, upstream session ID, optimistic local-row UUID, immutable raw-v2 context, and one transport binding:

- Direct stdio uses the actual connection UUID plus the actual signed-Int or string JSONRPC request ID reserved by that client.
- Broker uses broker ID, positive generation and an explicitly supplied operation key for one prompt attempt. The helper allocates its adapter request ID after handoff, so registration does not invent that ID. A validated first outcome pins it in retained evidence.

The method is fixed to `session/prompt`. Unsupported source kinds, snapshot-cache results and unbound diagnostics cannot become submission outcomes. Do not use text, response order, update ordinal, foreground generation or a broker ACK cursor as submission identity. Equal text in distinct local rows remains distinct.

The store allocates a positive per-local-session registration sequence usable as the canonical reducer's local Int request ID. Validate its range before conversion and fail on exhaustion. This local ID is not a wire ID. The registration keeps both domains explicit. Do not delete individual registrations or reuse their sequence in this chunk; session deletion is the lifecycle boundary.

Registration requires a matching current writer lease for the local session. For broker sources, validate the persisted broker ID/generation/raw-v2 context without treating mutable ACK as identity. Validate source IDs and integer bounds using existing broker/JSONRPC rules. For stdio, the connection UUID is the supplied attachment identity, not proof that an external process is alive.

Repeating the exact submission UUID and all fields is idempotent. Reusing a submission UUID with different fields fails. Two registrations cannot claim the same transport binding, or the same local row within the same source identity and upstream session. The same local row may have a later explicit attempt on another source; recovery returns both attempts and must not silently select the newer one as proof the older one failed.

Registration proves only that intent and correlation committed before a caller's future handoff. It never proves bytes were sent. An attempt without a retained outcome is uncertain on recovery, including a crash between registration and handoff. This conservative ambiguity prevents automatic redispatch; this slice adds no prepared/sent flag that pretends SQLite and transport enqueue are one transaction.

No prompt content is duplicated into this ledger. Existing message/queue storage remains its authority; these records are correlation and outcome evidence, not a replayable outbox.

## Exact outcome retention

Expose a lease-fenced store/actor method accepting a persisted registration and an ACPRawRPCDelivery. Revalidate the persisted registration and current broker descriptor in the same lease transaction. Validate connection identity for stdio, exact wire ID and method, or broker ID/generation/operation key/method and real positive event cursor. Broker outcomes may arrive through a new attachment connection UUID; preserve the original received UUID instead of making it part of broker attempt identity.

Store the complete frame as an exact BLOB, original delivery receipt UUID and connection UUID, typed source metadata, original broker event provenance and a bounded interpretation. Never rebuild source from ACPResponse.body, JSONRPCError or an acceptance object. Never parse and re-encode the stored frame.

Interpretation has four factual outcomes:

- No retained RPC outcome. Registration exists and insertion remains uncertain.
- A strictly valid success whose result decodes as ACPV2PromptAccepted. Retain the exact messageId and original result evidence as accepted insertion.
- A strictly valid RPC error. Retain the error and its exact opaque data as an RPC failure. It does not automatically establish that insertion never happened, and it does not call canonical reject or authorize retry.
- Bound evidence that cannot decode as a valid RPC response or valid acceptance. Retain bytes and an explicit uninterpretable outcome. Never turn malformed success into acceptance or discard it because projection failed.

Binding validation is separate from interpretation. A delivery whose source metadata is not bound to this registration is rejected without mutation. Once binding is established, malformed frame bytes remain useful evidence and may commit as uninterpretable. A frame that decodes a contradictory wire ID is retained as uninterpretable under its already-bound source metadata, never applied as acceptance. Reading the raw source and interpretation makes this discrepancy visible.

For stdio, the durable receipt identity is the delivery receipt UUID within its registration. For broker, it is broker ID/generation/event cursor, independent of connection UUID and delivery receipt UUID. An exact retry returns the original committed evidence, including original provenance. Equal payloads under different prompt bindings never deduplicate.

Each registration has at most one retained outcome in this chunk. A second delivery with different event identity, different frame bytes or contradictory binding is a typed conflict, leaves the original evidence unchanged and leaves the live handle unconsumed. This is intentionally not the existing helper's same-key hook-review retry protocol. A future sender must represent explicit retry attempts separately and must not reuse one ledger registration across them. Do not change helper retention or reinterpret the latest completion as authority for an older one.

Return a durable receipt only after the lease transaction commits, including duplicate success. Receipt construction remains module-internal. The receipt contains immutable data and wasInserted, never a callback. SQL failure, lease loss, descriptor replacement or a conflict cannot return a successful receipt or partially update acceptance.

The store never invokes consumption on success, duplicate, failure, read or replay. A later live owner must commit, recheck attachment ownership, apply the canonical decision, then explicitly consume its original handle. A retained record does not recreate that authority. No exactly-once remote delivery claim is made.

## Passive recovery and model integration boundary

Expose bounded latest-independent registration reads in increasing registration sequence for a supplied local/upstream session and source identity. Use a stream-scoped continuation validated against that same filter. Provide direct loading by submission UUID for callers with known registrations. Reads do not require a writer lease or current broker descriptor, because old generations and old stdio connections are historical evidence.

Use default limits of 128 records and 1 MiB of outcome frames, maximum 1000 records and Int32.max bytes. Inspect lengths before fetching BLOBs. Permit one oversized first outcome with an explicit flag so paging makes progress. Registration-only rows count toward record limits and have zero frame bytes. Return point-in-time local end-of-page information, not a complete upstream prefix claim.

Recovery values distinguish uncertainty, accepted insertion, RPC failure and uninterpretable evidence. Revalidate stored format, source metadata, numeric ranges and agreement between stored interpretation and the original frame. Unknown format or corrupt metadata fails explicitly without rewriting evidence. Do not silently reinterpret a stored acceptance differently after reopening.

No API mutates ACPV2SessionUpdateOwner.state in this slice. Tests can reconstruct a fresh ACPV2SessionState using loaded registration sequence/local-row correlation and accepted responses, combined with existing snapshot update replay. This demonstrates acceptance/echo reconciliation in both orders without creating another mutable owner. Foreground running/idle remains governed exclusively by state updates. Accepted insertion must never create a foreground completion, and an RPC failure must not erase accepted evidence from another attempt.

The next owner integration must restore applicable submissions before update replay and coordinate live registration/outcome calls on the same canonical owner. It must not revive old stdio callbacks, send an old prompt, or merge old broker generations into a new upstream session. This slice supplies data contracts, not that orchestration.

## Schema and lifecycle

Add schema version 32 with session-owned submission and outcome tables. Use foreign-key cascade on actual session deletion. Add uniqueness constraints for source-scoped request binding, submission identity, registration sequence and source-scoped optimistic row correlation. Keep broker UInt64 request IDs in a lossless representation rather than narrowing them to SQLite signed Int64. Broker generation/cursor still follow the existing positive Int64 persistence bounds.

Store a format version and explicit raw-v2 context so future or malformed records fail visibly. Keep the original registration immutable. Retain the first committed outcome and original provenance across duplicate retries and ACK changes.

Broker clear, broker replacement, ACK advancement, ordinary session upserts and archive operations do not remove historical submissions. V1 operations create no submission rows. These tables do not enter replica exports or existing message projections. No migration copies v1 prompt outcomes into v2 evidence.

All mutations run inside existing withLeaseFence transactions. Do not nest a second transaction under it. Passive multi-query reads may use a bounded SQLite snapshot as the update journal does. No migration, constraint or decode failure may clear stored broker/session state to obtain a fresh launch.

## Acceptance and validation

Extend existing store schema/CRUD and persistence suites. Add a dedicated suite only for genuinely new domain decision logic if needed. Use real SQLite transactions and synchronized in-memory fixtures. No fixed sleeps.

- Reopen retains exact whitespace, opaque numbers, malformed bytes and error data, as well as distinct equal-content prompt attempts and exact local-row associations.
- Reversed responses retain their exact stdio or broker operation association. Signed/string stdio IDs and full-width unsigned broker request IDs do not narrow each other.
- Duplicate copies converge on one outcome; broker redelivery with another connection/origin retains the first committed event. Conflicting source, response or receipt cannot overwrite it.
- Lost/stale lease, changed broker descriptor, wrong session, range violations and trigger-induced SQL failures leave no partial registration/outcome and return no durable receipt. Cursor advances do not change identity.
- Every persistence path leaves live consumption callbacks untouched. Loaded records contain no consumption handles.
- Registration-only recovery stays uncertain. Malformed acceptance remains retained/uninterpretable. Valid RPC error remains factual failure evidence, not automatic rejection, retry or completion.
- Accepted insertion plus user echo reconstructs the exact local row in both orders. Snapshot running/idle replay does not create foreground completion. Same text in another submission remains distinct.
- Bounded count/byte pages, oversized-first progress, foreign/invalid continuation, unknown formats and corrupt metadata fail or progress as specified without losing evidence.
- Migration preserves legacy sessions. Broker clear/replacement retains historical rows; actual session deletion cascades; normal v1 activity creates no ledger rows or replica exports.

Run focused AlasCore suites first and affected native store/persistence suites when feasible. Temporary source-identical app tests with only their import adjusted are permitted for rapid cycles and must be removed before native checks. Report actual selected counts. The existing unrelated Ghostty mismatch and native build limitation remain visible; do not repair dependency inputs as part of this chunk. Complete SwiftFormat and whitespace checks and one fresh final whole-change review.

## Delivery

Use the established approved inline method after design approval, meaningful TDD per task and one final review. Keep changes uncommitted until shipping is requested. Preserve unrelated adapter research and Ghostty changes. This design document is the only new work before approval; no tests, schema or product code have been edited.

## Builder check outcome

One fresh builder check returned "Nothing important left." The review specifically considered retention of source-bound contradictory raw evidence without false acceptance, and first-outcome identity across broker retries. No product code or tests were added during design. Sender handoff and canonical owner integration remain explicit follow-up work rather than implicit guarantees of the persistence API.
