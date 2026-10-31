# ACP 2 origin-fenced broker reply handoff

## Intent and scope

The next slice of umbrella #2213 gives the raw broker a factual reply-write contract before a response owner can safely use it. PR #2302 merged at 1a78acdd54d56438026658c04355690189538af1. It orders inbound receipt retention and consumption; neither that receipt nor a restored helper pending ID authorizes a reply.

Today raw and legacy respond share broker_respond. It matches a reusable JSON-RPC ID, removes the pending request and publishes resolution before writing a normalized response. The supplied operation key does not deduplicate replies. An old answer can target a newer request with the same ID, and failed writes can appear resolved.

My scope choice is the broker boundary first: matching Swift/Rust contracts, helper implementation and the concrete Swift raw facade. Direct-stdio reply ownership, durable response intent/current-request reconciliation and a complete response owner are later slices. No production runner, UI, permission/file/terminal execution, adapter eligibility, SQLite migration or SSH interoperability claim. Production remains v1-only. Existing v1 respond behavior remains compatible.

## Public contract and negotiation

Add a separate acp/raw/respondExact helper method and corresponding raw/respondExact supervisor IPC method, rather than extending the meaning of the legacy respond payload. Require a generation-bound acpRawReplies: 1 capability in addition to acpRawFrames: 1. Missing support fails before handoff, with no legacy fallback or helper restart. Advertise it only when the full path is installed. Preserve unknown capability decoding in old clients. Local and remote helper clients share the additive request method, but live remote qualification remains outstanding.

The request carries broker ID, generation, helper pending-request key, original event cursor, explicit caller-supplied operation key, and the existing opaque ACP raw JSON payload wrapper for the complete response frame. Bind the pending key and cursor together; the frame supplies the response wire ID, which must match the original pending request. Do not regenerate an operation key inside a retry or route through the current respondToRawRequest result/error projection.

Add typed Swift params/result and a narrow concrete raw-client entry point. It takes the current client connection ID as an expected attachment fence plus the explicit broker origin/operation/bytes. Check selected raw-v2 mode, current connection, broker identity/generation and cancellation before requesting handoff, and recheck lifetime after capability/transport awaits. A local pre-dispatch invalidation proves no local dispatch only when observed before the request handoff. Once handed off, cancellation or a lost helper reply is uncertain and must not be advertised as not written. The API does not authorize a UI answer, consume an inbound receipt or claim an upstream result.

## Exact frame and identity validation

Before any write or pending-state transition, validate one UTF-8 JSON-RPC 2.0 response object: supported non-null string or signed integer ID, no method, exactly one result or error, and a valid error object if supplied. Reject ambiguous duplicate envelope keys, unsupported IDs, malformed JSON and invalid error fields. Error code is int32 and message is a string; error data and result remain opaque JSON. Use the existing lossless header/parser approaches, never decode the entire payload through serde_json::Value or Foundation JSONSerialization. Opaque exponent numbers and large integers must survive.

The adapter uses newline framing. The complete payload must contain no literal CR or LF bytes, so it is exactly one frame; escaped newline content is allowed. Preserve every supplied byte and append only the transport newline. Reject incompatible multiline formatting before handoff instead of normalizing it. UTF-8 identity strings compare exact bytes, including Unicode spellings and embedded NUL, with existing broker ID restrictions.

Both Swift and Rust validate the envelope. Rust remains authoritative for pending identity and actual write. Validation is interpretation only, not re-encoding. A payload failing validation produces a typed pre-write rejection and leaves the request and write-attempt state untouched.

## Origin and attempt state

Under the broker runtime lock, require current broker/generation/raw context, an open writable adapter and a pending raw request whose exact helper key, original origin cursor and wire ID match. Legacy/notification/diagnostic evidence cannot become a raw request. An old cursor cannot target an ID reused at a newer cursor.

Maintain generation-local reply attempts indexed by explicit operation key, with an origin-to-attempt binding. Each immutable binding includes pending key, origin cursor and exact response bytes. Retain it through ACK pruning and wire-ID reuse until this supervisor generation ends. A repeated key with different binding or bytes is a conflict, never a new write. A second key for the same claimed origin is a conflict too. This is in-memory generation-local idempotency, not crash-durable intent.

Check a matching existing attempt before current pending lookup, so a retry can return its outcome after successful resolution or later ID reuse. It must not mutate or resolve the successor request. A first valid attempt atomically claims the original pending request for one writer. Keep the request identifiable while in flight; other reply paths cannot bypass that claim.

Expose typed outcomes bound to operation key and origin: inFlight, written, writeUncertain. Validation, stale origin, conflict and unsupported contract are typed rejections proving this call did not start a write. An IPC/network failure with no factual result remains uncertain to the caller. There is no automatic resend or polling loop. Retrying the exact operation is a status query once it exists and never repeats adapter I/O.

## Write ordering and failure

Serialize with the existing adapter stdin writer lock. Recheck runtime closing/exited/writable state and origin under the runtime lock after acquiring the writer lock, then claim and release the runtime lock before I/O. Do not hold the runtime state lock across a potentially blocking pipe write. Audit and keep a consistent lock order with close and all other writers; do not add an inverse lock acquisition.

Write the original payload, newline and flush exactly once. Only after all succeed record written and publish the original pending request's resolution. This proves local transport write completion, not adapter receipt, permission execution or model consumption. Preserve the exact response bytes in raw resolution evidence; do not invent a typed result projection. Update raw event/client handling where necessary so the factual status remains interpretable and old raw context cannot silently misdecode a new outcome.

After any I/O starts, failure is conservatively writeUncertain, including flush failure. Do not publish successful pending resolution. Keep the attempt binding so neither the same key nor a new one can resend. Because a partial newline-framed write can poison subsequent messages, mark the adapter writer unusable and reject all later sends/notifications/replies through that runtime; use existing observation/failure reporting without automatic restart. Close remains permitted. Do not infer that retaining pending metadata means the request is still answerable.

Close or adapter exit observed before claim rejects without writing. A close after claim can race I/O; the outcome records only what the writer actually observed. No atomic transaction with remote processing, lease takeover or process death is claimed. A supervisor restart/new generation cannot recover a write result; later durable response intent must preserve uncertainty rather than replay it.

The existing unfenced raw respond method must fail closed on raw-v2 supervisors once this contract is installed, so stale callers cannot bypass origin checks. Keep legacy-v1 respond usable. Retain source compatibility where needed, but never have the new facade fall back to it.

## Tests and acceptance

Use existing Swift protocol/helper/client and Rust broker/protocol/process suites. Add only regressions that pin wire semantics, state ordering or write ownership. Shared fixture cases cover exact raw payloads, null result, opaque numeric tokens, escaped control characters, malformed/duplicate envelope keys, invalid error shape, multiline rejection and mismatch IDs. Existing raw wrapper tests need not be duplicated.

- Reproduce stale-origin ID reuse and premature resolution before implementing the fix.
- Concurrent exact retries perform one write; changed bytes/key/origin fail without writing. Same-key retries after written resolution and ID reuse return the old outcome without touching the successor.
- ACK pruning does not erase attempt identity. New generation cannot reuse an old origin or fabricate its write outcome.
- Event-gated writer tests cover in-flight retries, pre-claim close, close after claim, partial write, flush failure and terminal write poison. Only successful complete writes publish resolution; uncertain attempts cannot resend.
- Concrete Swift facade forwards exact bytes and explicit identity, rejects foreign attachment/legacy/missing capability before handoff, and preserves uncertainty on cancellation or helper response loss. Old raw respond cannot bypass the new contract; legacy-v1 regression remains green.
- No inbound consumption callback, canonical completion, queue action or file/terminal execution occurs.

Run affected AlasCore suites first and inspect actual test counts. Run locked Rust broker/protocol/process tests, using injected writers/events for failure cases and a minimal real process only for the transport boundary. Run affected app/helper routing tests if app files change, otherwise package and Rust checks suffice. Run SwiftFormat and scoped rustfmt/whitespace checks. One fresh final whole-change review and one material RED/GREEN fix pass if needed, no rereview. Keep changes uncommitted until shipping is requested.

## Builder decisions and delivery

Exact names, enum spelling and placement can be settled by the builder within this contract. Prefer adjacent small protocol types and the existing raw payload wrapper. Error codes must be stable and typed, separate from JSON-RPC adapter errors. The write-attempt map has no automatic eviction within a generation; record that memory cost rather than silently weakening deduplication.

This design is the only new tracked candidate before approval. A fresh builder check will examine origin reuse, writer/close lock ordering, status retry semantics and compatibility. After design approval, write the implementation plan and proceed with the established inline TDD workflow. Durable response intent, direct-stdio current request/reply ownership, complete response reconciliation and production integration remain open in #2213.

## Builder check outcome

One fresh Swift/Rust transport builder check returned "nothing important left" after reviewing the proposed contract and current helper/client paths. No product code or tests were changed during design.

## Implementation review notes

The final review's two Important routing/poison issues were fixed with failing-then-passing regressions. Exact reply control calls bypass the ordinary per-broker helper queue/mutex and supervisor FIFO while retaining their origin, generation, attempt and writer fences. Ordinary prompt/cancel ordering stays intact. Writer waiters recheck claimed attempts; poison is rejected before accepting new sends, and registered competing sends receive terminal failure evidence.

Two Minor validator limitations are deferred: Swift rejects distinct canonically equivalent keys inside opaque objects, while Rust's integer parser rejects signed-zero ID/error-code tokens. These can reject otherwise-valid replies before handoff; they do not alter bytes or authorize a write. Resolve the differences before production qualification.
