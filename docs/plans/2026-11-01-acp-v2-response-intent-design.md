# ACP 2 durable response intent

## Intent and scope

Continue umbrella #2213 after direct-stdio reply handoff merged in PR #2311 at `c9e04e0d7f2155f92fb73118bdc0e265c0bd03a0`, reviewed head `8b8a6c48561aea4502b2ea65ff39916e71761c06`. Work on `nacho/acp-v2-response-intent`. Preserve unrelated Ghostty and adapter research changes.

Both transports can now answer an actual source request using explicit exact response bytes and an operation key. The next missing boundary is durable intent: a future response owner needs to commit the selected answer and attempt identity before calling either transport, and retain write observations without treating a restart as permission to send again.

Build the local storage foundation in AlasSessions, using the existing session store, persistence actor, lease fence and inbound ledger. This slice adds no active response owner, transport calls, request-liveness map, semantic authorization, permission/file/terminal execution, UI or production runner changes. Production remains v1-only. Current-request reconciliation and the owner that composes registration, handoff and outcome persistence follow this slice. A committed intent or historical request is never current reply authority.

## Chosen answer and source identity

An intent is an immutable chosen response for one already-retained inbound ledger record. Register it with an explicit UUID, the exact stored stream/record descriptor and exact complete response body bytes. It carries the session, upstream session and raw-v2 source attribution inherited from that record. No lookup by wire ID alone.

Validate the supplied record against the stored inbound record in the same lease-fenced transaction. Decode only the common request header; require a supported request ID and a valid method envelope. Notifications, update/response/diagnostic records without a request ID, malformed headers and broker records without a pending-request key cannot be response targets. Header validity grants no method-specific permission. Validate the response using the existing ACPRawReply contract, require its ID to match the request's interpreted numeric ID or exact UTF-8 string ID, and retain the supplied response bytes as a BLOB without re-encoding.

The origin is `(inbound stream UUID, retained ordinal)`. For stdio this inherits the original connection and receipt. For broker it inherits broker ID, generation, original cursor and exact optional pending key. A broker redelivery already deduplicates onto that stored record; changing the live capture UUID or journal/pending-snapshot provenance cannot allocate another intent. Reused pending keys or wire IDs at another cursor/receipt remain separate origins. A second intent UUID or changed answer for the same origin conflicts, even after a failed attempt. An identical registration is idempotent.

This is persistence validation, not a current-origin check. A still-valid local lease and broker descriptor permit recording an intent against historical retained evidence; only a later attachment-bound response owner can establish whether that origin is currently answerable. Do not add an API that turns a loaded record into a transport handle.

## Attempts and the pre-handoff boundary

Separate one immutable chosen answer from its explicit transport attempts. An attempt has a UUID, parent intent UUID, positive per-intent sequence and explicit nonempty operation key. Its source binding derives from the intent. Stdio binds the original connection and receipt; broker binds broker ID/generation/pending key/origin cursor. Broker attachment connection UUIDs are observations, not a substitute for the persistent source binding.

Register the intent first, then register an attempt in a separate fenced transaction. Return a registration receipt only after COMMIT. The future owner must obtain that receipt before any transport handoff. Neither API writes or schedules bytes. An attempt registration means handoff may occur, not that it did occur. A crash immediately after registration is indistinguishable from a crash after a write but before its outcome was saved; recovery therefore reports unresolved/uncertain, never definitely unsent or safe to resend.

An operation key is unique within its transport source namespace: stdio connection, or broker ID plus generation. Compare keys as exact UTF-8. Reusing a key with another intent/attempt conflicts. Identical attempt registration is idempotent and cannot advance sequence or create another writer. Store the chosen response once on the intent; every attempt uses those same bytes.

Allow at most one unresolved attempt for an intent. A new explicit key/attempt is allowed only after the previous attempt has a committed factual `notWritten` result, which the stdio transport supplies. Never infer this fact from a generic error, broker rejection, cancellation, absent outcome, queued/in-flight observation, EOF, lease loss or process restart. Broker currently has no factual `notWritten` result, so its uncertain/rejected attempt cannot be replaced through this API. This preserves the existing stdio explicit-new-key behavior without inventing a broker retry guarantee. There is no automatic retry.

## Retained observations and recovery meaning

Append source-bound observations under an explicit observation UUID and positive per-attempt sequence. An observation is immutable; identical UUID/payload is idempotent, changed reuse conflicts. Retain exact typed local facts rather than synthesizing JSON-RPC response frames.

Accept the existing typed stdio reply result and broker reply result, validating all available identity fields against the attempt and intent. Stdio must match connection, receipt, exact request ID and operation key. Broker must match broker ID, generation, exact pending key, cursor and operation key. Neither result proves adapter receipt, execution or semantic authorization. A separately attributed uncertain/error observation may retain the caller's local failure and bounded diagnostic text; it never becomes `notWritten` or `written`.

Keep observation history because caller cancellation can return uncertainty before a later same-key query yields the actual write result. `queued` and `inFlight` are snapshots, not terminal failures. `writeUncertain` can later be refined by factual `written` or `notWritten` evidence where the underlying contract permits it. Older queued/in-flight observations cannot erase a terminal fact. Identical terminal observations are harmless; contradictory `written` versus `notWritten` facts conflict and leave storage unchanged. Do not use last-write-wins for certainty.

Expose a conservative recovery view: intent only, registered attempt with no terminal fact, known written, or known not-written. Unresolved attempts remain uncertain after reopen, including those last seen queued/in-flight. Written remains a local transport fact. Not-written describes that attempt only and does not prove the request is still current. Loading any of these values grants no lease, ACK, current attachment or resend authority.

## Storage, authority and compatibility

Add schema34 with dedicated intent, attempt and observation tables referencing the existing inbound stream/ordinal and cascading with session deletion. Preserve all v1 tables, update/submission/inbound journals, broker cursors and existing session values. Migration creates empty tables and synthesizes no historical decisions or outcomes. Table layout and public type names are builder choices; the invariants here are binding.

All mutations run through ACPSessionStore.withLeaseFence and are forwarded by ACPSessionPersistence. Validate session identity, the stored immutable stream/record, current broker raw-v2 descriptor/generation and exact relevant text before mutation. Stdio attribution stays bound to its recorded connection. A changed generation, malformed wire context, stale lease, incompatible record or transaction failure returns no successful receipt and changes nothing. Do not update broker ACKs or invoke consumption callbacks.

Use strict UTF-8, preserving BOM, embedded NUL and distinct Unicode spellings. Never use linguistic String equality for opaque source/session/upstream/pending/key identity or a repairing SQLite String projection to validate identity. Reuse the inbound ledger's raw-byte validation pattern locally; do not broaden the shared SQLite decoder. Validate integer ranges, BLOB/text types, supported format versions and redundant attribution on reads as well as writes. The existing shared opaque-object parser and broker signed-zero differences remain tracked qualification work.

Historical reads require no live writer lease or current broker descriptor. Discover intents by inbound stream and load one intent/attempt by explicit ID. Provide bounded snapshot pages for intents, attempts and observations, with context-bound continuations, default128/max1000 records and a default1MiB byte budget. Never return unbounded nested history. One oversized record may be returned alone with an explicit marker so traversal progresses; no payload truncation. End means local end at that read snapshot. Unsupported/corrupt rows fail explicitly rather than disappear or acquire guessed defaults. Length-first selection must bound BLOB loading, following the inbound recovery pattern.

## Acceptance and verification

Extend the existing store CRUD/schema/persistence suites before creating sibling suites. Use meaningful parameterized variants rather than parallel copies of scenarios.

- Migration preserves v1/session and existing journals and starts with no intents/attempts/outcomes.
- Real retained stdio and broker request records bind exact chosen response bytes. Notifications, malformed headers, mismatched IDs, absent broker pending identity and invented/changed records cannot register an intent.
- Same origin cannot acquire another decision; copied/reopened registration and concurrent identical registrations remain idempotent. Broker snapshot redelivery maps to the original retained record, while reused IDs at a distinct origin stay separate.
- Attempts bind exact keys within the correct source namespace. A second unresolved attempt conflicts. Only a committed factual stdio not-written result permits an explicit new-key attempt; generic rejection/uncertainty and reopen never do.
- Typed result mismatches and contradictory terminal facts roll back. Uncertainty can retain later factual refinement without regression from stale queued/in-flight snapshots. Copied observations do not allocate another sequence.
- Lease/source/generation/descriptor failures and injected SQLite aborts cannot produce a commit receipt, advance ACKs or invoke consumption. Concurrent actor calls preserve unique decisions and sequence order.
- Reopening, bounded pages, oversized records, strict malformed metadata, exact UTF-8 identities and empty/nonempty histories preserve facts without reconstructing reply authority.

Run the affected package tests first, inspect actual counts, then the existing app-owned store suites if the native environment permits. Exact-source temporary import-adjusted package checks may supplement a native cache failure but must be removed. Report native failures as inconclusive. Run SwiftFormat and whitespace checks. No live adapter/SSH or production claim.

## Delivery and calls made

My calls: keep this PR to the durable store instead of coupling a new response owner and liveness reconciliation to a schema change; persist a fixed chosen answer separately from explicit attempts; preserve a conservative crash window; and require factual not-written evidence before another key. These trade extra tables and later owner integration for a reviewable storage boundary.

One fresh builder check reviews the design before approval. After full design approval, write the implementation plan and execute inline with test-first regressions, one fresh final whole-change review and one material fix pass if needed, without another execution menu or rereview. Leave product work uncommitted until shipping is requested. No product code or schema changes precede approval.

## Builder check outcome

One fresh read-only builder check returned "nothing important left" after examining the durable registration crash window, not-written replacement gate, broker reattachment identity and late/contradictory observations. No product code, tests or schema changed during design.
