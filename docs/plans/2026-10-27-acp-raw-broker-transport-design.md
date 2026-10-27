# Raw broker transport installation

Status: approved with `yes` on 2026-10-27; builder check found nothing important left.

## Intent and fixed scope

Continue umbrella #2213 after merged PR #2240. Baseline: `1176148430eff1402b2e8a5c9b456532e962c2ce`, branch `nacho/acp-raw-broker-transport`. Preserve the pre-existing research note and keep implementation local until shipping.

Install the raw payload contract through helper adapter ingestion, broker state, helper RPC and Swift delivery. Demonstrate exact-byte capture, cached outcomes and replay with controllable fixtures. This is a low-level opt-in transport path, not production ACP2 activation.

Production construction keeps the existing legacy-v1 broker mode. The Debug setting remains default-off and live v2 eligibility stays empty. The current ACPConnection initialize guard must continue rejecting a fixture-only v2 client under the production v1 selection before any initialize handoff.

The broker currently serves local sessions. SSH uses RemoteHelperACPTransport and a separate proc byte-offset path. Do not switch SSH sessions to brokers, change remote leases/proc recovery, deploy helpers to a host, or claim SSH/live-adapter interoperability from helper-RPC fixtures. Do not install the runner, queue/foreground completion, v2 client tools/MCP, UI projection, transcript persistence or resume/replay policy.

## Immutable modes and compatibility

Support two configured broker contexts only in this slice:

- Existing legacy-v1: structured payloads, ACP version 1. Missing context in older metadata means this context only.
- Opt-in raw-v2: ACP version 2 plus payload format `alas.acp.raw-json.v1`. The format's v1 is a wrapper version, not ACP1.

Use a public shared wire-context value in the Swift platform protocol and Rust protocol/state. Exact type names are builder choices. Reject unknown versions/formats/combinations. Store the configured context in launch data and generation metadata, return it in snapshots and expose it in the client's durable-state callback. Configuration is immutable for a generation and for a client instance; it is not proof of completed ACP negotiation. No raw-v1 mode or mutable decoder setter is added.

Introduce helper capability `acpRawFrames: 1`, meaning only this raw transport contract. Missing/unknown capability is unsupported. Capability checks must be tied to the current helper connection generation and refreshed after reconnect.

Use distinct public RPC methods `acp/raw/open`, `acp/raw/attach`, `acp/raw/send`, `acp/raw/notify`, `acp/raw/respond`, `acp/raw/ack`, `acp/raw/detach`, `acp/raw/close`, and `acp/raw/list`. Raw calls require the raw context; internally fence raw IPC operations as well. This is intentional protection against older helpers/supervisors silently ignoring an added field on an existing method. Keep existing `acp/*` methods unchanged for legacy-v1 traffic. A missing raw method is an actionable incompatibility, never a fallback to legacy RPC.

Before adoption/attachment, compare requested context, actual metadata and generation. Validate every returned snapshot before publishing frames, updating cursors/caches, emitting durable-state callbacks or running legacy replacement/cleanup logic. Mismatched raw/legacy/version context fails without initialize, ACK, close, restart, cursor reset or decoder reinterpretation of the running broker. Do not reuse the existing todo-snapshot restart path to force a mode change. A late mismatched open must not authorize cleanup of another mode's generation.

Raw recovery carries its expected generation into open as well as attach. If an expected generation is unavailable or differs, return observation loss without creating a replacement, resetting the old cursor or retrying an old operation key. If an existing raw generation's adapter/supervisor has died, do not follow the legacy automatic close-and-respawn branch for that broker ID, even when its context matches; report the loss and retain available evidence. Creating a fresh raw generation after that loss requires a deliberate fresh broker identity/recovery decision outside this slice. Fresh raw opens with no pre-existing generation may create a generation normally. This policy is my recommendation to prevent possibly accepted work from being resent by transport recovery.

Raw mutations and ACK/close reject context/generation mismatch in the helper before side effects. Legacy mutation/attachment methods reject raw generations, including old clients that omit context. Legacy list excludes raw generations so an older list decoder is not fed raw-only snapshots. Raw list is read-only and returns only compatible raw generations. Do not add a global broker migration or automatically replace an incompatible live process.

Production session persistence does not yet create raw-v2 sessions. Preserve/export context in the low-level durable state for future restoration, and test reconstruction from it explicitly. Do not claim the app's full rollback/resume workflow is installed by this change.

## Capture before interpretation

In raw generations, capture adapter stdout as bytes at the newline framing boundary before converting to String or serde_json::Value. Preserve every byte before LF, including preceding CR; omit only the framing LF. Retain a final unterminated frame at EOF. Invalid UTF-8 and malformed JSON must not silently terminate the reader or turn into a successful semantic event. The legacy reader/policy stays compatible.

Retain each full original frame using AcpRawJSONPayload. A small routing header may read method and bounded/string IDs, plus result/error presence, without decoding opaque params/result/error data as Value. Recommended mechanism: enable serde_json's existing `raw_value` feature and use borrowed RawValue fields. The pinned library source supports deferred parsing and preserved formatting. Do not enable global arbitrary precision, introduce a second general JSON parser, or construct source bytes by re-encoding Value.

Keep absent result distinct from explicit null. Reject ambiguous duplicate routing members and invalid IDs as diagnostic evidence rather than guessing an operation binding. Duplicate keys or extreme numbers inside opaque payloads remain captured. Parse only specific small control fields where broker bookkeeping needs them, retaining the original frame independently.

Every captured raw stdout frame has an ordered journal representation. Readable standard notifications, unknown notifications and malformed/invalid-UTF8 evidence all retain bytes. Invalid/unrouteable evidence is diagnostic delivery, not a synthetic session update, invented terminal outcome, or reason to automatically consume a cursor. A malformed response cannot settle the wrong pending operation or certify prompt acceptance.

## Broker data and caches

Add explicit raw event/payload alternatives rather than inserting a base64 wrapper into a legacy field while calling it structured params/result. Preserve legacy schemas and default behavior; raw-v2 generations use only the raw alternatives for adapter-originated opaque data.

Retain original bytes across:

- Notifications and diagnostics in ordered journal events.
- Operation completion records and immediate/replayed send replies.
- Initialize and remote-session cached responses, including caches exposed in attach/snapshot replies.
- Pending client requests, their snapshot representation, and response-correlation bookkeeping.

The builder may choose separate raw enum cases or explicit optional raw fields, but raw/legacy combinations must be validated against generation context, not guessed from payload shape. Do not double-wrap base64 at successive hops. Caches retain the original response and its operation provenance; a cached response's old adapter ID must not be relabeled as a newly received response. Successful result extraction uses the exact Swift codec, with numeric tokens preserved; transport retention is full-frame exact even when a typed result writer normalizes whitespace.

Errors retain the full raw response, including opaque data. Small code/message/hook-kind projections may be used for existing control decisions without materializing opaque error data. A public raw RPC error must retain the original payload and factual code/message; do not degrade an opaque numeric error into missing-result success. Keep no-execution hook-review rejection classification and retention until the polling send path consumes it. Contradictory control projections/raw frames fail explicitly rather than silently choosing a representation.

Do not expand outgoing ACP parameter serialization in this slice. Controlled client requests/responses retain existing serialization, dispatch handoff and operation-key deduplication. Raw contexts fence those operations but are not a claim of lossless outgoing arbitrary JSON.

The current journal/snapshots are broker-supervisor state, not a new disk transcript store. Preserve existing generation-loss/ambiguity behavior. Reattachment to a surviving supervisor must retain raw evidence; machine/adapter/supervisor death must not invent durable recovery or replay a possibly accepted prompt.

## Swift delivery and consumption

Add immutable broker mode/context to ACPBrokerClient, default legacy-v1. Raw-v2 uses the distinct service methods and exposes sessionUpdateProtocolVersion v2; the inactive v1 update stream finishes. Legacy mode continues its current normalization, fan-out, control requests, counts and ACK behavior.

In raw-v2, recognizable session/update frames go through the merged raw delivery path, before generic ID decoding or v1 normalization. Keep the fixed client-instance UUID and one watermark increment per delivery. Unknown/malformed params remain explicit decode failures with original bytes. Reuse the direct-stdio rule that readable frames rejected by the exact parser must not fall through to v1 or auto-consumption.

Expose other raw inbound notifications, diagnostics and pending client requests through an explicit low-level raw-frame stream. Do not reinterpret v2 pending requests as working v1 client-tool integrations or auto-respond to unknown requests. Preserve pending-request identity/resolution separately from receipt acknowledgement.

Deliveries must carry their actual broker ID, generation and journal cursor/origin alongside the client-instance identity. Preserve whether evidence came from journal replay or a pending-request snapshot; do not label replay/snapshot data as live semantic state. Extend the existing v2 delivery metadata additively if needed so provenance is not lost when session updates use the common stream. Do not create two independently consumable copies or deliver a frame to both an active v1 and v2 update stream.

Use shared at-most-once consumption authority across copies and any delivery projections; callbacks run outside locks. Iteration, decode, owner application, unknown/malformed handling, stream cancellation, detach and shutdown never automatically consume raw frames. All raw journal frames remain protected until explicit durable consumption; a later consumed cursor cannot advance ACK past an earlier protected cursor.

Pending snapshots must retain the real originating event identity/cursor where needed for deduplication. Never invent a new cursor from snapshot acknowledgedCursor. Snapshot receipt alone creates no new durability authority. Repeated attach pages and simultaneous polling/send paths must not duplicate a pending delivery or settle an awaited completion early. Preserve existing pre-registered operation completion protection.

Validate context/generation before publication and before applying deferred callbacks. A stale client, frame, response or late callback cannot ACK a replacement generation. Finish streams on termination and do not publish new raw deliveries after termination is observed. Buffered deliveries retain evidence without gaining authority over another attachment.

## ACP2 activity is not installed here

A raw-v2 generation must not report broker foreground completion merely because session/prompt returned acceptance. Suppress v1-only prompt/steering/cancellation turn-state derivation in this mode and expose an explicitly unknown/unmanaged broker activity state until the later v2 lifecycle integration. Keep factual operation-RPC outcomes distinct from foreground activity. Initial idle, replay and error projections cannot invent a completed turn. Legacy-v1 turn-state behavior remains unchanged.

This guard prevents fixture-only transport support from carrying a false completion model; it does not install queue advancement, completion reports, cancellation ownership or usage accounting.

## Validation and review

Use shared exact-byte fixtures and extend existing protocol/client suites. Add tests before implementation. Run affected AlasCore package tests first; then focused Rust broker protocol/process/crash-recovery cases and app broker/helper-client suites as appropriate. Inspect actual selected counts and classify build infrastructure failures honestly.

Required traces include:

1. Fixture adapter frames with 1e999, large integers, decimal token spelling, Unicode/whitespace and unknown data survive capture, helper IPC, journal replay and initialize/session/operation caches. Pending client requests retain exact source bytes. Verify bytes against independent fixture expectations at both language boundaries.
2. Raw missing/null results, valid errors with opaque data, hook-review rejections and malformed/ambiguous response headers preserve factual outcomes and exact evidence without premature completion or ACK.
3. Legacy helper, missing/stale capability, old supervisor and raw/legacy/version mismatches fail without adapter/session handoff, ACK, close, restart or reinterpretation. Matching generation/context reattachment retains caches and exact delivery. Legacy mode still adopts and runs as before.
4. Earlier unconsumed raw event blocks later ACK, both acceptance/echo orders retain operation protection, repeated attach pages deduplicate, pending snapshots do not mint cursor authority, and late callbacks cannot touch a replacement generation.
5. Invalid UTF-8, duplicate/over-depth JSON, unknown notifications, final unterminated frames and reader EOF preserve diagnostics without auto-consumption. Shutdown races cannot publish afterward. Use events and bounded helpers, not new fixed sleeps.
6. Current production factories/selection still use legacy-v1. ACPConnection rejects a raw-v2 client before initialize under its v1 policy. Low-level fixture acceptance cannot emit completed foreground state.
7. Replay pagination budgets count actual serialized wrapper bytes, including base64 expansion. Oversized-single-event behavior remains explicit and makes progress without truncation or a new limit bypass.

An in-memory fixture is not a published adapter or live SSH result. Helper capture tests should use the real compiled helper/supervisor boundary with a deterministic fixture adapter where that boundary is the behavior being proved; use existing fake services for pure client ordering decisions. No full local app test plan by default.

Obtain one fresh final code review, fix material findings with regression evidence in one pass, and update umbrella #2213 with exact fixture/local results. Do not advertise live adapter compatibility, publish/deploy a helper release, or create a PR until shipping is separately requested.

## Choices left to the builder

These are recommended architectural decisions: legacy-v1/raw-v2 contexts, distinct raw RPC namespace, immutable generation fencing, pre-interpretation byte capture, explicit raw storage alternatives, provenance-aware deferred delivery and suppression of v1 activity derivation. Names and placement of small helpers/types, exact raw event layout, routing header visitor, error projection structure and focused test organization remain builder choices within those constraints. Avoid a new general transport framework or a second mutable session owner.
