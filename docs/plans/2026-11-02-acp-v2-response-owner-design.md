# ACP v2 current-request reconciliation and response owner

## Intent and scope

Continue #2213 after PR #2317, merged as `77a90b551fe5aa9bf4ece15a2c281f6ad14dc30f`. Compose the schema 34 response ledger with the existing stdio and broker exact-reply contracts. The caller supplies a chosen complete response. The owner binds it to an actual current request, commits intent and attempt, hands off exact bytes once, and retains the returned write fact.

Build this in AlasSessions with narrow attachment interfaces in AlasACP. Keep production selection v1-only. Do not add method-specific permission decisions, file/terminal execution, UI, automatic retry, response ACKs, or inbound consumption. No new schema is planned. Preserve unrelated Ghostty and adapter research changes.

## Attachment and current-request authority

One owner belongs to one local session, upstream session, inbound stream, lease fence and attachment epoch. Use a local invalidation token and the existing synchronous ownership-current predicate. Stop, cancellation and attachment/lease-owner invalidation withdraw authority. Replacing an attachment creates a new owner; it never silently retargets an existing one.

Stdio authority requires the original delivery actually captured by ACPStdioClient on the same connection. A public delivery initializer, historical ledger record or matching wire ID cannot manufacture authority. Keep the client's existing capture registry as the final arbiter. Retain the original live delivery alongside its exact committed inbound record, without invoking its consumption callback.

Broker authority requires an attachment-bound pending-set observation from the concrete raw transport, obtained from a successfully validated open/attach snapshot. Introduce a narrow immutable pending-view API owned by that transport. It carries connection, broker ID, generation, observed journal tail and exact pending entries with original cursor and request bytes. Arbitrary callers cannot construct a trusted production view. Refresh through the existing attach mechanism when explicitly reconciling; never infer the pending set by accumulating historical deliveries.

A retained broker origin matches only if broker ID, generation, pending key, origin cursor and request bytes match exactly. A new attachment connection may reconcile to the same persistent broker origin. A missing entry is unavailable at that observation, not proof of cancellation, execution or completion. Reused pending keys at another cursor are distinct. Invalid or conflicting snapshots withdraw eligibility. Matching a snapshot permits considering handoff, not a guarantee that the request remains pending: the helper's exact-origin check remains authoritative at write claim.

The public reconciliation result distinguishes eligible, unavailable/stale and observation-lost. Historical records remain inspectable in every case. Eligibility tokens are local to the owner epoch and cannot be persisted or exported as restored transport handles. Builder chooses type names and whether eligibility uses an internal reference or opaque token.

## Explicit response operation

The caller provides a retained origin, exact response bytes, intent UUID, attempt UUID and operation key. Reject mismatched source/session/stream, unsupported headers, changed bytes or invalid identities. Use exact UTF-8 comparisons for opaque identities. Stdio and broker reply validation stays in the existing contracts.

Sequence each operation as follows:

1. Reconcile the origin with this attachment and check current ownership/cancellation.
2. Register the immutable intent through the fenced persistence interface.
3. Recheck owner epoch and current ownership after the await. Register the explicit attempt.
4. After that commit receipt returns, recheck epoch, ownership, cancellation and request eligibility before calling the exact transport endpoint. A broker refresh here may itself await and requires another owner check afterward.
5. Pass the saved response bytes and operation key unchanged, with expected connection and exact source origin.
6. Validate and retain the typed returned fact under an explicit stable observation UUID. Report durable success only after that observation commit and a final owner check.

No transport call occurs before attempt COMMIT. An already-existing attempt receipt is not permission to send: only the operation that observed a newly inserted attempt in this owner may initiate its first handoff. Concurrent identical calls join the same local operation or read its known facts; conflicting calls fail. Gate by retained origin as well as caller UUID so different IDs cannot create competing local operations.

After restart, a known written attempt is historical written evidence. An unresolved attempt is uncertain and cannot be handed off by this owner. A recorded not-written attempt can permit an explicit new attempt/key, after fresh reconciliation. Do not automatically query/retry an unresolved transport operation in this slice; an endpoint called a query could initiate a write if its attempt cache was lost. A future read-only factual lookup requires its own contract.

## Loss, cancellation and facts

Cancellation before registration can reject without mutation. After attempt registration but before handoff, retain an uncertain local diagnostic when the same fence remains valid; never synthesize a typed not-written transport result. A registered attempt without saved terminal evidence remains uncertain, including this conservative pre-handoff window.

The first caller owns cancellation of its shared response operation, not of the entire owner. Cancelling that initiating caller withdraws this operation's permission to initiate handoff and settles its joined waiters conservatively. Cancelling a joined caller only detaches that waiter; it cannot cancel the shared attempt or mint a replacement. Owner stop or ownership/attachment invalidation withdraws all operations. A detached caller receives cancellation, not a fabricated write result. If initiation was already handed off, cancellation remains uncertain and later facts follow the retention rules below.

Cancellation or invalidation after handoff cannot retract bytes. Preserve uncertainty and prevent another handoff. The owner must settle its caller promptly on stop without waiting for blocked I/O. A worker may finish later; detach it from caller success publication and never let it write again. If the owner/fence remains valid, a late typed fact may be retained as historical evidence. If ownership is lost, do not bypass the fence to save it. Shutdown must not wait on that persistence or transport worker.

A transport error is diagnostic uncertainty unless the existing typed result supplies a factual terminal outcome. A broker rejection never becomes not-written. Failed outcome persistence is exposed separately from the returned transport fact: it is not a durable written receipt. No automatic new key, resend or fabricated outcome follows. The original registration remains the conservative recovery boundary.

The local owner checks do not create an atomic transaction across SQLite and an OS pipe. A separate process can seize a lease between a check and a physical write. State this limit explicitly; this slice guarantees fenced durable mutations and attachment/origin checks, not distributed exactly-once execution. Synchronous local invalidation must prevent handoff not yet initiated; already handed-off operations remain uncertain. Do not promise stronger ownership arbitration without a separately designed helper-level protocol.

## Integration boundaries

Add an injectable response persistence protocol over the existing intent/attempt/observation APIs and bounded recovery reads. ACPSessionPersistence conforms. Reuse the inbound owner style for lifecycle and latest-only status observations, while keeping reliable facts in the ledger. Do not add another consumer competing for an AsyncStream. The eventual caller supplies the actual delivery and its committed retention receipt through an explicit registration method; tests exercise this composition without installing a production runner.

The owner never acknowledges delivery consumption or resolves a helper pending request locally. Exact transport handoff owns helper resolution. Snapshot refresh may perform the transport's existing ACK flushing, but this feature must neither create consumption authority nor advance the acknowledged cursor itself. No changes to schema 34 certainty rules or parser qualification limits.

## Acceptance and verification

Use event-gated fakes and existing suite helpers, no fixed sleeps. Extend existing suites for transport changes; a new owner suite is appropriate for the new coordinator.

- Real captured stdio origins work; invented, copied-from-storage, foreign-connection and ambiguous/reused origins cannot redirect a reply.
- Broker reconciliation matches same-generation pending origins across reattachment; absent, resolved, reused, conflicting and changed-generation origins remain unavailable. A stale positive snapshot still cannot bypass helper origin checks.
- Persistence is observed before endpoint entry. Failed intent/attempt commits result in no handoff. An idempotent historical attempt cannot dispatch.
- Concurrent copies produce one attempt/handoff. Explicit new keys require a committed factual not-written outcome plus current reconciliation.
- Cancelling a joined waiter leaves the initiating operation running; cancelling the initiator disarms the shared operation. Neither action invalidates unrelated operations on the owner.
- Cancellation, stop and lease/attachment loss at each await settle promptly and prevent stale success. Late results cannot revive the owner.
- Write completion followed by observation failure reopens as uncertain. Errors and broker rejections never open the new-key gate.
- Exact frames and UTF-8 identities survive the full path. Inbound callbacks and durable ACK cursors do not change because a response was chosen or written.

Run affected package suites first, focused native suites when supported, SwiftFormat and whitespace checks. Check actual test counts. Keep source/fake, native, CI and live adapter/SSH evidence separate. Dependency-resolution failure before compilation is inconclusive.

## Delivery

My calls: package-level opt-in owner; transport-owned broker pending views; original stdio capture authority; insert-only first dispatch; no unresolved-attempt retries; conservative registration crash window; explicit cross-process lease limit. These keep the slice bounded while connecting durable decisions to real transport origins.

One fresh builder check reviews this design before approval. After full design approval, write the implementation plan and execute inline with TDD, one fresh final review and one combined material fix pass if needed, without rereview. Leave implementation uncommitted until shipping is requested. No product code or schema changes before approval.

## Builder check outcome

The fresh read-only check found one material ambiguity: which caller owns cancellation when identical calls join an operation. My call is initiating-caller ownership, independent joined-waiter cancellation, and owner-wide invalidation only for stop or attachment/ownership loss. This prevents a duplicate waiter from disarming another caller's answer. No other important questions remained. This clarification is part of the design presented for approval; no product changes or tests have been made.
