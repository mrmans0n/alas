# ACP v2 message transcript foundation

Status: approved with `ok` on 2026-10-25. The design review found no important unanswered questions.

## Intent

Continue [umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) after lifecycle foundation [#2221](https://github.com/mrmans0n/alas/pull/2221). Give v2 user, agent, and thought messages their own lossless wire decoding and deterministic transcript state, including exact correlation with locally submitted prompts.

V2 messages are identified entities that can be replaced or appended to. The existing v1 path also uses text matching, replay suppression, and streaming separators. Applying those heuristics to v2 can merge distinct submissions or drop legitimate chunks.

This slice supplies the canonical message reducer and app-facing reconciliation effects. It does not activate a transport handler, install a UI projection, or change persisted transcript rows. That keeps structured v2 content intact without forcing it into the current flattened v1 row codec before the later projection and persistence work is designed.

## Scope

- Separate v2 update-envelope and message decoding, retaining the complete JSON value.
- Whole-message upserts and chunks for user, agent, and thought messages.
- Receive-ordered content and metadata patches keyed by message type and ID within one session.
- Exact local-submission correlation, accepting either response-before-echo or echo-before-response delivery.
- Explicit mutation/reconciliation effects for a later session owner to project and persist.
- Package tests for wire preservation, ordered reduction, and correlation. Live production selection remains v1.

Tool calls, plans, display terminals, notices, compaction, foreground lifecycle integration, UI projection, persistence integration, replay/resume, and adapter changes are outside this slice. Their envelopes are preserved as unhandled updates. This is another partial step in workstream 3, not completion of live v2 transcript support.

## Wire contract

Use an explicit v2 entry point. Do not guess a version from update shape or add v2 cases to the existing v1 `ACPSessionUpdate` decoder. The v2 notification envelope retains `sessionId`, its raw `params`, and the raw `update` object so future fields and notification-level metadata survive a decode/encode round trip. JSON-value equality is the round-trip contract; byte-for-byte key ordering is not.

Recognize the six message variants: `user_message`, `agent_message`, `agent_thought`, and their `_chunk` variants. Each requires a string `messageId`. Validate known discriminators and container shapes; missing, null, or non-string required fields are errors, not unknown variants. Unknown string discriminators retain their whole object and produce no message mutation. A known variant with an invalid payload remains an explicit decoding failure; its original input remains available to the caller rather than being reclassified as an unknown update.

For whole-message `content`, distinguish omission, explicit null, and a concrete array. For chunk `content`, require one content-block object. Preserve each block as structured JSON, including unknown types and fields; do not pass it through the v1 content decoder or flatten it to text. Require a string content-block discriminator, leaving rendering-specific interpretation to the later projection layer.

The entity `_meta` on whole-message updates is an omitted/null/object patch. Chunk `_meta` and notification `params._meta` are scoped to those individual objects and never patch message metadata. Keep their raw values with the decoded event. Reject malformed known metadata containers instead of coercing them to empty objects.

## Canonical message state

Place public, UI-free values in the existing `AlasACP` package target. A reducer instance belongs to one immutable session/connection context. Request tokens and update inputs carry that context; a mismatch produces an explicit ignored/conflict result without mutation. This prevents a response from a replaced connection from binding a new request that reused an integer ID. No transport, clocks, persistence, or UI callbacks belong inside the reducer.

Keys include message type and `messageId`; the same ID can identify a user, agent, and thought message independently. The canonical transcript contains only upstream message entities. Local optimistic placeholders are registered by opaque local row handles, not inserted into this upstream entity list.

The first update or chunk for an entity creates it with empty content and metadata before applying its fields. Preserve first-observed upstream entity order. Updating an existing entity never moves it. Neither local submission order nor prompt-response order establishes upstream message order.

Apply content in receive order:

- Omitted whole-message content leaves current content intact.
- Null or an empty array clears it.
- A concrete array replaces all prior content, including previous chunks.
- Every chunk appends its block to current content. Equal consecutive chunks both remain; there is no text-based or payload-based chunk deduplication and no invented separator.
- Repeating an identical whole-message replacement leaves one entity with the same content. This does not grant transport replay deduplication.

Apply whole-message metadata one top-level key at a time. Omission preserves it; null clears it; an object patches it. Omitted keys remain, null keys are removed, other values replace the entire value at that key. Do not deep-merge nested objects. An empty object is a no-op, not a clear. Content replacement does not implicitly reset metadata.

Retain structured content and effective metadata in the canonical state. Every reduction result also exposes the original lossless event for the eventual durable/proxy owner. Unhandled event payloads are available through that event; do not invent patch semantics for their unknown fields. This slice does not claim durable retention of events or v2 snapshots, and it must not make an adapter eligible for live v2.

## Exact prompt correlation

The session owner registers a local request token and the opaque handle of the user row it already created. The handle is enough; user text, attachments, pasted spans, delegated provenance, and other display metadata stay with the owner. Never infer a request-to-message association from text, arrival order, foreground state, or a neighboring row.

Pass confirmed acceptance from the exact awaited prompt request, using the existing `ACPV2PromptAccepted` result and its request token. The lifecycle owner still owns pending/accepted/rejected/uncertain status and foreground decisions; this reducer owns only transcript identity and association.

- **Response first:** remember the binding between this local row and the accepted user-message ID. Acceptance alone creates no upstream entity and does not seed canonical content with the optimistic text. The first actual echo supplies authoritative content, so streamed echo chunks cannot append to a second copy of the optimistic prompt.
- **Echo first:** create the user entity from that echo without guessing which local submission it represents. When its exact response arrives, bind it to that submission and emit a reconciliation effect identifying both the local row handle and the already-observed entity. Do not append another canonical entity.
- **Identical submissions:** distinct registered request tokens and distinct returned IDs stay distinct, even when text and attachments match and responses arrive in reverse order.
- **Repeated acceptance:** the same binding is a no-op. A changed ID for an already-bound request, or a second request claiming an already-bound user entity, reports a conflict without overwriting the first binding or changing unrelated entities.
- **Missing registration or wrong context:** report an unmatched/stale acceptance without mutating current bindings. Do not attach it to the next pending request.

Reconciliation effects give the future projection owner enough information to keep the local row UUID and local-only metadata, remove only its corresponding optimistic placeholder, and render the authoritative entity at its first-observed upstream position. If it was already projected as an echo row, that row is replaced rather than duplicated. Acceptance before an echo leaves the optimistic row visible until the first authoritative update arrives. This slice tests the identities and effects; it does not perform those UI or database mutations.

Rejection and lost observation do not remove arbitrary upstream entities or trigger resubmission. The lifecycle model continues to describe uncertainty. A new connection context starts a new reducer; cross-generation recovery and restoring bindings require the later persistence design. Acceptance never finishes foreground work, advances a queue, acknowledges durable delivery, or proves model consumption.

## Existing behavior and boundaries

Reuse the concepts behind `ACPMessage.StableIdentityKey` and `ACPTranscript.TextMessageKey`; do not change their existing v1 behavior. The v1 `appendUserChunk`, replay-fragment suppression, and legacy echo reconciliation stay on their current path. No v2 event enters those helpers.

Do not change `ACPMessageCodec`, `ACPMessageWire`, stored message kinds, hydration, `restoreQueue`, the snapshot-consistent delivered-prompt calculation, broker acknowledgments, or lease ownership. Connecting the new state to those owners is explicitly later work. Keep the Debug flag disabled by default and live v2 eligibility empty.

## Validation and acceptance criteria

Use Swift Testing in AlasCore, with one suite for the new coherent reducer/decoder behavior rather than scenario-specific sibling files. Parameterize variant and field-shape cases. These are deterministic values and ordered inputs, so no sleeps, subprocesses, or app build are needed.

- Decode/encode preserves unknown envelope, update, content, chunk, and notification fields. Unknown variants survive; malformed known required fields fail explicitly.
- Content traces cover chunk, replacement, chunk, omitted content, explicit null, and empty arrays. Equal chunks both append. Agent and thought entities with the same ID remain separate, and the same message ID in another session context cannot mutate this transcript.
- Metadata traces cover omission, empty object, top-level removal, nested-object replacement, full clear, and content replacement without metadata reset. Chunk metadata never becomes entity metadata.
- Both response/echo orders resolve to one upstream entity and the exact local handle. Two identical submissions with reversed responses bind correctly. Repeated acceptance is harmless; conflicting and stale acceptances leave valid state intact.
- Acceptance without an echo creates no canonical message or completion effect. Foreground and queue behavior remain outside this model.
- Run the new reducer/decoder suite and the existing package lifecycle and protocol-negotiation suites. Existing app message-identity suites need an app run only if implementation changes their source or behavior; the proposed package-only boundary does not require one. Inspect actual counts and run `git diff --check`. No full local test plan; no live adapter compatibility claim.

Keep the work local until a separate shipping request. Preserve the pre-existing untracked research note.

## Evidence and implementation choices

The new branch `nacho/acp-v2-message-transcript` starts at merged main `3b1dfc8cb96f3405edda8c53e156408714673526`. Current code already keys transcript text indices by type and message ID, while `ACPSession.appendUserChunk` uses legacy content-based reconciliation. `ACPMessageWire` and the message codec store flattened user/agent/thought content, which motivates keeping the canonical structured state separate in this slice.

The chosen boundary, a canonical reducer plus reconciliation effects before UI/persistence integration, is an implementation recommendation. Exact type names, whether the key is a struct or enum, and the effect representation are left to the builder. Public APIs must remain small and expose observable outcomes rather than internal dictionary layout.

Protocol sources use the same revision pinned by the umbrella:

- [Entity identity, insertion, and message patches](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/prompt-lifecycle.mdx)
- [Metadata patches and unknown fields](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/extensibility.mdx)
- [Structured content](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/content.mdx)
