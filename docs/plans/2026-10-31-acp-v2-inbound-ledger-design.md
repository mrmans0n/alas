# ACP 2 passive inbound receipt ledger

## Intent and scope

Continue umbrella #2213 after raw inbound delivery merged in PR #2281 at `07cede457fb3cae5df571e3c2bbb2495a1c695a2`. Start branch `nacho/acp-v2-inbound-ledger` from current main `cf9aa29df52bcf77e2f13ca98657aebe8c7c221f`, preserving unrelated Ghostty and adapter research inputs.

The merged common inbound delivery preserves exact method evidence but has no durable owner. Before a future request owner can consume a live receipt, it needs a committed local record that survives database reopen. This slice provides that passive storage and bounded historical discovery. It does not install a receiver loop or consume receipts itself.

Production supported versions remain v1-only. Exclude response intent/storage/dispatch, request resolution, permission decisions, filesystem/terminal execution, UI, queue/lifecycle changes, runner activation, upstream resume, SSH replication, helper changes and compaction. In particular, do not turn a stored request into permission to answer it. The earlier outline's response-intent and uncertain-delivery states belong to the subsequent response-owner work; this ledger records received evidence only.

Use the existing Swift/SQLite session store and persistence actor. These are implementation choices based on the merged journal and submission ledger, rather than new user requirements. No new database or generic persistence framework is needed.

## Evidence and source ownership

Add a journal domain in AlasSessions, keeping successful durable-receipt construction internal to that module. Reuse the public common delivery from AlasACP; do not move transport callback ownership into persistence.

An immutable stream descriptor holds a generated UUID, local session ID, caller-assigned upstream session ID, source identity, format version/raw-v2 context and optional fixed initial broker ACK baseline. Source identity is either a stdio connection UUID or broker ID plus positive generation. Mutable ACK is not part of stream identity. The stream is a historical descriptor, never an active attachment or ACK handle.

One source belongs to one inbound stream across local sessions and upstream IDs. Registration reopens an identical mapping; attempting to bind the same connection or broker generation to another local/upstream context is a typed conflict. This global source uniqueness is my choice to prevent two local owners independently claiming one source's inbound history. It applies to this inbound ledger only, not other journal domains. A genuine source replacement creates a new connection/generation and stream. Actual session deletion removes its retained mapping.

The caller supplies session attribution. The ledger does not guess session ownership from arbitrary method params or interpret the upstream ID as proof that every method is session-scoped. Connection-level notifications and opaque params remain evidence in the chosen context. Installing routing for traffic before a local/upstream session context exists is outside this slice.

## Durable retention

Expose store methods and matching public persistence-actor methods for registration, retaining a common inbound delivery, bounded stream discovery and bounded record pages. Use names consistent with the existing journal; the implementation plan may settle exact names without changing semantics.

Registration and retention require an exact matching current writer lease for the local session. Use the existing `withLeaseFence` transaction, with no nested BEGIN. Broker writes also validate the current session row's broker ID, generation and raw-v2 context, excluding ACK from identity. A stale lease, wrong session fence, descriptor replacement, opaque/legacy context, invalid identity/range or SQL failure returns a typed error and no durable receipt. Stdio writes validate the captured connection against the registered source; the writer lease is the local ownership fence, not proof that a remote request remains alive.

Retention validates the descriptor against the current stored stream on every call and allocates a positive per-stream Int64 ordinal inside the transaction. Successful return contains the committed immutable record and `wasInserted`; its initializer stays module-internal. Return only after COMMIT. No receipt contains a consumption callback, response method or mutable owner reference.

Each record retains exact original frame Data, first capture's receipt UUID and connection UUID, actual broker provenance when applicable and the original optional opaque helper pending-request ID. Empty Data, invalid UTF-8, malformed JSON, duplicate keys, non-method broker diagnostics and unknown/invalid method payloads are all retainable. Do not parse/re-encode frames, normalize known params or reject evidence because header interpretation fails. A source descriptor mismatch is different from uninterpretable bytes.

Identity rules:

- Stdio retries use the original common delivery receipt UUID within the registered connection. Copies retry once; separately captured equal frames remain separate records. The decoded adapter request ID is not a receipt key, so reused wire IDs and notifications remain distinct captures.
- Broker retries use broker ID/generation plus positive original event cursor. Reattachment can change connection UUID, delivery receipt UUID and journal/pending-snapshot origin; retain the first record unchanged. Require exact bytes and identical optional helper pending-request ID on retry. Opaque identity strings compare exact UTF-8, including Unicode spellings and embedded NUL; linguistic equivalence cannot merge distinct identities. A nil versus nonnil or different pending ID is conflicting metadata, not implicit enrichment. Current transport pending journal/snapshot paths already carry the same helper ID for the same event.
- Do not deduplicate by payload, method, adapter ID or helper pending ID alone. The helper currently derives pending keys from wire IDs; reuse can describe a later event, so cursor remains necessary.
- No storage mutation changes a broker ACK, helper pending request, queue or model. A caller may explicitly consume its original live handle after receiving committed proof, but neither new nor duplicate retention invokes it.

Raw broker metadata needs strict validation: positive generation and cursor within the supported signed SQLite range, valid broker ID/context, recognized provenance origin, and no broker fields on stdio evidence. Treat the helper pending ID as opaque; preserve it without converting it into a JSON-RPC ID. Byte-length conversions must be checked before using the SQLite binder. Database size/limit errors propagate without partial rows or ordinal consumption.

## Historical recovery without request authority

Provide passive discovery by local session, newest stream first, one descriptor per call with an optional prior stream ID. This permits discovery after reopen, broker clear/generation replacement, lease succession and old stdio connections without registration or a current writer lease. Validate discovery positions against the same local session. Historical reads do not require the source still match the current session broker row.

Read records by descriptor and optional stream-bound positive ordinal continuation. Validate descriptor identity and continuation ownership/existence; reject cross-stream, nonexistent and nonpositive positions. Read a consistent database snapshot. Default budgets are128 records and1 MiB; maximum record count1000 and maximum byte budgetInt32.max, with nonpositive/excessive budgets rejected. Inspect only lengths/ordinals for at most count+1 candidates, choose a bounded prefix, then materialize only selected frame BLOBs. Return one oversized first record with an explicit flag to guarantee progress. End means the end of the locally retained journal at this read, not upstream completeness.

Store the first broker ACK baseline on stream creation and preserve it across reopen/ACK advancement. A baseline greater than zero reports a known missing prefix. Zero baseline is not a completeness certificate; skipped non-inbound broker events and filtered routing mean these per-stream ordinals are not broker event sequences. Never treat a journal-tail or absence of a retained row as evidence that a request resolved.

Recovery returns immutable historical records without callbacks or successful-write receipts. A caller may explicitly decode the exact header using the merged common contract to distinguish request, notification or uninterpretable evidence; this is a pure view, not a persisted liveness state. Do not materialize a list called current pending requests from retained rows. A pending helper ID means the source supplied pending metadata when captured; it does not prove current unanswered status. A later helper resolution is not ingested by this slice, and a stdio connection may be gone. No reconnect/reopen mints a live handle or automatically retries an answer.

For a future response owner, a safe pending view must reconcile retained evidence with a current validated attachment/helper snapshot and independently commit response intent. That owner must handle cancelled/resolved/reused IDs and uncertain sends. This slice neither claims nor implements that reconciliation.

## Schema and lifecycle

Add schema33 to the existing session store, with additive inbound stream and record tables. Stream table has a globally unique canonical source key, local-session foreign key with delete cascade, immutable attribution/context and original baseline. Record table has `(stream_id, ordinal)` primary key and unique `(stream_id, receipt_key)`; metadata and original bytes are stored separately with strict decoding. Session deletion cascades through streams to records. No replica triggers/export, RPC/submission/update table changes, or ordinary v1 writes to these tables.

Retain old records after ACK, detach, broker clear, descriptor replacement and lease succession. Unknown format/context or corrupt stored metadata produces typed errors rather than silently skipping records, coercing identity or deleting evidence. Strict row decoding validates UUIDs, ranges, source shape, canonical keys and source/record consistency; it does not parse the frame. Keep read and mutation transactions separate and avoid publishing schema33 before tables/indexes are installed.

## Acceptance and validation

Extend existing schema/CRUD/persistence suites; add a domain suite only if there is genuinely new behavior that belongs outside store contracts. Use Swift Testing, real SQLite, event-gated concurrency and existing polling helpers. No fixed sleeps or scenario-sliced sibling suites.

- Registration/reopen preserves source, attribution and initial ACK baseline. Cross-local/upstream claims, stale leases, wrong connection, changed broker generation/context and unsupported ranges cannot insert or return durable proof.
- Exact byte retention survives reopen for whitespace/opaque numbers, binary, empty and malformed evidence. Copied stdio retries converge, separate equal captures survive, and broker reattachment retains original evidence despite changed capture connection/origin.
- Same cursor/receipt with conflicting bytes or pending metadata fails without overwriting. A reused helper or adapter ID at another cursor remains another record. Concurrent copies converge to one record; a trigger-induced SQL failure rolls back without consuming an ordinal.
- No callback runs on registration, insertion, duplicate, rollback, rejection, read or decode. Explicit caller consumption after commit is separate. Already-ACKed pending snapshots remain readable without invented callbacks or resolution authority.
- Count/byte paging, oversized-first progress, empty evidence, continuation ownership/existence, discovery after clear/replacement and unknown/corrupt metadata are pinned. Reads preserve ACK/session/replica state and never mutate request liveness or canonical completion.
- Migration32 to33 retains existing sessions, update/submission rows and ordinary v1 behavior. Session deletion removes inbound history; source changes retain old generations for passive discovery.

Run affected AlasCore suites first. Temporary source-identical app tests with only imports adjusted may accelerate RED/GREEN and must be removed before final native checks. Run full SwiftFormat lint, tracked/new-file whitespace checks and one focused native schema/CRUD/persistence attempt, recording actual counts and infrastructure failures separately. No full local app plan or unrelated dependency repair by default. One fresh final whole-change review, one material RED/GREEN fix pass if needed, no rereview.

## Delivery

This document is the only new file before full design approval. A fresh builder check will identify important planning gaps before presentation. After approval, write the implementation plan and use the established inline TDD workflow. Keep changes uncommitted until shipping is requested. No additional execution-menu approval is needed.

## Builder check outcome

One fresh builder check returned "nothing important left" after checking the proposed receipt identities, metadata conflicts, global source ownership and passive recovery against the existing transport/store contracts. No product code or tests were written during design.
