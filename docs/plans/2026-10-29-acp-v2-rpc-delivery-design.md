# ACP 2 raw RPC response delivery

## Intent and sequence

Continue umbrella #2213 after ordered update owner #2264. Before storing prompt registration and acceptance, the caller needs the original RPC response and its consumption authority. Today stdio errors are decoded through AnyCodable and consumed during dispatch, successful ACPResponse values expose only result bytes, and broker success drops the original envelope and completion cursor from its public response.

This slice makes v2 RPC responses lossless and caller-owned across stdio and the raw broker. The next slice can then commit exact response evidence together with submission state before consuming it. This is a transport boundary, not the durable submission ledger itself.

Production remains v1-only. The v1 runner, initialization policy, outgoing request serialization, queue, UI, prompt retry policy and existing v1 error handling stay unchanged.

## Goals

- Retain the original full response frame before generic decoding for explicitly selected v2 transports.
- Bind matched responses to the exact pending request or broker operation, never to arrival order, text, or a guessed ID.
- Expose immutable connection identity and real broker generation/cursor provenance when available.
- Preserve success, valid RPC error and malformed matching-response evidence without implicit consumption.
- Share one single-use consumption token across copied delivery/response/error views, including compatibility acknowledgement accessors.
- Retain unmatched or unclassifiable v2 response evidence for an explicit diagnostic owner, without settling another request or silently consuming it.

No SQLite/schema changes, submission reconstruction, pending adapter-request durability, permission answering, live v2 activation, upstream resume, SSH deployment/replication or adapter publication. RPC failure is not foreground completion and does not by itself prove whether a prompt was inserted.

## Delivery and interpretation

Add an immutable raw RPC delivery value in AlasACP with a fresh per-construction receipt UUID, exact Data frame, immutable connection UUID, source/binding metadata, optional real broker event provenance and private single-use consumption. Copies preserve receipt identity and share consumption. A broker retry may construct another handle for the same event; its generation/cursor remains the durable identity for a later journal.

The successful ACPResponse gains an additive optional raw-delivery view, defaulting to nil for existing callers. Keep body as the existing exact-value result representation. Full original whitespace, object order and numeric spellings belong to the retained frame; do not pretend that re-encoded result bytes are the original envelope.

A v2 error exposes the same raw-delivery contract plus an optional factual JSONRPCError projection. Preserve ACPBrokerRawRPCError's existing public frame/rpcError access and classification behavior. The implementation may introduce a common v2 error type or protocol for stdio while adapting the existing broker wrapper. Existing hook-review classification must recognize the reserved error/code/kind through the new view, without consuming it. Do not change the helper's special hook-rejection retention or replay policy.

Decoding is a pure explicit operation and never consumes. Use the exact LSPJSONValue parser for complete frame validation. Require a JSON-RPC 2.0 response object, no method member, a supported non-null ID, and exactly one result or error. An error must have a supported bounded integer code and string message. Preserve its complete raw error/data value, including opaque exponent tokens and large integers; a generic AnyCodable projection is not raw authority. Keep the repository's existing Int bounds for RPC error projection rather than adding an unrelated numeric-policy change.

Interpret supported response IDs without floating-point conversion. Preserve existing stdio JSONRPCID signed Int/string support and the raw broker's UInt64 adapter request IDs. A common metadata representation may distinguish those domains rather than narrowing the broker to signed Int. The source frame remains authoritative even when a bounded interpretation fails.

The exact type names and error-view shape are builder choices. There must be one consumption token per delivery, not separate callbacks hidden behind the raw and legacy views. Direct calls to the existing durableConsumptionAcknowledgement closure and acknowledgeDurableConsumption methods must share that token when a raw delivery is present. Taking/calling it must tolerate concurrent copies and synchronous reentry without holding its lock while executing caller code.

## Stdio routing

Apply this path only when the client's immutable sessionUpdateProtocolVersion is v2. Keep session/update delivery exclusive and unchanged. Match a valid response ID against the pending table under the existing lock, retaining the request method/binding needed by the delivery. Do not let Foundation decode or normalize the error object before its raw frame has an owner.

A strictly valid matching result returns ACPResponse with its raw delivery. A strictly valid matching error throws the v2 raw error view. Both retain the original frame and leave consumption to the caller. Null success is present success, not absence. Opaque numeric error data cannot turn an actual error into success or cause the error frame to be consumed during failed generic decoding.

Only frames with no method member are eligible for outgoing-response binding. Such a frame with a uniquely and exactly decoded supported pending ID but contradictory result/error, invalid jsonrpc or invalid error fields cannot become success. Surface a bound raw interpretation failure, retaining the original evidence and unconsumed handle.

A frame containing any method member plus result or error is ambiguous between the peer's inbound-request ID namespace and the client's outgoing-response namespace. Route it as unbound diagnostic evidence even if its ID matches a pending outgoing call; do not settle that call or dispatch an inbound operation. A valid string method with neither result nor error keeps existing inbound request/notification routing. An invalid method value is diagnostic evidence and cannot grant outgoing binding. Presence and absence of method are distinct; null is not absence. These rules take precedence over the pending-ID lookup.

When exact parsing rejects a frame, especially duplicate IDs/keys or invalid UTF-8, do not use a lossy fallback ID to choose a pending continuation. A shallow tolerant header may classify evidence as a response candidate, but cannot grant request binding. Likewise unmatched/late IDs, null/unsupported IDs and ambiguous frames cannot settle another pending call. Publish them to an explicit raw v2 diagnostic delivery stream or equivalent existing raw diagnostic channel. Unclassifiable v2 frames must not fall through to the legacy auto-consumption defer. Keep bytes and the original single-use handle; no response success or acceptance is inferred. This channel does not process or persist pending adapter requests.

Use one diagnostic delivery channel, not an additional accumulating raw-frame array. This transport slice does not solve backpressure or durable diagnostic retention. A future owner must drain/store or explicitly reject diagnostic evidence before consuming it; there is no automatic ACK on yield, parsing, stream termination or shutdown.

Transport observation loss still settles outstanding continuations with the existing factual transport error. It does not retroactively consume previously returned raw deliveries or diagnostic handles. Keep callbacks bound to their original connection lifetime, following existing transport generation/lifetime guards; a late callback cannot acquire authority for a replacement connection. Do not claim an atomic transaction between callback invocation and remote acknowledgement.

## Broker routing and caches

Use the raw source frame already supplied by acp/raw/send and the matching completion cursor already established by ACPRawBrokerTransport.send. Attach that real broker ID/generation/cursor, immutable connection UUID, exact operation key and adapter request identity to the raw delivery before returning or throwing. Never reconstruct the original frame from ACPResponse.body or JSONRPCError.

Preserve ordered broker ACK protection, fresh replay beyond an older in-flight poll, exact same-key completion selection and detach fencing. Consuming any view of one delivery may release only its own completion cursor, never a newer outcome under the same operation key. Existing pending-request and update owners keep their authority.

Snapshot-cached initialize/session responses have original frames but no newly observed operation event. Expose them with explicit snapshot-cache origin, original source ID and no live event-consumption authority. Do not assign the current logical call a fabricated adapter ID, operation key or journal cursor. Preserve the existing cache behavior; the delivery metadata must distinguish cached source from a newly dispatched response. Cached errors likewise retain evidence without a fabricated callback.

Broker-generated failure without adapter bytes, such as -32074 after stdout closes, remains a transport/broker diagnostic. Do not manufacture a raw response frame or classify it as an adapter rejection. Unknown/malformed raw error projection retains the raw failure and cannot become success.

## Future durable owner contract

The later submission ledger will store a local submission identity and exact local-row correlation before request handoff, then retain the returned raw outcome before consuming its live handle. This slice does not add a handoff API, replay a prompt, restore pending submissions, infer rejection from connection loss or grant a stored receipt callback authority.

The ordered update owner remains responsible only for session/update. RPC returns are associated through their exact request binding; they are not inserted into its update stream or used to advance its lastAppliedOrdinal. Acceptance and foreground lifecycle remain independent.

## Acceptance and validation

Use Swift Testing and existing stdio/broker suites. Prefer event-gated in-memory transports and existing broker service fixtures; extend their suites rather than adding scenario-sliced siblings. Synchronize any concurrently accessed fake state used by new tests. A dedicated suite is appropriate only for a genuinely new raw-delivery/parser type.

- Success, null result, valid errors and opaque/huge error data retain original full bytes across the public response/error views, with zero consumption before explicit action.
- Copies, compatibility closure/method access, concurrent consumption and synchronous callback reentry invoke one shared callback at most once.
- Reversed responses for distinct pending requests retain exact association, including string and signed integer IDs where supported. Wrong/null/unsupported IDs never settle another pending request.
- Contradictory response shapes cannot become success; duplicate keys, invalid UTF-8 and parser failures remain diagnostic evidence with no guessed binding or implicit ACK. A method-plus-result/error frame with a colliding pending ID is diagnostic only, while a valid inbound request can reuse that ID without settling the outgoing call.
- A bound interpretation failure retains the raw frame and callback; decoding, reading diagnostics, shutdown and late response delivery cannot consume it automatically.
- Broker success/error preserve real operation identity and provenance. Snapshot cache origin and source-less broker failures never gain fabricated live consumption authority.
- Repeated same-key completions, hook review errors and detached/replaced attachments retain their existing fencing and evidence. Raw callbacks cannot release a newer outcome's cursor.
- Existing v1 stdio/connection and broker behavior remains covered. Run affected package tests first, then focused native stdio/connection/broker suites if those interfaces change. Confirm actual selected counts; complete full SwiftFormat and whitespace checks. No CI or live adapter result is implied by fixtures.

## Delivery

Use the approved native inline execution method after full design approval, with meaningful RED/GREEN tasks and one fresh final review. Keep work uncommitted until shipping is requested. Implement on nacho/acp-v2-rpc-delivery from merged main. Preserve unrelated adapter research and any unrelated submodule checkout mismatch.

## Builder check outcome

One fresh builder check found a routing ambiguity when a frame carries both a string method and response members under an ID that also belongs to a pending outgoing request. My design choice is to preserve it as unbound diagnostic evidence. It cannot dispatch an inbound operation or settle an outgoing continuation. Only method-absent frames can bind outgoing responses; valid inbound requests keep their independent ID namespace. This conservative rule may leave a malformed call pending until transport failure or caller cancellation, but it avoids guessing which request the peer meant. The explicit routing and validation rules above resolve the question without changing product scope. No product code, tests or commit were made during design.
