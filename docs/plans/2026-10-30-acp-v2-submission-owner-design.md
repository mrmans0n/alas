# ACP 2 durable prompt submission ownership

## Intent and boundary

Continue umbrella #2213 after submission ledger PR #2269, merged as `43e0db9f08e1303b692a66d1332652e3599ce9b4`. Work on `nacho/acp-v2-submission-owner` from that merged main, preserving unrelated Ghostty and adapter research changes.

The ledger currently requires an actual wire binding, but stdio allocates its request ID inside send and exposes no async persistence boundary. The ordered update owner has canonical state but cannot register or accept prompts. This chunk connects these contracts: reserve a real binding, commit registration before dispatch authorization, retain the raw outcome before consumption, and apply the decision through the same canonical owner that receives updates.

Production remains v1-only. No manager/runner installation, queue advancement, UI projection, automatic retry, reserved hook-error retry, pending adapter-request recovery, permission answering, remote cancellation policy, upstream resume, SSH changes or adapter publication. A fixture-capable sender/owner path is the deliverable. Acceptance remains insertion evidence, never foreground completion.

## Architecture choice

Extend ACPV2SessionUpdateOwner as the one canonical state owner. Preserve its existing name and update-only initializer/start path for callers that do not enable submission persistence. Add an explicitly configured submission capability rather than silently introducing ledger I/O into every existing owner.

A configured owner restores current-source submission registrations and outcomes before replaying the update journal, then accepts explicit live submission calls once restoration is complete. It uses the existing ACPSessionPersistence actor through a small submission-persistence protocol for event-gated testing. No second mutable transcript/lifecycle owner, duplicated shadow state, or general effect queue is added.

Add a separate, additive v2 prompt-preparation protocol in AlasACP, implemented by the concrete stdio and broker clients. Its prepared identity lives in AlasACP and is converted explicitly to the ledger binding in AlasSessions. Do not import AlasSessions into transport code. Keep the existing ACPClient.send and ACPRequestHandoffPreparing contracts unchanged for v1 and existing callers.

These are my implementation choices. The exact additive API names and placement are builder choices, subject to the ownership and ordering contracts below.

## Real preparation before handoff

The new transport method only accepts explicitly selected v2 `session/prompt` requests. It must not fall back to the generic ACPClient default handoff implementation or the v1 ACPConnection.prompt hook-review wrapper. Require an explicit operation key for broker attempts; never synthesize another key when recovering an uncertain attempt.

Its immutable prepared value exposes method, connection UUID and one binding:

- Stdio reserves the actual next signed/string JSONRPC ID under the existing allocator lock and encodes that exact request before invoking preparation. The reserved ID is consumed even if preparation later fails. It must never be reassigned to another send.
- Broker captures its actual active broker ID/generation, connection UUID and the supplied operation key before invoking preparation. The helper's UInt64 adapter request ID remains unavailable until the outcome and must not be invented. The later service.send uses exactly that captured operation key and generation.

The transport awaits a throwing async preparation closure before installing/dispatching the outgoing call. The closure lets the canonical owner commit registration and register the returned local sequence in its model. Encoding or preparation failure grants no handoff authorization. A cache result is not a prompt outcome and cannot satisfy this method.

After preparation, recheck task cancellation and transport lifetime/generation. The owner supplies a per-attempt thread-safe handoff gate, invalidated synchronously by stop or cancellation. Immediately before transport enqueue or the broker service invocation, the transport atomically claims this gate once. Failure to claim prevents dispatch. There is no await between a successful stdio claim and its synchronous enqueue. Broker claim precedes invoking its async service call with the fixed request.

The claim is the local point of no return, not proof of bytes written or upstream insertion. Cancellation before claim prevents dispatch; cancellation racing after claim leaves the attempt uncertain and does not prove it was never sent. Do not hold a gate/state lock while invoking caller callbacks or awaiting I/O. Do not promise a transaction across SQLite, a claim and remote delivery.

A stopped/replaced transport after preparation cannot reuse the prepared identity on a new connection. A stopped owner invalidates every unclaimed gate and cancels its owned tasks. isCurrent is checked on the canonical owner's executor before preparation and after every persistence/transport await; observed ownership loss invalidates its gates. Replacement integration must stop the old owner rather than treating a predicate alone as an atomic remote revocation mechanism.

The new stdio path must install and remove its pending continuation exactly once across response, synchronous send failure, shutdown and caller cancellation. Cancellation before installation must not leave a late pending entry. Cancellation after dispatch removes only that call; a late response stays raw diagnostic evidence and cannot settle a replacement request or be consumed automatically. This adds no wire cancel notification.

The broker path preserves its existing same-operation pending polling and exact completion selection. It makes one logical call for this attempt and never converts an RPC error, observation loss or stale completion into another prompt attempt. Existing v1 and special hook-review retry behavior remain untouched outside the new path.

## Live submission on the canonical owner

A submission call supplies an explicit fresh submission UUID, optimistic local-row UUID, `session/prompt` request for this owner's upstream session and the configured v2 sender. Reject a wrong upstream session, mismatching sender source/connection, duplicate active submission identity, non-live owner or unsupported sender before dispatch. The sender identity must match this owner's immutable attachment; it cannot be supplied as an unrelated client with a plausible request ID.

The request's params must be a typed prompt value whose upstream session ID can be checked directly. Do not authorize arbitrary Encodable params by guessing their JSON shape. Reuse existing prompt schemas/encoding where compatible; outgoing opaque-JSON encoding changes are outside this slice. Generate no automatic retry and perform no trust/auth review loop.

Within preparation:

1. Validate current owner and the actual prepared binding against the attachment and requested method.
2. Await lease-fenced ledger registration using the caller's submission/local-row IDs and actual binding.
3. Recheck owner/task/gate validity. Register the ledger's positive local sequence in the latest canonical state, not a copy captured before the await.
4. Publish the correlation observation and let the transport proceed to its own lifetime check and handoff claim.

An echo may arrive before an acceptance response; existing exact-message correlation must handle both orders. Concurrent distinct submissions are permitted, including identical content and reversed responses. Their transport IDs, local sequence, local rows and task/gate ownership remain separate. No task may overwrite a newer canonical state snapshot after awaiting storage.

On a returned response or raw RPC error, obtain its original ACPRawRPCDelivery and validate it against this exact prepared attempt. Await fenced outcome retention. A missing raw delivery or source-less transport error cannot become fabricated outcome evidence. If registration committed but no valid receipt returns, retain that registration as uncertain and do not resend.

After a committed receipt, recheck current ownership and apply its record to the latest canonical state. An accepted record calls existing atomic register/accept correlation for its exact local sequence. Duplicate receipt/application is idempotent. A conflict leaves existing canonical facts unchanged, blocks this owner and leaves the live handle unconsumed.

A valid RPC failure marks only this submission uncertain, preserving its factual failure record and any existing accepted binding. It does not call reject or alter foreground observation. Add a narrow per-submission uncertainty decision to the existing lifecycle/value owner if needed; repeated uncertainty is idempotent and accepted/rejected facts cannot be downgraded. Transport loss without a raw outcome also leaves this attempt uncertain. Whole-stream observation loss retains its existing broader semantics.

Uninterpretable bound evidence is already durable but cannot be applied as acceptance. Mark the attempt uncertain, block further dispatch/application on this owner, and retain the original live handle unconsumed for explicit future handling. Known valid RPC failure can return a factual failure result after durable retention and uncertainty publication; it need not pretend the update stream was lost.

Only after storage succeeds, the canonical decision is published and a final owner check passes may the owner explicitly consume the original live delivery. There is no await between that final check and consumption. Loaded receipts never supply a callback. A stop/ownership change during commit may leave a durable outcome for restoration but cannot publish or consume through the stale owner.

Return an explicit per-call factual submission result or typed failure. Latest-only owner observations remain invalidations, not a reliable RPC outcome queue. Preserve the existing observation contract while adding a distinguishable submission-change observation/effects if necessary. Never label acceptance as a completed turn.

## Restoration, stopping and ordering

For a submission-enabled owner, use the ledger's bounded pages for exactly the current local/upstream session and source identity. Broker reattachment to the same generation can restore prior bindings. A fresh stdio connection does not revive registrations from an old connection UUID; historical old-source data stays available through passive APIs.

Register every applicable loaded local sequence/local-row binding and apply retained acceptances before replaying snapshot session updates. Registration-only records and RPC failures restore as uncertain. An uninterpretable stored outcome restores its registration as uncertain and blocks this owner visibly rather than skipping it and claiming complete recovery. Conflicting stored acceptances likewise block without erasing a valid prefix. No restoration path sends a prompt, reconstructs consumption authority, advances helper ACKs or claims upstream resume.

Submission calls are rejected during restoration. Once live, every model mutation runs synchronously on the same canonical executor between awaits. Updates may continue while a submission's storage is in flight; outcome application must use the latest state. Keep lastAppliedOrdinal exclusively about update records. Submission restoration/acceptance never advances that ordinal or mints foreground completion.

Stop remains a synchronous local invalidation. It invalidates gates and cancels managed receive/submission tasks; stale continuations recheck ownership before model mutation or consumption. Blocking on a submission interpretation/storage conflict stops further dispatch and update consumption for that owner while preserving already committed facts. Block is distinct from stop, and neither proves the adapter process stopped. Task completion may still await an uncooperative transport I/O operation; report observation loss honestly rather than promise remote cancellation.

## Acceptance and verification

Extend existing stdio, raw broker, owner, lifecycle and session-state suites. Use event-gated synchronized fixtures and real SQLite for durable boundaries. Do not use fixed sleeps or a real adapter as the primary concurrency test.

- Capture real signed/string stdio ID and broker key/generation in preparation. No transport dispatch while registration is gated, or after rejected registration/preparation, observed ownership loss, pre-claim stop/cancel or detected transport generation replacement. A lease taken after COMMIT cannot atomically revoke an already authorized handoff; no SQLite-to-remote atomicity is claimed.
- A stop racing after claim retains uncertainty and cannot authorize replay. Shutdown/cancel/response races settle only the original continuation; cancelled IDs never settle a later call or auto-consume a late response.
- Concurrent equal-content submissions with reversed responses and echo-before/after acceptance retain distinct local rows. Updates arriving during registration/outcome commits survive in the same canonical state.
- Registration and original outcome are durable before consumption. Stop or ownership loss before/after commit preserves evidence but prevents stale publication/ACK. Real SQL failure, mismatching source and canonical conflict leave handles unconsumed.
- Valid acceptance is insertion only. Valid errors remain uncertain without rejection/retry or foreground changes. Malformed bound outcomes remain durable and block; no raw frame is fabricated for transport-only failure.
- Restore multiple pages of registrations/acceptances before snapshot replay, reconcile local rows in either echo order, preserve uncertainty, and block visibly on malformed/conflicting evidence. Old stdio sources and broker generations cannot become the active attachment.
- Existing update-only owners, update order/ordinal accounting, v1 stdio/broker callers, hook-review paths and production v1-only selection keep their contracts.

Run affected AlasCore suites first, then focused native stdio/connection/broker suites when feasible. Use temporary source-identical import-adjusted app tests only for rapid checks and remove them before native validation. Confirm actual selected counts, full SwiftFormat and whitespace checks, and one fresh final whole-change review. Keep native dependency-cache and Ghostty limitations distinct from passing SwiftPM evidence; do not repair unrelated build inputs here.

## Delivery

After full design approval, use the established inline execution method with meaningful TDD per task and one final review. Keep changes uncommitted until shipping is requested. This document is the only new change before approval; no implementation or tests have been written. A fresh builder check will resolve planning questions before presentation.

## Builder check outcome

One fresh builder check returned "Nothing important left." It found the handoff/cancellation boundary, latest-state mutation across awaits, restoration ordering and durable-outcome-before-consumption contract sufficiently specified for implementation planning. No product code or tests were written during design.
