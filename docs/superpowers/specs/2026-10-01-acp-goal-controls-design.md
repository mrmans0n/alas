# ACP goal controls

## Purpose

Alas already reads basic goal snapshots from ACP `session_info_update` messages and shows them in the toolbar. It does not negotiate the provider-neutral goal extension, expose its controls, or display the richer progress fields emitted by current adapters.

Add capability-driven goal controls for any ACP provider that advertises the extension. Codex currently advertises set, pause, resume, and clear. Claude currently advertises set and clear. Providers without the extension keep their existing advertised slash-command behavior.

References:

- [codex-acp goal extension](https://github.com/agentclientprotocol/codex-acp/blob/main/docs/goal-extension.md)
- [claude-agent-acp goal extension](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/docs/goal-extension.md)

## Protocol model

Decode `_meta.goal` from the agent capabilities returned by `initialize`. The capability contains:

- `version`
- a nonempty `controlMethod`
- the supported subset of `set`, `pause`, `resume`, and `clear`

Alas supports version 1. Unknown versions and actions are ignored. A malformed capability does not fail initialization and behaves as unsupported. Alas sends control requests to the advertised method with `sessionId` and `action`; `set` also sends a nonblank `objective`. Provider names and legacy method aliases do not participate in routing.

Keep the capability on `ACPSession` as runtime state learned during each attach. `ACPConnection` encodes the request. `ACPSessionManager` resolves the live runner and lease before sending it, matching existing model and mode controls.

## Goal state

Expand `ACPGoalState` to retain the provider-neutral snapshot fields useful to the UI:

- objective and status
- creation and update timestamps
- token budget and tokens used
- elapsed seconds
- iteration count
- last continuation reason

All fields except the objective remain optional. Partial snapshots merge into the existing state. `goal: null` clears it. Top-level `_meta.goal` remains authoritative, while the existing nested Codex metadata path stays as a compatibility fallback.

Goal state remains runtime only. Providers restore it through session load or resume and publish a fresh snapshot.

## Toolbar interaction

When the session advertises `set` and has no goal, the toolbar shows a compact "Set goal" control. Its popover contains one objective field and disables submission for blank input.

When a goal exists, the existing pill becomes a button that opens the same popover. It shows the objective, normalized status, and only the progress values the provider supplied. Token use is shown against the budget when both exist. Time, iterations, timestamps, and the last reason are omitted when absent.

Actions follow the negotiated capability:

- Pause appears for an active goal when `pause` is advertised.
- Resume appears for a paused goal when `resume` is advertised.
- Clear appears when `clear` is advertised and asks for confirmation.
- Set remains available when advertised so the user can replace the objective according to provider behavior.

The existing `/goal` slash command path does not change. Providers continue to advertise and execute slash commands through ordinary prompts.

## Request state and errors

Only one goal control request can run from the popover at a time. Controls disable while it runs. Alas does not mutate the goal optimistically; the next provider snapshot remains authoritative.

Request failures appear inline in the popover and leave the current goal unchanged. Goal control requests can run while a prompt is active. The adapter owns any steering or queueing needed for that state.

## Testing

Extend existing suites rather than adding scenario-specific files:

- `ACPInitializeTests` covers valid, partial, malformed, and unknown capability values.
- `ACPConnectionTests` covers the advertised method and request payloads.
- `ACPSessionTests` covers richer snapshots, partial updates, the legacy fallback, and clearing.
- `ACPGoalPillTests` covers pure presentation and action-visibility decisions.

SwiftUI composition and manager forwarding do not need tests. Run the affected suites locally.

## Deferred scope

Remote gateway goal controls and local persistence are deferred. Add remote controls when the remote client needs goal editing. Add persistence only if an adapter cannot restore its session-owned goal.
