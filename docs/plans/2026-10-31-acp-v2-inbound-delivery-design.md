# ACP 2 raw inbound method delivery

## Intent and scope

Continue umbrella #2213 after merged PR #2276 at `79a8f405c910c0cf18b49db1105fb2321f3485ba`. Use branch `nacho/acp-v2-inbound-delivery` from that merged main and preserve unrelated Ghostty and adapter research inputs.

Before adding durable pending adapter-request recovery, the caller needs exact inbound request evidence and explicit receipt consumption. Selected-v2 stdio currently sends valid inbound methods through generic v1 handlers. That can normalize opaque params, run extension behavior, send automatic errors, or consume evidence when a response write completes. The raw broker already retains original frames, pending-request IDs and origin cursors, but exposes a broker-specific delivery value.

This chunk provides a common immutable inbound-method delivery and exclusive selected-v2 capture. It does not implement SQLite request storage, request/response recovery, permission decisions, filesystem or terminal execution, UI, response dispatch, upstream resume, SSH, helper deployment or live v2 activation. Production supported versions remain v1-only. The existing v1 handlers and their response/consumption behavior remain unchanged.

This transport boundary is the necessary next step before a durable request ledger and response owner. It follows the same sequence used for raw RPC outcomes before the submission ledger.

## Common delivery value

Add a public Sendable inbound delivery in AlasACP. Preserve full original Data, a fresh immutable per-construction receipt UUID, immutable connection UUID, source metadata and a private shared single-use receipt-consumption token. Copies preserve identity and share consumption. Decoding, projection, stream reads and shutdown never consume automatically.

Sources are explicit:

- Stdio identifies its actual immutable connection, with no broker identity or pending token fabricated.
- Broker preserves the real broker ID/generation/event cursor/origin and optional helper pending-request ID from the existing raw delivery. A pending snapshot keeps its original event cursor; it is not a newly observed event and cannot gain a fabricated ACK callback when already acknowledged.

The receipt UUID distinguishes source captures, not payload contents. Two equal stdio chunks remain two deliveries. Broker redelivery may create a fresh handle/UUID for the same durable event, whose broker ID/generation/origin cursor remain available for the later ledger to deduplicate. Do not deduplicate by method, params text or adapter request ID alone.

The helper pending-request ID is opaque metadata, not the JSON-RPC ID decoded from the frame and not reply authority. Preserve both domains without parsing one into the other. A consumed receipt does not prove a request was answered or resolved; an unanswered helper request can remain pending after its origin event was durably received.

A pure header decoder validates exact JSON-RPC object structure using LSPJSONValue: jsonrpc must equal 2.0, method must be a string, and result/error members must be absent. Distinguish method requests with a supported non-null ID from notifications with no ID member. Use the existing signed Int/string JSONRPCID domain without floating-point conversion. Null, bool, fractional, overflow and unsupported IDs cannot gain request binding. The helper's outbound adapter-operation UInt64 IDs are a different domain and must not widen inbound request interpretation beyond its existing signed/string contract.

Expose method, optional typed ID, exact raw params value and the original parsed object. Omitted params and explicit null remain distinct. Header validation does not grant method-specific validity: retain malformed known-method params and opaque future params for a later owner to validate and retain or explicitly reject. Do not decode permission/file/tool payloads through AnyCodable first. Duplicate keys, invalid UTF-8 and exact-parser failure cannot acquire a guessed request ID.

The common value has no respond/approve/deny/write/execute method. It grants only explicit consumption of its original receipt handle. Future response ownership must separately bind the exact adapter request and commit response intent before using a response transport. This chunk does not turn legacy arbitrary-ID responder APIs into a safe durable response interface.

The builder may choose the concrete type and decoded-value names and reuse a small existing consumption implementation where appropriate. Do not refactor unrelated delivery contracts merely to unify private helpers.

## Stdio exclusive routing

Only explicitly selected v2 clients expose the new active inbound-method stream. V1's new stream finishes immediately. For v2, valid non-session/update method envelopes with absent or supported request IDs go exclusively to this raw channel, preserving original frame bytes before generic decoding. No generic inbound request/notification dispatcher is invoked for those frames.

This includes permission, filesystem, terminal, ask-user, plan approval, elicitation, cancellation and extension methods, plus future/unknown methods. Unknown methods receive no automatic method-not-found response here. Known methods receive no automatic invalid-params response, cached extension mutation or response-write ACK. Notifications with the same method names retain notification identity and never gain a synthetic request ID.

Finish the corresponding legacy typed inbound method streams for selected-v2 stdio, matching the raw broker's separation. Leave stderr and transport lifecycle observation intact. Preserve the active v2 session/update stream and existing RPC response/diagnostic channels. There is one capture channel per frame, no parallel legacy/raw dispatch, accumulating frame array, or extra owner task introduced to bridge streams.

Routing precedence remains conservative:

- Keep the existing exclusive session/update path, including identifiable parser-rejected update evidence. A session/update carrying an ID remains invalid update evidence, not a request to answer.
- Any method member mixed with result/error remains an unbound RPC diagnostic, even with an ID colliding with an outgoing call. It cannot become an inbound request or settle that outgoing call.
- Exact supported method requests and notifications use the new raw inbound stream. An inbound ID can equal a pending outgoing ID without affecting it.
- Invalid method/header/ID or exact-parser rejection stays in the existing raw diagnostic path without guessed request binding. Do not use a fallback ID. The existing method-only fallback for session/update classification does not authorize a request.
- Method-absent responses keep the merged raw RPC matching behavior.

Callbacks stay bound to their original stdio lifetime, using existing lifetime guards. A returned/copied handle cannot acquire authority for a replacement client. Shutdown/EOF finishes the stream without consuming buffered or retained values. Do not promise an atomic transaction between a local callback and remote acknowledgement. Existing public typed responder APIs are outside the durable response path; this change prevents automatic v2 dispatch into those handlers, not every possible manual call to an old responder.

## Broker compatibility without a duplicate stream

Keep ACPBrokerClient.incomingRawFrames and the existing ACPBrokerRawFrameDelivery public fields and acknowledgement method source-compatible. Give each existing broker delivery one stored common inbound view, available without reconstructing its frame or token on each access. The facade and common view share receipt identity and one consumption token; consuming either view at most once invokes the same original callback.

Use the existing raw frame stream as the broker's sole stream for non-update, non-matched-outcome evidence. Do not add a second independently consumed broker inbound stream or a background mapping task. A future owner can read a broker frame and take its common view directly.

That broker channel also contains non-method diagnostic evidence, such as unmatched response frames. Preserve those frames and expose header decode failure without relabeling them as a pending request. Only real helper pending-request events/snapshots carry a pending ID. A method-looking raw frame without pending metadata must not be upgraded to helper pending authority. The common decode API interprets the frame; it never creates missing helper metadata.

Preserve exact snapshot origin, ordered ACK protection, already-acknowledged unanswered pending snapshots, detach/close fencing and existing raw response APIs. Receipt consumption and pending-request resolution remain independent. No Rust schema or helper retention change is planned; inspect existing helper contracts and keep their tests as regression evidence when relevant.

## Future durable owner contract

The next ledger can use the original connection/source identity, exact request ID and method, helper pending ID and real broker origin cursor to retain evidence before consuming a live receipt. It must distinguish receipt durability, request liveness, response intent and delivery uncertainty. This chunk adds none of those persisted states and does not infer approval, rejection, cancellation or permission from raw capture.

No incoming delivery is applied as a session update, increments lastAppliedOrdinal, changes canonical foreground state, advances a queue or claims completion. No old stdio request is revived on a new connection and no broker pending snapshot is answered automatically during attachment.

## Acceptance and verification

Extend existing stdio and raw broker suites. A dedicated suite is appropriate for the genuinely new common header/token contract. Use Swift Testing, synchronized in-memory transport fixtures and event gates, without fixed sleeps or redundant wiring-only tests.

- Preserve exact full bytes and opaque numeric params across requests, notifications, known malformed params and unknown methods. Reading/decoding/copying never consumes or invokes an automatic response/extension action.
- Distinguish absent ID, supported negative/string IDs, null and unsupported IDs; preserve omitted/null params. Reject method-plus-response ambiguity, duplicate keys and invalid UTF-8 without guessed binding or implicit consumption.
- An inbound request can reuse an outgoing ID without settling it. Only its exact method-absent response settles the outgoing call. Each valid v2 frame has one destination, while v1 retains its existing typed behavior.
- Captured permission/file/terminal/unknown methods do not appear on legacy v2 typed streams or cause transport writes. Raw notifications and cancellation notices remain caller-owned evidence.
- Copies, common/facade views, concurrent consumption and synchronous reentry invoke one token at most once without holding its lock through callbacks. Separate equal frames keep distinct receipt UUIDs.
- Broker pending journal/snapshot deliveries preserve real helper ID/generation/origin and original bytes, including an already-ACKed unanswered request with no new callback. Consuming a receipt never resolves that pending request or consumes another cursor.
- Shutdown/detach, stream end and late handles preserve existing lifetime fencing without implicit ACK. Session/update, raw RPC outcomes, hook errors, prompt ownership and production v1 selection retain their merged behavior.

Run focused AlasCore tests first, then affected native stdio/connection/broker suites when feasible. Temporary source-identical app tests with only import adjusted are permitted for rapid cycles and must be removed before native checks. Report actual selected counts, full SwiftFormat and whitespace results, and one fresh final whole-change review. Keep native cache/Ghostty limitations distinct from passing package evidence; no unrelated dependency repairs.

## Delivery

After full design approval, use the established inline implementation method with meaningful TDD and one fresh final review. Keep changes uncommitted until shipping is requested. This document is the only new change before approval. A fresh builder check will resolve important planning questions before presentation.

## Builder check outcome

One fresh builder check returned "Nothing important left." It checked outgoing/incoming ID separation, exclusive v2 routing, broker facade compatibility, snapshot provenance and the distinction between receipt consumption and request resolution. No product code or tests were written during design.
