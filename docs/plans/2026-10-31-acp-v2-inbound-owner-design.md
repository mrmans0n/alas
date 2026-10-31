# ACP 2 ordered inbound receipt ownership

## Intent and scope

Continue umbrella #2213 after passive inbound receipt persistence merged in PR #2299 at `26fe6397de2edd0c4ab6d325e33aa15fbbf48665`. Its final implementation head was `a15ed6c9cc7d5a10b5c192f97183eda2b4f900df`, including two CI test synchronization fixes. Use branch `nacho/acp-v2-inbound-owner` from that merged main, preserving unrelated Ghostty and adapter research inputs.

The ledger retains exact bytes and committed proof, but callers still have to order receipt retention, check attachment ownership after awaits, and explicitly consume the correct live handle. This slice puts those responsibilities in one attachment-bound owner. It is an additive, fixture-capable component; production protocol selection remains v1-only and no runner installs it yet.

This splits the umbrella's broad next item deliberately. Current-request reconciliation, durable response intent and actual replies need a stronger reply contract first. Today ACPRawBrokerTransport.respond sends by wire ID, and broker_respond resolves the helper's current pending entry by a derived key before writing the response. It does not compare the original pending cursor, and operationKey is not a response-attempt deduplication boundary. A helper ID can be reused at another cursor. Do not build an owner that treats historical ledger metadata or a stale snapshot as permission to call that API.

My proposed sequencing is therefore: ordered receipt ownership now; origin-fenced raw reply handoff and factual write outcomes next; durable intent/current-attachment reconciliation composed with a response owner after that. This is an implementation decomposition, not a claim that the wider inbound-request workstream is complete.

Exclude replies or response intents, current pending-request lists, permission decisions, filesystem/terminal execution, helper/Rust protocol changes, UI, queues/canonical foreground state, upstream resume, SSH replication and production v2 activation. No database migration is needed beyond merged schema33.

## One receive task, existing streams

Add ACPV2InboundReceiptOwner in AlasSessions, adjacent to the inbound ledger. Add a small Sendable ACPV2InboundLedgerPersisting protocol for registration, retention and bounded record reads; the existing persistence actor conforms. Keep discovery available on the persistence actor, but the owner restores only its registered source stream rather than discovering and reviving other sources.

Use a main-actor owner, matching the established canonical session owner, because its synchronous ownership predicate and lifecycle invalidation share that executor. It owns one managed Task and one attachment, starts once, and supports explicit stop plus waiting for task completion. It does not own or shut down the transport, the session lease, or the existing update/submission owner.

Accept the existing stdio incomingV2Inbound stream directly. For broker input, accept incomingRawFrames and read each facade's stored inboundDelivery in the same receive loop. An overload or internal generic sequence may implement this; do not add a second broker stream, mapping task, queue or raw-frame array. One owner consumes each raw inbound stream. It must never subscribe to incomingV2Updates or outgoing RPC delivery paths.

An immutable Attachment binds the selected-v2 concrete client connection UUID and source tuple. Factory methods take the stdio client, or the broker client plus its validated open result. Reject v1 clients. For broker identity, the existing read-only v2PromptEndpoint can supply the actual connection/broker/generation tuple without invoking prompt sending; compare it exactly with the raw-v2 open metadata and the constructor's local session context. This reuses an identity value, not submission capability. If a clearer narrowly scoped identity accessor is necessary, that is left to the implementation plan; do not rename/restructure the existing endpoint system.

Validate raw-v2 context, supported positive signed-range generation/cursors, matching actual broker ID/generation/connection, local session metadata, and ACK not beyond the open journal tail. The open result establishes attachment identity, not current request liveness or response authority. All opaque identity comparisons must preserve exact UTF-8, including Unicode spellings/BOM/NUL, consistently with the ledger. Upstream attribution remains caller-supplied, not inferred from arbitrary method params.

## Restore then retain in order

On start, check task cancellation and the supplied synchronous isCurrent predicate, register the inbound stream under the supplied matching local writer fence, then check ownership again. Registration may reopen the same broker source while keeping its original baseline; a fresh stdio source does not reopen a different connection's history.

Read bounded schema33 pages before draining live input, using the existing128-record/1MiB defaults and oversized-first policy. Validate the returned descriptor, record source and strictly contiguous positive ordinals. Preserve the original frame, receipt UUID, connection UUID, broker cursor/origin and pending metadata in historical observations. A historical broker connection may differ from the current attachment; its broker ID/generation must match. Stdio history must retain the exact same connection UUID. No restoration operation produces or consumes a transport handle.

Keep only the current page, the latest record/observation and a retained-prefix ordinal. Do not build an in-memory copy of history or a dictionary of supposedly pending requests. A page's local end is not upstream completeness, and the known-missing-prefix flag comes from the ledger's fixed baseline. Retained helper metadata is not reconciled into liveness during restore.

For each live delivery, sequentially:

1. Check current ownership and validate its connection/source against the attachment, including exact broker ID, generation and a positive supported cursor.
2. Await lease/source-fenced retainV2Inbound, then check ownership again before changing owner state or consuming anything.
3. Validate the committed record's stream/source/identity and exact frame/pending metadata against the current delivery, allowing the ledger's first-capture broker connection/receipt/origin to differ on retry. For stdio, the original receipt and connection must match.
4. Advance the retained-prefix watermark only for the next contiguous ordinal. A duplicate at or below the restored/retained prefix does not advance it. An ordinal gap blocks the owner rather than silently skipping another writer's records. Do not accumulate a seen-payload set.
5. Publish a latest-only durable observation, then synchronously recheck ownership and explicitly consume the original live delivery. Never reconstruct a callback from the committed record. No await or external observer callback occurs between that check and consumption.

A current broker redelivery can thus be consumed after its matching committed row is confirmed, even though the row retains another attachment's original metadata. A copied stdio handle retries once; separate equal captures both retain their own ordinals. No code assumes ordered input proves a complete broker cursor sequence.

## Receipt durability is separate from interpretation

All evidence accepted by the merged ledger remains retainable, including notifications, unknown methods, malformed headers/known params, unmatched broker response diagnostics, duplicate-key JSON, invalid UTF-8 and empty frames. The owner does not parse method payloads, reply, execute extensions, reject a request or mutate canonical session state.

A malformed frame is not a storage failure: once its exact evidence is committed and the owner remains current, the original live receipt may be consumed. This proves durable receipt only. The caller can inspect the immutable record with its existing pure decodeHeader view; decode failure does not erase evidence or imply helper resolution. This is deliberately different from the update owner's canonical-application gate, because this owner applies no canonical model.

The owner exposes idle/restoring/receiving/observationLost/stopped/blocked status, current stream, lastRetainedOrdinal, hasKnownMissingPrefix and a revisioned latest observation. Observations distinguish historical restoration, newly retained input and duplicate receipt confirmation. They are latest-only invalidations, not a reliable work queue; slow observers may skip revisions and must query the ledger for history. Include the immutable record for inspection, without a durable-write receipt or live delivery. Reading owner state cannot consume or grant reply authority.

## Ownership, failure and teardown

Check cancellation, source identity and isCurrent before work and after every persistence await. Recheck stopped/blocked/cancelled state after evaluating the predicate too, so synchronous reentry cannot authorize consumption through a stopped owner. Stop invalidates synchronously on the owner executor and cancels its Task. A COMMIT already in flight may still finish, but its result cannot publish or consume through the stopped/replaced owner. A successor can recover that durable row from the ledger.

Block on stale lease, current descriptor mismatch, storage error, corrupt/unsupported ledger format, invalid source, inconsistent committed proof or ordinal gap. Preserve the last known retained prefix, finish observations and stop reading further deliveries. Report failure with the operation/ordinal where useful. Never turn a failure into a fabricated consumed receipt or implicit success. Do not automatically seize a lease, clear/replace a broker tuple or restart a transport.

Unexpected input EOF becomes observationLost and finishes observations after current ownership is checked. It does not resolve requests, close the helper, claim canonical completion or release queue work. Intentional stop remains stopped and cannot be overwritten by the task's later return/catch. There is no automatic reconnect or restart; a deliberate new attachment uses a new owner.

The final current-owner check and callback invocation are a local boundary, not an atomic transaction with SQLite lease takeover or remote ACK. A lease taken after COMMIT is not synchronously revocable unless the owning session invalidates isCurrent; existing transport callback lifetime fencing still applies. Do not add a redundant database check and call that remote atomicity.

## Acceptance and validation

A new ACPV2InboundReceiptOwnerTests suite is appropriate for this new owner. Extend existing broker/stdio suites only where concrete integration earns coverage; do not duplicate their transport/header tests. Use real SQLite plus small persistence gates/fakes, with event/deadline waits and no fixed sleeps.

- Registration and every replay page precede live retention. Multiple replay pages restore an exact prefix without callbacks, liveness or canonical completion. Retained history from another source is not revived.
- Gate registration/page/retain at entry and after commit/return; stop, cancellation and observed replacement before return cannot publish or consume. A committed unpublished row is recoverable by a successor. Stale lease and real SQL failure block further input without ACK.
- Separate equal stdio captures survive; copies retry without prefix advancement. Broker redelivery after restoration consumes the current handle once while preserving original frame/metadata. Already-ACKed pending snapshots gain no callback from replay.
- Malformed/unknown/notification/diagnostic frames retain exact bytes and may be consumed only after durable storage; no typed handler, response or application state changes. A failed header view remains historical evidence.
- Wrong connection/generation/context, byte-distinct broker IDs/pending metadata, inconsistent receipt/projection and ordinal gaps fail closed. Reject v1 clients and misconfigured attachment/open identity.
- Concrete raw broker stream integration proves the facade/common view is read without another stream and that ordered ACK occurs after retention. Stopping/EOF has no helper resolution or reply side effect. Production negotiation remains v1-only.
- Keep memory limited to the existing source buffer, one bounded replay page and latest observation. No second receive bridge, history cache or pending-request map.

Run affected AlasCore suites first, inspect actual selected counts, then focused native transport tests when app files change. Preserve the known local missing-manifest limitation without unrelated dependency repairs. Full SwiftFormat and scoped whitespace checks, one fresh final whole-change review and one material RED/GREEN fix pass if needed; no rereview. Keep changes uncommitted until shipping requested.

## Delivery

This design is the only new file before full approval. A fresh builder check reviews the proposed boundary and ownership rules before presentation. After approval, write the implementation plan and proceed with the established inline TDD method, without another execution menu. The wider umbrella still needs current-request reconciliation, an origin-fenced reply contract, durable response intent and production integration.

## Builder check outcome

One fresh builder check returned "nothing important left" after inspecting the ledger, common delivery, existing update owner and concrete stream/identity contracts. No product code or tests were written during design.
