# ACP First-Run Connecting State Design

Date: 2026-06-03
Status: Approved for implementation planning

## Goal

Make the first few moments of a brand-new ACP chat feel like a new chat is
being prepared, not like an old agent connection is recovering. A fresh chat
should show a quiet empty-state-style connecting view with phased status, then
transition into the existing ACP new chat empty state once the agent session is
ready.

The existing reconnect and skeleton UI should remain available for restored
sessions, existing conversations, real reconnects, setup/auth failures, and
other recovery states.

## Context

The current ACP chat surface is built around:

- `Alas/Sources/ACP/UI/ACPTabView.swift`
- `Alas/Sources/ACP/UI/ACPToolbar.swift`
- `Alas/Sources/ACP/UI/ACPRecoveryPill.swift`
- `Alas/Sources/ACP/UI/ACPConnectingPlaceholder.swift`
- `Alas/Sources/ACP/UI/ACPNewChatEmptyStateView.swift`
- `Alas/Sources/ACP/UI/ACPNewChatEmptyStatePolicy.swift`
- `Alas/Sources/ACP/Session/ACPSessionManager.swift`

`ACPNewChatEmptyStateView` already establishes the desired first-chat posture:
centered artwork, compact copy, starter prompts, and a raised composer. The
problem is the earlier attach window. While the agent is still checking setup,
spawning, initializing, or creating the remote session, the generic connecting
surface can show the top toolbar and `ACPRecoveryPill` with reconnecting copy.
For a first-time chat, that reads as a recovery problem instead of normal
startup.

## UX

When a brand-new ACP chat is still attaching, render a first-run connecting
view:

- No ACP top toolbar.
- No sessions button, plan pill, or reconnect/recovery pill.
- Centered sparkles artwork matching the ACP new chat empty state.
- Spinner plus primary label: `Connecting...`
- A short secondary line: `Preparing a new <Agent> chat.`
- Small phased status chips underneath the label.
- Raised composer remains visible in the same general position as the new chat
  empty state, but continues to follow existing disabled/connecting behavior.

The phased status chips should be restrained. They are there to explain why the
brief empty state is waiting, not to become a setup wizard.

Initial phase labels:

- `Checking setup`
- `Launching adapter`
- `Initializing`
- `Creating session`

Once the session is ready, the view transitions to the existing new chat empty
state:

- Title: `What should we work on?`
- Subtitle: `Start with a task, a file, or a rough idea.`
- Starter prompt chips.
- Raised composer.

## State Rules

Show the first-run connecting view only when all of these are true:

- The session is fresh, not restored from persistence.
- The session has no transcript messages.
- The current attach attempt was started as a fresh `session/new` attempt, not
  as a reload or reconnect of an existing remote ACP session.
- The session has no last error.
- The session is not in a setup or auth failure state.
- The agent is not disconnected or failed.
- The session is not ready for the regular new-chat empty state yet.

This includes the period where hydration is loading for a placeholder created
from a newly opened tab, setup is checking, or `agentState` is `.spawning`.

Do not show the first-run connecting view for:

- Restored sessions.
- Sessions with any transcript messages.
- Attach attempts started from a prior remote session id.
- Setup-needed or auth-needed states.
- Hydration failures.
- Agent failures or disconnected state.
- Real reconnect attempts from the sessions menu or recovery flow.

Those states should keep the existing toolbar, banners, recovery pill, and
`ACPConnectingPlaceholder` behavior.

## Architecture

Add a small policy layer next to `ACPNewChatEmptyStatePolicy`, for example
`ACPFirstRunConnectingPolicy`.

The policy should answer two questions:

- Whether the first-run connecting surface is visible for the current session.
- Which display phase should be shown.

Prefer deriving the phase from existing observable state:

- `setupState == .checking` maps to `Checking setup`.
- `agentState == .spawning` with no stronger signal maps to `Launching adapter`.
- A short-lived attach phase set by `ACPSessionManager` can refine spawning into
  `Initializing` and `Creating session` if derivation alone would be misleading.

If explicit phase tracking is needed, keep it runtime-only on `ACPSession`.
That runtime state may also record that the current attach attempt is a fresh
first-run attach. Do not persist either value. They exist solely to make a
transient loading view accurate.

## Components

### First-Run Connecting View

Add a dedicated SwiftUI component near the ACP UI files, for example
`ACPFirstRunConnectingView`.

Inputs:

- `agentDisplayName`
- current phase

Visual behavior:

- Reuse `ACPNewChatEmptyStateArtwork` for the sparkles mark.
- Reuse `Spinner`.
- Use existing theme tokens: `bg-*`, `fg-*`, `fg-muted`, `fg-dim`, `line`, and
  `accent`.
- Keep the centered content aligned with `ACPNewChatEmptyStateView`.
- Use compact chip styling consistent with existing ACP chips.

### ACPSessionView Routing

In `ACPSessionView`, derive:

- `isFirstRunConnecting`
- `isNewEmptySession`
- `isConnecting`

The outer shell should suppress `ACPToolbar`, adapter banners, restore banners,
and error/hydration banners only for `isFirstRunConnecting`. Other states keep
the existing shell.

Within `transcriptAndComposer`:

- `isFirstRunConnecting` renders `ACPFirstRunConnectingView`.
- `isConnecting` renders `ACPConnectingPlaceholder`.
- `isNewEmptySession` renders `ACPNewChatEmptyStateView`.
- Otherwise render `ACPMessageList`.

The composer placement should treat first-run connecting like the new empty
state, using the raised placement.

## Data Flow

1. Opening a new ACP chat creates or resolves a fresh local `ACPSession`.
2. `ACPTabView` hydrates if needed and calls `ACPSessionManager.attach` with
   the existing `freshlyCreated` decision.
3. While attach is in progress, the session remains fresh, empty, and not ready.
   The policy resolves this to first-run connecting.
4. Optional runtime attach phase changes update the displayed chip. If the
   manager records a first-run attach flag, it should be set before the first
   await in `attach` and cleared when the attempt becomes ready, fails, or is
   superseded.
5. When `session/new` succeeds and `agentState` becomes `.ready`,
   `ACPNewChatEmptyStatePolicy` takes over.
6. On setup/auth/failure/disconnect, first-run connecting stops matching and the
   existing banners or recovery UI render.

## Error Handling

Errors should never be hidden behind the first-run connecting view. As soon as
`lastError`, setup failure, auth-needed state, hydration failure, or agent
failure is present, the normal ACP shell should render so the existing banners
and retry/reconnect affordances remain available.

If explicit phase tracking is added and an attach attempt exits early, clear or
reset the phase when the attempt completes, fails, or is superseded. Stale phase
text must not appear after the session has become ready or failed.

## Testing

Add focused Swift Testing coverage:

- Fresh empty session with setup checking shows first-run connecting.
- Fresh empty session with agent spawning shows first-run connecting.
- Fresh ready empty session shows the existing new-chat empty state, not
  first-run connecting.
- Restored sessions do not show first-run connecting.
- Sessions with transcript messages do not show first-run connecting.
- Attach attempts started from a prior remote session id do not show first-run
  connecting.
- Setup/auth problems, hydration failures, last errors, disconnected state, and
  agent failures do not show first-run connecting.
- Phase labels remain stable.
- Composer placement is raised while first-run connecting is visible.

Manual verification:

- Open a brand-new ACP chat and confirm there is no top toolbar while
  connecting.
- Confirm the view says `Connecting...`, shows phased status, and then becomes
  the normal new chat empty state.
- Reopen a previous ACP chat and confirm the existing toolbar/reconnect or
  skeleton behavior remains intact.
- Force setup/auth/failure paths where practical and confirm errors are visible.

## Out of Scope

- Redesigning the normal ACP toolbar.
- Replacing `ACPConnectingPlaceholder` for restored or reconnecting sessions.
- Changing ACP setup/update/auth banners.
- Persisting attach phase.
- Changing the first prompt submission flow.
- Delaying attach until the user types or submits.
