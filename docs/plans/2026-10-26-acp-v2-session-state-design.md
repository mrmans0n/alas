# ACP v2 ordered session state

Status: approved with `lgtm` on 2026-10-26. Builder check found nothing important left.

## Intent

Continue [umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) after merged [PR #2227](https://github.com/mrmans0n/alas/pull/2227). Message, activity, and foreground-lifecycle reducers now exist, but they have independent state and no common owner. A future transport consumer could bind a prompt in only one model, infer order from separate arrays, or treat acceptance as completion.

Add one UI-free v2 session owner that composes those existing reducers. It accepts already-decoded notifications and exact prompt-response outcomes synchronously, preserves cross-entity first-observation order, and returns ordered effects. It becomes the single target for later live dispatch and projection.

This slice does not install transport dispatch, UI projection, persistent event storage, replay/resume, permission handling, cancellation execution, queue advancement, or adapter eligibility. All live connections remain ACP1 and the Debug preference remains default-off. Keep work local until a separate shipping request.

## Existing boundaries

The branch `nacho/acp-v2-session-state` starts at merged main `ce0093d4929d3460305ac4fb0c40b4f5125ac1d2`. Preserve the pre-existing untracked adapter-support research note.

- `ACPV2MessageTranscript` owns canonical messages and exact request/local-row/user-message correlation.
- `ACPV2ActivityState` owns tools, plans, terminal bytes, and first-reference placeholders.
- `ACPSessionLifecycle` owns independent insertion outcomes and foreground work. Its v1 behavior is already installed in the runner; its v2 behavior is not.
- `ACPStdioClient` and `ACPBrokerClient` still publish v1 `ACPSessionUpdateParams`. Changing these streams now would also cross acknowledgement, update-drain, lease, and persistence boundaries.
- `ACPSessionHydrator` reads transcript and queue evidence in one transaction. This design does not modify hydration, `restoreQueue`, broker cursors, or durable delivery evidence.

## Owner and identity

Add a small public value, recommended name `ACPV2SessionState`, in the existing AlasACP target. It owns one message reducer, one activity reducer, and a `.v2` lifecycle for the same immutable session/connection context. Reuse the existing context type, with compatible aliases if useful. Its child state is read-only to consumers; every mutation goes through the owner.

Every entry point checks the supplied context before mutation. Notifications additionally require the envelope session ID to match. A stale context changes no canonical state, correlation, lifecycle, ordering, or latest-state observation, and emits no semantic effects.

Expose a combined first-observed entity order keyed by message kind plus message ID, tool-call ID, plan ID, or terminal ID. Equal strings across these types remain distinct. Append each newly observed entity once. For a tool update that introduces terminal references, retain the activity reducer's tool-before-placeholder and content-reference order. Updates, replacements, acceptance, and reference removal never move an existing entity.

This is canonical entity order, not a finished UI row model. An optimistic local user row obtains its upstream position only from its actual user-message update. A terminal placeholder may be referenced by several tools and need not become a standalone visible row.

## Notification dispatch

Extend the lossless `ACPV2SessionUpdateEnvelope.Payload` with a typed foreground-state variant. Preserve its existing message accessor and all current activity variants. Dispatch each known notification to exactly one child reducer, never through the v1 update model.

Applying an envelope returns its original lossless event, applied/unhandled/stale disposition, and ordered typed effects. Preserve the existing message reconciliation-before-message-change order and lifecycle foreground-change-before-foreground-ended order. Canonical changes are complete before the result is returned; no callbacks or awaits expose intermediate state.

Keep the latest applied state observation, including its exact raw update and explicit provenance, even when a repeated state produces no lifecycle transition. A setup default ignored because state was already observed cannot replace that observation. Unknown update variants remain raw unhandled events and create no entity or foreground transition. Known malformed interpreted shapes fail during decoding before the owner can mutate state. This is an in-memory guarantee, not an event journal or durable replay implementation.

## Lossless lifecycle inputs

The existing `ACPV2PromptAccepted` and `ACPV2StateUpdate` have generic Decodable entry points. Add explicit `decode(from:)`, `init(rawValue:)`, and `encodedData()` wire entry points using the same exact raw JSON parser/writer as the transcript envelope. Generic Decodable remains available for current callers, with its existing numeric-representation limits documented; the new owner-facing wire path must not round-trip through generic JSONDecoder or AnyCodable.

- Prompt acceptance still requires a non-null string `messageId`. Preserve unknown fields, metadata, and arbitrary numeric tokens. Validate supplied `_meta` as object/null consistently with the envelope.
- State updates require `sessionUpdate: "state_update"` and a string `state`; unknown state strings remain explicit. Supplied `_meta` must be object/null. Preserve all raw fields and scoped metadata.
- Preserve omitted, null, malformed, and unknown stop reasons without inventing success. Optional malformed failure details must not hide an otherwise valid idle state. Keep the malformed raw value; use the existing generic failure summary when no valid details are available.
- A valid error-detail view requires an exact integral int32 code and string message, and retains opaque `data` without Foundation numeric conversion. Keep the existing `error` API compatible where representable. A useful failure message must remain available even if opaque error data contains `1e999`. The exact raw view is authoritative; do not silently discard or round its data.

Reuse a bounded exact numeric helper if needed for int32 and the existing uint32 fields. Do not add a second general JSON parser or change v1 JSON-RPC error decoding. Mathematical integral spellings remain valid; malformed raw number tokens, fractions, and out-of-range codes cannot become valid typed details.

## Prompt registration and outcomes

The owner registers an exact request ID and optimistic local-row UUID before sending a prompt. Registration must succeed in the message model before lifecycle submission becomes pending. Repeating the same pair is idempotent; conflicting request/row bindings leave both models unchanged. Registration starts no foreground work and creates no upstream message position.

On acceptance, validate the request's pending/uncertain status and message correlation before committing either child mutation. Never leave lifecycle accepted while message binding conflicts, or bind a row when lifecycle rejects the response. Missing registration is unmatched; a mismatched repeated acceptance, reused message binding, or response after a definitive rejection is a conflict with no state change. Request IDs and their registrations are not reused within this context.

Valid acceptance updates insertion state and exact correlation atomically. Acceptance before echo binds the future user message without creating content. Echo before acceptance reconciles the existing entity at its observed position, reuses the local UUID, and returns projection effects for that reconciled message before the accepted lifecycle effect. Identical submission content never establishes identity. Repeated identical acceptance emits no duplicate reconciliation or insertion effect.

A definitive pre-insertion rejection changes only a pending/uncertain submission outcome. It neither removes canonical content nor ends foreground work. A rejection after acceptance is a conflict, not a rollback. Retain correlation registrations for the context lifetime so late or contradictory responses cannot reuse them.

Expose observation loss as a context-fenced operation using the existing lifecycle policy: pending becomes uncertain, foreground becomes unknown, accepted stays accepted, and canonical entities/correlations remain intact. It emits no foreground completion and no retry/replay instruction. Observation loss does not prove process termination. The later transport owner remains responsible for current-connection fencing; this value exposes no context-rebinding or automatic recovery API.

## Foreground provenance

State application requires explicit `.live`, `.snapshot`, or `.setupDefault` provenance. Never infer it from idle, a stop reason, an acceptance, or transcript content. Only an appropriate live idle boundary closes an observed foreground interval. Initial/default/resume snapshots synchronize state without creating a completion, and setup defaults cannot overwrite an already observed state. A setup default represents the new-session idle default only; applying a non-idle value with that provenance must fail without mutation. Agent-initiated foreground work needs no synthetic prompt.

Acceptance, rejection, output, tool status, terminal exits, and outstanding permission data cannot start or complete foreground work. The owner returns lifecycle decisions only; it does not advance queues, account usage, acknowledge broker delivery, cancel interactions, or invoke terminal hosts. Explicit provenance is an input for future integration, not a claim that resume/replay is implemented here.

## Validation and acceptance

Use Swift Testing in AlasCore. Extend the lifecycle decoder suite for lossless state/acceptance wire behavior and malformed known containers. Add one coherent suite for the new owner. Keep existing message/activity/lifecycle logic covered by their existing suites rather than duplicating every field-patch test. Promote state_update from the old unknown-variant fixtures to valid typed state fixtures; use a genuinely unhandled variant for the lossless unknown case.

- Interleave user/agent/thought messages, tool calls, plans, references, terminal output, and state updates. Verify combined first-observation order, separate equal IDs, unchanged positions, and exact raw events.
- Test acceptance and echo in either order, including two identical submissions with reversed responses. Conflicting or stale acceptance/registration/rejection must change neither lifecycle nor message binding.
- Pin acceptance-before-idle, acceptance-after-idle, pre-insertion rejection during active work, and agent-initiated work. Acceptance never creates a completion; the same live idle boundary completes only once.
- Pin explicit snapshot/default provenance, repeated-state observations with changed raw information, unknown state strings, and observation loss without implicit rejection, replay, or completion.
- Preserve opaque `1e999` and a large integer in state, acceptance, stop-reason data, and error data through explicit wire round trips. A valid failure message survives unrepresentable opaque data. Malformed optional error details remain raw while valid state still applies.
- Reject required state/message-ID/container errors and malformed interpreted number tokens before any owner state changes. Stale notifications, including terminal references, produce no entity/order/observation mutation.
- Run affected package suites for session owner, lifecycle, message transcript, activity state, and protocol negotiation. Check actual executed counts, full SwiftFormat lint, and whitespace for new/tracked files. No app build or live interoperability claim is warranted if scope stays package-only.

Obtain one fresh final code review after implementation. Update the umbrella with exactly what is locally validated and what remains for transport, projection, persistence/replay, and live rollout. Do not mark the full coexistence workstream complete.

## Choices left to the builder

The combined owner, explicit provenance, atomic correlation/lifecycle mutations, exact raw lifecycle inputs, and package-only boundary are recommendations in this design. Exact API/result names, effect wrappers, lookup shape, and small internal composition/validation helpers are left to the builder. Avoid a general event bus, async framework, storage layer, or multiple owners of mutable child state.

## Sources

- [Pinned prompt insertion, entity identity, foreground lifecycle, and state synchronization](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/prompt-lifecycle.mdx), inspected on 2026-10-26.
- [Pinned v2 schema](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/schema/v2/schema.json), including PromptResponse, StateUpdate, ErrorStopReason and int32 ErrorCode, inspected on 2026-10-26.
