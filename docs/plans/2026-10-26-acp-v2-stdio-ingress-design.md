# ACP v2 lossless stdio ingress

Status: approved with `yes` on 2026-10-26. Builder check found nothing important left.

## Intent and sequence

Continue [umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) after merged [PR #2233](https://github.com/mrmans0n/alas/pull/2233). The canonical v2 session owner is ready, but current transports still decode session updates as v1. A direct response also passes through JSONSerialization before the new exact wire codecs receive it.

The next slice adds explicit low-level v2 notification delivery to `ACPStdioClient` and preserves successful JSON-RPC result values without Foundation numeric conversion. In-memory transport tests will feed these deliveries into the merged owner, proving the full frame-to-model path and deferred consumption behavior.

This is the direct stdio slice only. Broker/SSH lossless payloads follow separately: `ACPBrokerJSONValue.number(Double)` and Rust helper `serde_json::Value` currently precede the exact v2 codecs. Adding a v2 decoder only in ACPBrokerClient would not recover already-lost values. Do not claim that broker path supports opaque v2 numbers or reopen it under a new wire mode in this slice.

Live adapter eligibility stays empty, the Debug preference stays default-off, and production connections still use ACP1. No v2 initialize/session/prompt requests, runtime runner, UI, storage/replay, queue/cancellation/permission integration, broker changes, or helper release is installed here. Keep work local until a separate shipping request.

## Existing code and base

Branch `nacho/acp-v2-stdio-ingress` starts at merged main `62e1b51678284c94d4bf116ecc2138f9ebdc056a`. Preserve the pre-existing untracked adapter-support research note.

- `ACPStdioClient.handleFrame` currently decodes session/update through `ACPSessionUpdateFrame` and publishes v1 `incomingUpdates`. Its fan-out puts the durable callback on the last normalized update.
- `ACPStdioClient.extractResultBytes` currently uses JSONSerialization to parse and rewrite result values. It must instead use the existing exact raw JSON codec.
- `ACPClient.yieldedUpdateCount` is a drain watermark. Current runners consume its v1 stream; that count and normalization behavior must remain compatible in the default mode.
- `ACPConnection.initialize` captures the negotiated version but production selection still requests/supports only v1. A low-level decoder mode must not bypass that boundary.
- `RemoteHelperACPTransport` has separate byte-offset consumption and attachment ownership. It is not part of the direct-only evidence claimed here.

## Immutable low-level mode

Give ACPStdioClient an explicit immutable session-update protocol mode, default `.v1`, chosen when constructing the client and never changed while it runs. Both executable and injected-transport constructors support it. Choosing `.v2` is available for fixtures and future integration only; it is not adapter eligibility or successful negotiation.

Expose the configured version through an additive ACPClient property with a v1 default for existing conformers. Add a v2 delivery stream with a finished default for clients that do not implement it. Existing mocks and brokers remain v1; do not implement a second transport path through protocol-extension forwarding tasks.

Exactly one session-update stream is active for a concrete stdio client. In v1 mode, preserve existing decode/normalization, fan-out, extension routing, watermarks, and callback ownership. In v2 mode, emit standard session/update frames only to the v2 stream; never also yield a v1 event or apply v1 normalization to that payload. Inactive streams finish so a consumer cannot wait for a mode that will never deliver.

The v2 watermark counts deliveries once in receive order, including a delivery whose params later fail semantic decoding. V1 fan-out retains its current per-normalized-update count. This changes no production runner drain behavior because production remains v1.

ACPConnection must reject a configured client update mode that differs from its requested/validated selected version before session work. Under the current v1-only selection, a v2-configured low-level client cannot be used through production initialize. Do not send an initialize or enable v2 just to make the fixture mode reachable. Future downgrade handling must replace a mismatched connection before session work rather than change an active client's decoder.

## V2 delivery and decoding

Introduce a small public Sendable delivery value, recommended name `ACPV2SessionUpdateDelivery`, containing the original full JSON-RPC frame bytes, a fixed client connection-instance ID, and a deferred consumption handle. Copies of a delivery share the same single-use consumption authority. The client exposes its connection-instance ID as a stable read-only value so a future owner can be constructed before notifications arrive.

The delivery provides a pure `decode()` entry point using `LSPJSONValue.decode(from:)` and `ACPV2SessionUpdateEnvelope.init(rawValue:)`. Do not use JSONDecoder, AnyCodable, or JSONSerialization to reconstruct its params. Validate JSON-RPC notification shape, `jsonrpc: "2.0"`, `method: "session/update"`, absent id, and required object params before returning a typed envelope. Original frame bytes and exact opaque number tokens remain available even if semantic decoding fails. Unknown v2 variants retain their raw envelope and produce an unhandled owner reduction as before.

The client recognizes the session/update method and yields one raw delivery without first interpreting its params. If the exact parser rejects the full envelope but a method-only read can still identify it, retain the same raw delivery for explicit decode failure. That fallback never interprets IDs or reconstructs params, and cannot enter the v1 normalizer. Missing/null/wrong-shaped params and malformed required/interpreted v2 fields therefore produce an explicit decode error for the consumer, not an empty success, v1 fallback, silently dropped update, or automatic consumption. A session/update carrying an id is also delivered as an invalid notification to diagnose explicitly. In v2 mode, inspect the raw object/method before generic head routing so a malformed or non-Int id cannot hide an identifiable session/update; genuine responses retain existing request-ID matching. Completely malformed JSON for which no method can be read retains the existing framing/error policy; this slice does not add a general protocol-error bus.

Decoded session IDs remain part of the envelope. A consumer constructs/passes the owner's immutable context using that session and the delivery's actual client-instance ID. Do not mint a fresh context for each frame, relabel an old delivery with a new connection ID, infer live/snapshot provenance from content, or use model application as proof of durable storage.

## Consumption, order, and shutdown

Yielding, iterating, decoding, or applying a delivery to ACPV2SessionState must not invoke its consumption callback. Unknown and malformed deliveries keep the same deferred authority. The future consumer must explicitly decide what has been durably handled; this design installs no automatic durability policy.

Expose explicit `acknowledgeDurableConsumption()` on the delivery. Use a small thread-safe single-use handle so repeated calls and copies invoke the original callback at most once. Invoke callbacks outside internal locks. The handle represents only this source frame; it must not advance any later frame, target a replacement transport, or invent persistence.

Retain per-client receive order. Holding an earlier delivery unacknowledged must not be bypassed by client-side automatic acknowledgement while a later delivery is decoded. This does not introduce a stdio journal or broker cursor ordering: the underlying transport still owns how its frame callbacks fence offsets. Do not synthesize durable support where callbacks are absent.

Finish the v2 stream on exit/shutdown along with existing streams. New v2 deliveries must not appear after termination is observed. Do not automatically acknowledge buffered/outstanding v2 deliveries during shutdown, decode failure, consumer cancellation, or stream termination. A new client gets a distinct connection-instance ID; stale deliveries cannot mutate its owner when presented with their original context. Low-level clients are single connection instances, with no decoder reset or restart/rebind API added here.

## Successful response extraction

For successful JSON-RPC responses, extract the result value with the same exact raw JSON parser/writer used by the canonical v2 models. Preserve unknown fields, large integers, exponent tokens such as `1e999`, and object/array/scalar/null results. Re-encoding may normalize whitespace and object-key order; numeric token spelling must remain exact.

Keep missing result distinct from a present null result. Preserve exact request-ID matching, one-time pending-continuation settlement, deferred ACPResponse consumption, handoff behavior, and established JSON-RPC error precedence. Do not run result values through generic Codable or Foundation serialization on the extraction path.

This result-extraction correction also applies to current v1 clients, whose known decoded response semantics stay unchanged. JSON-RPC error responses still use the existing typed error path; lossless arbitrary error-response data and outgoing parameter serialization are outside this slice. Do not claim all JSON-RPC payloads are now lossless.

## Validation and acceptance

Use Swift Testing, existing in-memory transport fakes, event-driven coordination, and bounded fixture helpers. Extend the existing stdio/connection suites before creating scenario-sliced sibling files. Put pure new delivery-codec tests in AlasCore if they earn a separate suite. No sleeps, real adapter subprocess, or manual permission prompts are needed for new cases.

- Prove full raw JSON-RPC v2 frames reach the typed envelope and session owner with opaque numbers/metadata intact, mixed entity ordering preserved, and explicit caller-supplied state provenance. Parsing and model application leave the callback untouched.
- Pin mode exclusivity, unchanged default-v1 fan-out/watermarks, one count per v2 delivery, and connection initialization rejecting a decoder-mode mismatch before request handoff. No Debug preference or adapter eligibility change is permitted.
- Preserve unknown and malformed deliveries with original bytes and deferred consumption. Invalid params, invalid notification id, and known-shape decode errors cannot create owner state or trigger v1 fallback.
- Copy and acknowledge the same delivery from concurrent tasks; its callback runs exactly once and can safely reenter without a held handle lock. A missing callback creates no fictitious durability.
- Verify exit/shutdown finishes the v2 stream, does not consume outstanding deliveries, rejects late delivery, and gives a replacement client a different context. Old-context application remains stale.
- Check successful response extraction for object/array/scalar/null, missing result, huge/exact numeric tokens, request-ID routing, deferred response consumption, and existing error handling. Retain existing handoff/cancellation tests without broad unrelated refactoring.
- Run affected AlasCore suites first, then focused `ACPStdioClientTests` and `ACPConnectionTests` in the app target with isolated DerivedData and required macro/plugin flags. Inspect actual suite/test counts. Run full SwiftFormat lint and whitespace checks. Classify unavailable app build infrastructure honestly; a process exit without the selected test count is not a pass.

Obtain one independent final code review. Update the umbrella with direct-stdio fixture evidence separately from pending broker/SSH, persistence, and live-adapter validation. Keep all production selection v1.

## Choices left to the builder

The immutable mode, exclusive v2 delivery stream, raw full-frame delivery, explicit single-use consumption, exact successful result extraction, and production mismatch guard are design recommendations. Exact type/property names, handle implementation, helper placement, and small code deduplication choices are left to the builder. Reuse the existing raw JSON codec; avoid a new general transport framework, a second parser, a second mutable session owner, or automatic ACK on error.
