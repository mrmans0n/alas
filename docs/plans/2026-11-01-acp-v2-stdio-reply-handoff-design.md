# ACP 2 direct-stdio reply handoff

## Intent and boundary

Continue umbrella #2213 after broker reply handoff merged in PR #2308 at aa95d477b5db52074aef91ddfeb128e767d2b0eb, reviewed head0e8f956bd7515a0ff7f911e4a17efc7bb10fa244. Work from branch nacho/acp-v2-stdio-reply-handoff, preserving unrelated Ghostty/research changes.

The broker now fences replies by original event cursor and explicit attempt key. Direct stdio still has only legacy responders keyed by wire ID. Its raw inbound delivery is evidence without reply authority; the concrete client has no current capture registry or exact reply writer. A delayed answer must not target a newer request that reused the ID.

This slice implements the direct-stdio transport counterpart: current captured origins, exact response handoff and factual local write outcomes. It does not install response authorization, durable response intent, current-request reconciliation after reconnect, permission/file/terminal execution, canonical state, queues, UI, the production runner or adapter eligibility. Production remains v1-only. No helper/Rust/schema change is needed.

## Concrete source origins

Only a selected-v2 ACPStdioClient may register reply origins, at the point it captures a valid JSON-RPC method request into incomingV2Inbound. Construct the common delivery once, then atomically associate its immutable receiptID with the actual connection, method and wire ID before yielding it. No reply origin for notifications, session/update, outgoing RPC responses, diagnostics, malformed/ambiguous envelopes or frames arriving after drain.

The registry is private to the concrete client. It stores transport identity and lifecycle metadata, not copies of raw request history or interpreted payloads. A public ACPV2InboundDelivery initializer remains evidence-only: a caller cannot turn an invented delivery or a recovered ledger record into a registered origin. Actual copied handles retain their receipt identity. Persistence and durable consumption do not register or resolve reply origins.

Use exact UTF-8 for string IDs and attempt keys. Do not use synthesized Swift String equality or the legacy JSONRPCID-keyed dictionary as the incoming origin index. Numeric identities use the supported signed machine-integer domain; preserve existing inbound bounded integral-number interpretation. Match the caller's supplied response ID against that interpreted numeric identity or exact string bytes. Result bytes are never regenerated.

Keep incoming and outgoing request namespaces separate, including equal numeric or prefixed string IDs. No changes to existing outbound correlation semantics are required.

## Reply API and attempts

Add a narrowly scoped async concrete-client API taking the actual inbound delivery, expected connection ID, explicit caller attempt key and complete response frame. Exact names and local type layout are builder decisions. Use a new stdio/generic reply key type rather than implying the key is a broker operation. Result facts include connection, receipt, request identity, attempt key and status; identity comparisons are byte-exact.

Validate selected protocol, source/connection, registered origin, current unambiguous request, cancellation and the response envelope before scheduling a new attempt. Reuse ACPRawReply validation for accepted single-line response frames, including strict error fields and no literal CR/LF. Preserve its documented opaque-object limitation rather than changing the shared JSON parser in this slice. No normalization, legacy responder fallback or automatic method execution.

An explicit attempt binds one origin and exact response bytes for the lifetime of this client connection. The same key with different origin/bytes conflicts. An origin can have only one queued or claimed attempt. Identical retries return its current fact and never enqueue another write. Keep known attempt lookup separate from current-origin lookup so a factual retry survives later wire-ID reuse without affecting the successor.

Statuses distinguish queued, inFlight, written, writeUncertain and notWritten. The first call may await terminal evidence; identical concurrent retries may return queued/inFlight immediately. Queued means a candidate is scheduled and may still write, not proof that it never will. inFlight begins only when the actual writer authorizes the attempt immediately before I/O. Written proves a complete local framed write, not adapter receipt or execution. notWritten is terminal proof that this attempt was invalidated before any I/O. Pre-scheduling validation errors are typed rejections and create no write attempt.

Cancellation/stop before writer claim atomically disarms the queued candidate, records notWritten and releases its origin reservation. The same key remains bound and returns notWritten; a different key can be an explicit new attempt only if the original request is still current. There is no automatic retry. After claim, cancellation settles the caller promptly as uncertain, retains the binding and never grants permission for another attempt. The writer may later record its actual outcome; no cancelled waiter can be resumed twice or publish success through a stopped attachment.

Attempt facts can be queried by identical retries without another write, including an old resolved origin. A closed connection cannot accept a new attempt. Such a result remains attributed to the old connection and grants no current attachment or response authority. No reconnect/restart of a stopped client; a new adapter process requires a new client/connection identity.

## Reuse and ambiguous captures

If a new request reuses an ID while an earlier reply is in flight, install the successor under its fresh receipt identity before publishing it. The writer carries its claimed original across I/O and finalizes only that origin. Completion, failure and old-attempt retries cannot remove or answer the successor. This includes reuse after the adapter reads the full response but before the local write call returns.

After a reply is written, retire its active wire-ID slot before accepting another capture; a later request with that ID registers normally under a fresh receipt. Retained written attempts are historical facts and do not make the new capture ambiguous. A terminal uncertain write instead poisons the connection, so it cannot authorize a successor reply.

If the same ID arrives while the earlier request is still unanswered and unclaimed, or only has a queued reply, there is no evidence that it is legitimate sequential reuse. Preserve both raw deliveries, mark the conflicting wire-ID slot ambiguous and reject replies through either handle. A queued predecessor attempt becomes notWritten. Do not pick whichever request happened to arrive last, silently replace authority or auto-answer an error. Deliberate new attachment/reconciliation is outside this slice.

Retain minimal origin/attempt metadata until connection teardown; retain response bytes where needed for attempt conflict checks. There is no history replay, durable storage or automatic eviction that could permit a duplicate write. Document the connection-lifetime memory cost. Released/retired slots must still distinguish stale handles from current captures.

## Factual writer and shutdown

Add an opt-in AlasFoundation frame-writing protocol implemented by JSONRPCStdioTransport. Existing custom transports remain source compatible, but a transport without this explicit contract cannot use the new reply API. Do not assume that ordinary send return or its optional onWritten callback proves a factual write: existing fakes/custom transports can defer completion.

The new seam accepts an immutable body and an authorization callback evaluated by the actual writer immediately before I/O, after waiting for serialization. It reports notWritten, written or writeUncertain. It has no ACP or request identity dependencies. ACP owns the origin/attempt state and performs atomic authorization under its state lock, then releases that lock before pipe I/O. The Foundation implementation performs the new async work on a connection-owned worker off MainActor; do not block the caller while awaiting a write lock.

Serialize every write through the same underlying transport writer lock, including existing prompt/notify/respond paths, so large frames cannot interleave with an exact reply. The new seam preserves the supplied body bytes and adds only the existing newline framing. Do not promise FIFO order between concurrently submitted unrelated methods. No client state lock is held while acquiring the writer lock or writing; maintain writer-before-client-state order only for the authorization callback.

After I/O begins, any write failure is conservatively uncertain. Poison the transport writer and refuse later sends/notifications/replies on that same connection rather than appending to a possibly partial frame. Settle outstanding/queued reply waiters according to their actual claim state. Do not publish canonical completion, resolve unrelated inbound origins or consume receipts. Do not add a flush claim where FileHandle has no explicit flush boundary; written reflects the actual complete write operation supported by this transport.

Shutdown, adapter exit and observation loss invalidate queued authorization and settle waiters independently of the writer lock. Process termination must remain reachable while an exact reply is blocked and an ordinary send/notify is waiting behind it. No queue, MainActor task or client lock may hold shutdown behind those writes. Termination can interrupt a claimed write; any resulting uncertainty remains bound to that attempt. Do not automatically replace the adapter, resend, or treat socket/pipe acceptance as upstream execution.

Keep the existing v1 happy path, typed streams and response behavior intact. Shared transport serialization and refusal to reuse a poisoned stream are safety behavior; verify the affected legacy transport checks. New v2 reply calls must never use legacy inbound-consumption bookkeeping. Fence the legacy ID-only responders on a selected-v2 client so they cannot bypass origin checks or consume captured receipts.

## Tests and acceptance

Extend existing ACPStdioClientTests and its in-memory transport fake. Add a focused package suite only for genuinely new origin/attempt logic or the Foundation writer seam; avoid duplicating broker fixtures or wrapper codecs. Use event-gated writes, deadline waits and real isolated pipes only for the serialization/termination boundary. No fixed sleeps or default suite serialization.

- Actual capture/copies can reply once; invented, archived, wrong-source/connection, v1, diagnostic, notification and late handles cannot gain a reply origin. Header validity does not validate a method payload.
- Equal incoming/outgoing IDs do not collide. Byte-distinct string IDs and attempt keys stay distinct. Identical attempt retries do not write; changed bytes/origins conflict.
- Gate before authorization, during write and before finalization. Stop/cancel/replacement before claim yields notWritten with no bytes; after claim it promptly yields uncertainty without permitting resend. Delayed results cannot double-resume or revive ownership.
- Sequential ID reuse during finalization preserves an independently answerable successor. Unclaimed/queued duplicate ID captures become ambiguous and cannot be answered. Old successful/uncertain attempts cannot target the new origin.
- Capture consumption and reply write remain independent in both orders; no ACK callback is invoked by parsing, handoff, retries or write completion.
- A delayed transport proves ordinary send return is insufficient. Unsupported custom transports fail before handoff. Accepted exact bytes survive a real pipe; partial failure prevents later writes.
- A blocked large reply plus waiting ordinary send/notify cannot block shutdown. Verify actual process/pipe termination, queue settlement and no orphaned continuations rather than only calling an inner helper.

Run affected AlasCore suites first and inspect counts. Extend app-owned transport tests and validate their selected native suites when practical; if the known missing native package cache prevents compilation, retain that as inconclusive and use source-identical temporary import-adjusted package checks without claiming an app build. Run SwiftFormat and scoped whitespace checks. One fresh final whole-change review, one material RED/GREEN fix pass if needed, no rereview. No live adapter/SSH or production claim.

## Delivery and choices

This document is the only new file before design approval. A fresh builder check reviews origin lifetimes, cancellation and writer/shutdown ordering first. After approval, write the implementation plan and continue the established inline TDD workflow without another execution menu. Leave changes uncommitted until shipping is requested.

My choices are a concrete-client source registry rather than reply authority embedded in a receipt; an explicit opt-in factual writer rather than reinterpreting send/onWritten; and fail-closed ambiguity for unclaimed duplicate IDs. Durable intent, semantic request reconciliation/authorization, complete response ownership and production integration remain subsequent umbrella slices. Broker signed-zero and shared opaque-object validator differences remain tracked qualification work.

## Builder check outcome

One fresh Swift transport builder check returned "nothing important left". It identified a wording gap around reuse after written replies; the lifecycle now explicitly retires the written origin's active slot, accepts subsequent reuse normally and limits ambiguity to unanswered unclaimed/queued predecessors. This clarification does not expand reply authority or implementation scope. No product code or tests were changed during design.
