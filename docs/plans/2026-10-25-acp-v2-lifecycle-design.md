# ACP lifecycle model and v1 integration

Status: approved with `sgtm` on 2026-10-25. Implementation is tracked in the companion lifecycle implementation plan.

## Intent

Continue [umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) after the negotiation foundation merged in [PR #2217](https://github.com/mrmans0n/alas/pull/2217). The next slice gives prompt submission and foreground work separate meanings, integrates that model into the existing v1 runner, and tests the v2 lifecycle without enabling live v2 connections.

The current runner treats a successful `session/prompt` RPC as completion. `ACPConnection.prompt` extracts quota but drops `stopReason`. V2 instead returns an inserted user message's ID, while aggregate foreground state arrives independently. An acknowledgment alone must never finish work or release the queue.

## Approach

Use a small UI-free lifecycle model with version-specific inputs and explicit effects. Keep transport and persistence side effects in the runner. Route the existing v1 response, failure, and cancellation paths through the model, so this change has a production integration rather than only unused v2 types.

This follows the umbrella's agreed separation between wire handlers and shared session logic. Completing a live Claude v2 path now would also require transcript identity/replay, client integrations, and transport ownership work. Those remain later slices. Adding v2 conditionals throughout the runner would couple two different completion contracts to its current RPC task ownership.

## Scope

- Separate submission status from aggregate foreground activity.
- Decode v1 stop outcomes without conflating an absent or unknown reason with success.
- Add isolated v2 prompt-acceptance and state-update schemas with fixture coverage.
- Integrate the shared model into the existing v1 runner, including cancellation ownership, queue settlement, and completion publication.
- Preserve explicit stopped or unknown outcomes through delegated reports and usage history.
- Keep production negotiation restricted to v1, including when the Debug toggle is enabled.

## Model and contracts

### Submission and foreground are independent

Submission status describes one exact local request: pending, accepted with the v2 user-message ID, rejected before insertion, or uncertain after loss of observation. JSON-RPC request identity associates a response with its submission. Equal text, arrival order, and a foreground state must not imply acceptance.

Foreground state describes the session: unknown during attachment, idle, running, or requiring action. A state update is aggregate, not a per-prompt completion event. Agent-initiated work can open a foreground interval without a local submission. Independent background output or permission requests do not change foreground state by themselves.

The model emits distinct effects for acceptance, rejection, foreground changes, and terminal outcomes. A v1 prompt response is a terminal input; a v2 prompt response is acceptance only. V2 live state changes close an interval at idle, with its outcome kept separately from which user messages the model consumed. An idle state is not evidence of consumption or durable upstream storage.

Initial and resume snapshots are explicitly marked by the caller. They synchronize state without creating a completion. Repeated states are idempotent; repeated idle cannot publish another completion or add usage. Updates received before a setup response remain authoritative. A later setup response cannot overwrite them with idle.

Keep submission identities and foreground generations distinct. Preserve event receive order. Do not assume acceptance precedes running or idle: a short foreground interval can end before its prompt response arrives. Retain that interval's result independently, and do not fabricate a per-prompt success or redispatch an unresolved submission. Full v2 queue scheduling is deferred with live v2 runner integration.

### Stop outcomes

Preserve the raw stop-reason value for absent, null, malformed, and unrecognized values. Recognize protocol-defined reasons without collapsing them into one successful result:

- `end_turn`: normal completion.
- `cancelled`: cancellation.
- `max_tokens`, `max_turn_requests`, and `refusal`: stopped with the supplied reason, distinct from success and from Alas's provider-usage-limit retry state.
- V2 `error`: failure with the supplied JSON-RPC details when valid. Missing details still represent failure; do not invent an error code.
- No recognized reason: stopped with unknown outcome.

A local v1 cancellation still wins over a racing successful RPC, preserving the existing ownership rule. Superseded responses may contribute real usage but cannot finish or clear a successor. Existing usage-limit detection and configured continuation behavior remain separate from protocol stop reasons.

### V1 integration

Carry the decoded stop outcome and quota through `ACPPromptOutcome`. Use the lifecycle decision to select the terminal result instead of classifying every successful RPC as completed. Extend `ACPTurnCompletion` and its consumers so a stopped/unknown result is never described as successful completion. A delegated stopped/unknown result wakes its parent with factual wording, unless the turn was started by a shepherd prompt as excluded today. It must not create an automatic child retry.

Only `end_turn` is eligible for the successful-turn callback used for next-prompt suggestions. Recognized stops and unknown outcomes still end v1 foreground work and settle an acknowledged queue item once. Rejected requests retain the existing error/retry handling; lost transport observation retains the current delivery-uncertainty safeguards.

Keep the existing runner responsible for writer-lease checks, durable consumption acknowledgments, queued persistence, draining buffered updates, and cost/quota attribution. A lifecycle effect cannot acknowledge an event or dispatch a successor before the runner's existing persistence and update boundaries allow it.

Retain the current v1 Stop behavior. A v2 cancel request is modeled separately from confirmed cancellation; its future live handler must wait for an appropriate idle update rather than treating a sent notification as confirmation. This slice tests that distinction but does not install v2 cancellation on the v1 path.

### V2 isolation

Use explicit v2 decoder entry points. Do not teach the current v1 `ACPSessionUpdate` decoder to guess a protocol from payload shape, or feed v2 frames through its lossy unknown case. Preserve unknown fields in the lifecycle fixtures and decoded payloads.

The v2 acceptance decoder requires a non-null message ID. State decoding retains missing/unknown stop outcomes and any failure payload. Unknown state values cannot silently become idle. These schemas feed the lifecycle model directly in tests until the later versioned ingress and transcript integration are ready.

## Existing behavior to preserve

- Cancellation cannot target a queued successor that starts while Stop is awaiting transport work.
- Detached or superseded runners cannot publish fresh completions or mutate the current connection.
- Queued dispatch provenance, direct-turn markers, fork context delivery, and background wake confirmations keep their existing persistence boundaries.
- Recovery reads transcript and queue from one hydration snapshot. Do not use text matching to establish v2 insertion, and do not change `restoreQueue` or cross-version resume in this slice.
- Repeated lifecycle observations cannot duplicate delegated reports, usage rows, or queue advancement.

## Validation

Use Swift Testing and deterministic event gates. Add package coverage for the new state model and decoders, extending existing suites where applicable. Exercise acceptance before/after running and idle, foreground work without a local prompt, direct entry into requires-action, repeated and resume snapshots, stop-reason variants, cancellation confirmation, and loss before/after known acceptance.

Extend the existing runner and queue suites for observable v1 outcomes: a cancelled response without a local Stop, non-success and malformed/missing stop reasons, exactly-once queue settlement and reporting, and a late response after cancellation or supersession. Reuse existing race coverage and fixture helpers instead of duplicating it. Update orchestration and usage tests only for the new outcome semantics.

Run affected AlasCore tests first, then the focused app runner, queue, and connection suites with isolated DerivedData. Check actual test counts. Do not run the entire local test plan. No tests for Debug view composition, no adapter/package changes, and no claim of live v2 interoperability.

## Boundaries and implementation choices

No live v2 eligibility, transcript upserts or prompt echo reconciliation, session/resume implementation, MCP client-tool bridge, adapter fork publication, persisted broker protocol migration, or cross-version recovery changes are included. Workstream 2 remains partial until v2 is connected to the runner and validated with the later slices.

The implementer chooses exact type/file names and whether effects are represented as a value or a short array. The lifecycle model owns deterministic decisions; transport, clocks, database access, and callbacks stay outside it. Implement on a new branch based on current `origin/main` in this existing worktree, preserving the local research note. Commit and PR publication follow a separate shipping request.

## Evidence

The relevant runner, connection, prompt-result, and completion code is unchanged between local `bcd8a4c2d0a1eb689e73b0041ec661ccca86121a` and fetched `origin/main` at `9deb125cd`. Main also contains later hook-review and paired-host changes, which the new branch must retain.

The official lifecycle document at current upstream commit `8ea15f4eed0128ba8fe5b0cbb65282e2fb431842` is byte-identical to the version pinned by the umbrella at `41c6a98caa3dea7d8e05a8013348e266dd4286e1`.

- [Prompt lifecycle and foreground state](https://github.com/agentclientprotocol/agent-client-protocol/blob/8ea15f4eed0128ba8fe5b0cbb65282e2fb431842/docs/protocol/v2/prompt-lifecycle.mdx)
- [Setup and current-state synchronization](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/session-setup.mdx)
