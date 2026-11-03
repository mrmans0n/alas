# ACP v2 inbound request decisions

## Intent and scope

Continue #2213 after session projection PR #2339 merged at `16ed77f6679dbf3b1d4b176cbd3bb1fc3add9888`. Add the package layer that turns retained inbound captures into typed, attachment-bound decision handles and turns explicit decisions into durable exact responses. This closes the gap between passive request offers and a later application runner's interaction policy.

The user accepted typed interactive requests, explicit current-request decision handles, answer validation, cancellation/ownership invalidation, and no duplicate or stale writes. My scope decision is session-scoped permissions and form/URL elicitation, plus individual cancellation and URL completion notifications. Request-scoped pre-session/auth interaction is decoded and preserved but not handled by this session-bound coordinator.

Production remains v1-only. No application manager/runner installation, permission/form UI, browser opening, filesystem/command execution, automatic approval/remembered policy, auth execution, outgoing session/cancel/session/close, queue advancement, resume/adoption, schema migration, live adapter or SSH qualification. Preserve unrelated Ghostty/research. Do not update #2213 without separate explicit authorization.

## Contract version and deliberate boundary

Use the selected inbound request/response and individual cancellation contracts at ACP source commit `0e486bcd6a5ec97bcb31bc97c360996f7f2dc6a7`, resolved and fetched during design on 2026-11-03:

- [v2 schema](https://github.com/agentclientprotocol/agent-client-protocol/blob/0e486bcd6a5ec97bcb31bc97c360996f7f2dc6a7/schema/v2/schema.json), blob `01fc80f2b9c110ddd0a5785e0527dc07e9bf9985`.
- [Permission requests](https://github.com/agentclientprotocol/agent-client-protocol/blob/0e486bcd6a5ec97bcb31bc97c360996f7f2dc6a7/docs/protocol/v2/tool-calls.mdx#requesting-permission), blob `db944fc1486bc17d2d91da13c0be7b9700b9e127`.
- [Elicitation](https://github.com/agentclientprotocol/agent-client-protocol/blob/0e486bcd6a5ec97bcb31bc97c360996f7f2dc6a7/docs/protocol/v2/elicitation.mdx), blob `c48314223945ccb8a55ca509a9e1c65739ce4e1e`.
- [Cancellation](https://github.com/agentclientprotocol/agent-client-protocol/blob/0e486bcd6a5ec97bcb31bc97c360996f7f2dc6a7/docs/protocol/v2/cancellation.mdx), blob `5daf20d4b40f5556fd9733e564e43ae8a0f072ba`.
- [Errors](https://github.com/agentclientprotocol/agent-client-protocol/blob/0e486bcd6a5ec97bcb31bc97c360996f7f2dc6a7/docs/protocol/v2/error.mdx), blob `82989229078956175ca80671562c7a8264027767`.

This is a targeted contract pin, not a wholesale update of earlier v2 setup/update/lifecycle schemas. Compared with the earlier `41c6a98...` baseline, elicitation content now explicitly preserves arbitrary JSON values, request cancellation matches the sender's request direction, and the current contract no longer requires blanket permission cancellation merely from sending session/cancel. Do not copy the older blanket rule into this layer. Background-work/session cancellation integration stays deferred.

## Existing authority

`ACPV2InboundReceiptOwner` already retains raw captures before consumption and invokes synchronous callbacks for received captures, not for passive historical replay. `ACPV2AttachmentRuntime.Request` holds an opaque current epoch and the original capture. `ACPV2ResponseOwner` commits one immutable reply intent per retained origin, commits an attempt before handoff, and records typed transport facts. Its existing recovery gates prohibit uncertain replay or replacing a chosen reply with different bytes.

Keep these components authoritative. The new coordinator must never construct reply authority from a ledger row alone, use the v1 permission/elicitation streams, send directly to a transport, acknowledge a receipt itself, or interpret an absent outcome as not-written. There is no SQLite/pipe atomicity or cross-process exactly-once claim.

## Reliable inbound integration

Add an optional synchronous throwing MainActor inbound callback to the runtime, forwarded by bootstrap before startup. It sees each validated, committed original non-update capture, including notifications, with its retained record and provenance. It does not compete for an AsyncStream or depend on latest-only observations. Existing onRequest remains available for callers not installing this coordinator; document that one decision authority owns each request and the two callbacks must not independently answer the same origin.

The callback classifies requests and handles notifications in inbound-retention order. It must distinguish original current captures, copied duplicate captures and diagnostic adaptations. Diagnostic bytes can be reported but never create decision authority. Historical records loaded without a current capture do not mint handles. Broker pending-snapshot captures may bind the current exact pending origin even when the retained record was inserted on an earlier attachment.

Requests may be retained/offered during restoration. A user decision submitted while runtime readiness is false returns a correctable notReady error and leaves the slot pending; it is not buffered, does not create a durable intent, and does not beat a later cancellation. After readiness, the caller must explicitly submit again. A remote cancellation can withdraw and claim a pending handle while restoring; its protocol cancellation response waits for readiness and fresh reconciliation, rather than dropping the cancellation or fabricating permission to write. No new global order is claimed between independent session-update and inbound streams, or the diagnostic fan-in.

Forward an optional synchronous runtime lifecycle callback for ready/terminal transitions, installed before runtime.start. The coordinator must not consume the runtime.observations stream already used by bootstrap. Read actual runtime status before draining a queued cancellation, and recheck ownership after every external lifecycle callback. A two-phase binding may connect the coordinator and runtime before startup without a retain cycle. A reentrant stop during a startup/lifecycle callback prevents the next child startup or dispatch step.

Reentrant callbacks are authority boundaries. After classification/presentation callbacks, recheck coordinator epoch, runtime ownership and request state before scheduling a response, publishing success, or allowing receipt consumption. A thrown coordinator callback uses a typed runtime failure and withdraws sibling authority synchronously, as projection failures do. Stop settles local waiters promptly without waiting for blocked persistence or I/O.

## Typed interpretation

Put v2 wire interpretation in AlasACP, orchestration in AlasSessions. Use LSPJSONValue and original bytes, not AnyCodable/Double round trips or the lenient v1 request types. Preserve opaque IDs with byte-sensitive comparison where identities are indexed; string versus integer IDs are distinct. Existing parser qualification limits remain explicit and are not solved by this slice.

Classify each envelope as a supported request, supported notification, malformed known payload, unsupported method/mode/scope, or opaque diagnostic. A notification never gains a reply ID. A known method with malformed required fields cannot become an ordinary interactive request. Unknown fields and future variants remain available as raw evidence.

### Permissions

`session/request_permission` requires sessionId, title and a nonempty options array. Require exact-unique option IDs. Each option has optionId/name/kind; unknown kinds remain display hints and never mean approval. Description and subject are optional/nullable. Parse tool_call and command subjects separately, preserving unknown subjects. A command subject validates native absolute cwd and displays command context only; choosing an option authorizes the agent, not client command execution.

The supported decision is selected(exact offered optionId) or cancelled. Missing/foreign/duplicate option identity is rejected before persistence or transport. Do not infer remembered approval scope from allow_always/reject_always. Preserve option and subject metadata without changing canonical tool titles/content.

The newer contract requires applying a tool_call subject to stored tool state before an actual prompt is displayed, in wire order relative to updates. This package coordinator does not display prompts or claim that cross-stream projection integration. It exposes the typed subject to the later runner, whose ordered subject application remains a prerequisite for production presentation. Do not silently apply it through a v1 reducer here.

### Elicitation

`elicitation/create` requires explicit mode and message and exactly one non-null sessionId or requestId. A session-scoped request must match the bound upstream session. Request-scoped interactions require proof of an unanswered client-to-agent RPC on that connection, which this coordinator does not own; classify them as unsupported context and expose no ordinary decision handle. Never reinterpret requestId as an inbound ID or current foreground generation.

Known form mode retains requestedSchema as raw typed JSON. Known URL mode requires elicitationId and a URI string, preserving the full original URL; no URL is prefetched, opened or marked completed by this layer. Unknown modes stay unsupported, not form by default. Caller-supplied local support settings distinguish a wholly unadvertised method from an unadvertised mode; this slice does not change initialize capabilities or advertise incomplete support.

Decisions are accept(content), decline and cancel. Content is omitted/null or an object mapping property names to arbitrary LSPJSONValue values, including nested objects, arrays, nulls and opaque numeric tokens. Emit only the chosen known action; never coerce arbitrary values through the old restricted ACPElicitationValue enum. Decline/cancel omit content. URL accept omits content and means consent only.

Answer validation has two levels: enforce the exact response wire shape and origin/method binding unconditionally; for form content, run a synchronous pure validator against the exact retained schema and proposed content. Provide a default conservative validator for flat known primitive/enum schemas and a caller-injected validator for supported custom schemas. Validation returns valid, invalid or unsupported. Invalid/unsupported acceptance is a correctable local error while the handle remains pending and writes nothing; decline/cancel remain available. Do not report valid when an unsupported constraint was skipped.

The default supports required property membership, primitive types, string enum/oneOf, string-array choices and declared supported bounds. Enumerate its supported keywords in the implementation plan. Unknown optional properties can be omitted. Unknown required types, missing required definitions, simultaneous enum/oneOf, or unsupported constraints make acceptance unsupported. Do not implement a general JSON Schema engine. In particular, do not silently treat ICU regex as ECMA-262 or use rounded floating-point comparisons as exact numeric validation; classify an unimplemented constraint as unsupported. Arbitrary JSON round-tripping remains possible through a supplied validator that understands that custom schema. Defaults are metadata, never automatic answers.

## Coordinator identity and public decisions

Create one explicitly installed MainActor request-decision coordinator per runtime attachment. Public handles contain a private coordinator nonce and an exact retained-origin key. Method payload/raw evidence is inspectable, but callers cannot construct a valid handle from IDs. Index pending state by origin, not just JSON-RPC ID or toolCallId. Record the runtime epoch/source/generation and broker origin cursor where present.

State distinguishes pending, choosing, response in progress, withdrawn, and resolved/uncertain outcomes. Validate the handle and answer synchronously before the first await. The first valid decision claims the local slot before starting persistence. Later calls with that handle either inspect the same stored result or fail as already chosen; they cannot create another operation key or write. A wrong answer is correctable and does not claim the slot. A persistence failure after choosing does not reopen it automatically; callers can inspect typed evidence, with any explicit factual-not-written recovery still governed by the existing response owner.

Create one intent UUID, attempt UUID and reply operation key for the claimed decision. Serialize the envelope with the original request ID and typed result/error using the existing lossless JSON encoding path. Pass the original runtime Request to runtime.respond. Expose the response owner's typed receipt or outcomePersistence fact without converting it into semantic success. A written response is not proof that the agent acted on it.

Restored reply intents/attempts do not become fresh interactive handles or trigger automatic sends. If reconciliation discovers already chosen durable state, withdraw the current decision affordance and expose that evidence; never offer a replacement answer for that origin.

## Individual cancellation and races

Observe `$/cancel_request` notifications using required params.requestId. It names a request issued by that notification's sender. Match only inbound agent-to-client requests in this attachment, never an outbound prompt with the same ID. Ignore unknown/already-answered IDs without another response. Do not preserve an unqualified ID tombstone that could cancel a later request reusing it.

For stdio, retain the original inbound sequence when matching cancellation. For broker deliveries, compare same-generation origin cursors: a cancellation may target a pending origin issued before it, but cannot target a later reused ID. If a pending-snapshot capture is delivered after a cancellation already observed from the journal, a source/cursor-qualified cancellation record may withdraw that exact older origin. No passive history record alone creates current authority. If provenance cannot establish the relation, report ambiguity and withhold a new decision rather than guessing.

If cancellation wins while the slot is still pending, synchronously withdraw its public decision handle and claim a method-defined cancellation reply: permission cancelled or elicitation cancel. Send it through the same durable response owner once runtime readiness/current-origin checks permit. This installed cancellation behavior is an explicit protocol policy, not a grant or a fabricated user refusal. Cancellation of unsupported methods has no automatic response policy in this slice.

If a valid decision already claimed the slot, cancellation withdraws further local interaction but does not replace its immutable chosen response. The selected response may finish normally, as the individual request cancellation contract permits, or return the existing uncertain/failed fact. Do not cancel an in-flight selected intent and then attempt a differently serialized cancellation response. The design promises no new stale decision after withdrawal, not reversal of a previously chosen or written response. Test both sides of this synchronous claim boundary and blocked COMMIT/write races.

Stop, replacement or lease/attachment loss withdraws all handles and cancels initiating response tasks through existing response-owner gates. It does not send cleanup responses over a lost attachment, invent not-written evidence or retry under a successor. A lifecycle caller must deliver stop explicitly for prompt settlement while a dependency is blocked; there is no ownership polling loop.

No foreground state is inferred from request arrival, an answer, dismissal, individual cancellation or URL completion. Do not blanket-withdraw requests on idle snapshots, stopReason cancelled, tool status, or session scope. Explicit outgoing session-cancel/close integration and background-work dependency policy belong to the later runner.

## URL completion and errors

Reserve a URL workflow identity when its validated current create request is registered, before user consent or response persistence. Bind elicitationId to the exact connection/attachment and retained create origin. A matching elicitation/complete can therefore be retained even before consent, or while reply handoff/outcome persistence is blocked. It records only the agent's completion observation, not user consent, delivery of the create response, verified external success or foreground completion.

Keep consent decision, create-response transport/durability facts and completion observation as separate fields. Accept claims the original response slot; it does not clear an already observed completion. If response evidence later becomes uncertain, not-written, or outcomePersistence fails, preserve both facts independently. Do not turn the earlier completion notification into a written/durable receipt or automatically retry the originating operation. Decline/cancel withdraws local interaction without rewriting received evidence. No browser, OAuth credential or external side-effect rollback is installed.

Ignore unknown/already-completed notifications and never answer a completion notification. Reject simultaneously outstanding duplicate URL IDs. Because complete carries no create-origin token, reuse of a previously used elicitationId within this coordinator attachment is conservatively unsupported rather than risking a delayed duplicate completing a successor. This is a local safety limitation, not a claim that the protocol forbids sequential reuse. Broker replay completions must also be later than their matched create origin; passive historical records alone cannot establish a current workflow.

Malformed/unsupported requests retain raw diagnostics. Expose explicit protocol rejection actions rather than silently answering during receipt handling. The caller may choose a validated standard error through the same response owner: method-not-found -32601, invalid-params -32602, or cancelled -32800 where appropriate. Distinguish unsupported/unadvertised methods from unsupported modes. Do not fabricate user decline/cancel to represent inability to render. Wrong-session/request-scope handling is a classified routing limitation, not an invented permission dialog. Unknown notifications never receive responses. JSON parse/invalid-envelope response handling is outside this layer because it lacks a validated inbound request handle.

## Acceptance and validation

Use real SQLite-backed response registration and concrete stdio/broker fixtures, with event gates rather than fixed sleeps. Extend existing suites before adding new scenario files. Add one wire suite and one coordinator suite only if these are new owning types.

- Strict v2 permission shapes, exact duplicate option rejection, known/unknown subject/kind preservation, absolute native paths and wrong-session classification.
- Form/URL mode and scope validation, explicit capability distinctions, arbitrary nested JSON/opaque numeric answer preservation, conservative validator failure without any response intent/write.
- Pending request bursts, copied captures and already-ACKed broker pending snapshots create one current handle per exact origin; history/diagnostics alone create none.
- Real post-setup decisions commit one immutable intent and attempt before the concrete write, with exact original ID/result bytes and no second ACK authority.
- Two simultaneous answers, answer versus cancellation in both orders, cancellation during blocked storage/write and duplicate/stale handles produce at most the permitted existing response attempt.
- Numeric/string IDs, equal IDs in opposite RPC directions, reused inbound IDs and broker cancel-before-pending-snapshot delivery never cross-cancel a successor.
- User answers during restoration return notReady without claiming the slot; a later cancellation can win. Cancellation response waits for readiness and exact-current reconciliation, driven by a synchronous lifecycle callback rather than another status-stream iterator.
- Stop/replacement/lease loss and reentrant callbacks settle waiters without late success or successor mutation. No new-key retry of unknown COMMIT/write results.
- URL completion before consent, during blocked handoff, and during blocked/failed outcome persistence is retained independently of response facts. Duplicate/reused IDs, unknown/duplicate completions and optional/background forms cannot fabricate activity or successful delivery.
- Explicit unsupported/error actions use the same durable boundary; notification/diagnostic payloads cannot acquire reply authority. Existing v1 behavior remains unchanged.

Run affected AlasCore suites with nonzero counts, full SwiftFormat and whitespace checks. No native app build unless app changes become necessary, which would be a scope change. Keep fixture, CI and live/published-adapter/SSH evidence separate. The previous projection slice's deferred replay/provenance/local-metadata test matrix remains a recorded gap unless a case is directly exercised by this slice; do not declare it fixed incidentally.

## Builder decisions

Choose API/file names, pure validator implementation details and notification payload layout. Preserve the single owner of each ingress stream. The callback and coordinator construction may use a two-phase binding so the coordinator can be installed before runtime.start without a strong retain cycle. Do not introduce transport authority, a general JSON Schema library, inferred prompt dependencies, a new schema, automatic replays or a production toggle to make the fixtures pass.

## Builder-check decisions

One fresh builder check raised two important questions; both are resolved above without changing the accepted scope. My calls: user answers before readiness are correctable and do not claim a slot; URL workflow identity starts at validated create registration and records completion independently of consent/write facts; lifecycle transitions use a synchronous callback rather than competing for a status stream; same-attachment URL ID reuse is conservatively unsupported because the completion notification cannot distinguish a delayed duplicate. The costs are an explicit user-answer retry after readiness and a diagnosed limitation for reused URL IDs. No product code has been changed.
