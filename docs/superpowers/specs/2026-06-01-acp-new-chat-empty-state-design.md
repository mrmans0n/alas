# ACP New Chat Empty State Design

Date: 2026-06-01
Status: Approved for implementation planning

## Goal

Give a completely new ACP chat pane a distinct empty state that feels ready to use before the first prompt. The composer should sit closer to the center of the pane, show a compact welcome treatment, and offer starter prompts. Once the user starts the session, the composer should animate smoothly to its current bottom position and the normal transcript layout should take over.

The existing loading skeleton remains the state for restoring, reattaching, or loading an existing session.

## Context

The current ACP surface is built around:

- `Alas/Sources/ACP/UI/ACPTabView.swift`
- `Alas/Sources/ACP/UI/ACPComposer.swift`
- `Alas/Sources/ACP/UI/ACPComposerShell.swift`
- `Alas/Sources/ACP/UI/ACPConnectingPlaceholder.swift`
- `Alas/Sources/ACP/UI/ACPMessageList.swift`

`ACPComposer` is already the correct visual primitive: a floating glass pill with agent status, shortcut hints, attach/action controls, model/config chips, and send behavior. The new empty state should reuse that composer rather than introduce a separate input surface.

## UX

When an ACP chat is brand new and has no transcript messages, the center pane shows:

- A small symbolic mark above the text.
- Title: `What should we work on?`
- Subtitle: `Start with a task, a file, or a rough idea.`
- Three compact starter chips:
  - `Review current changes`
  - `Find a bug`
  - `Plan a feature`
- The normal ACP composer, horizontally centered and raised toward the middle of the pane.

The starter chips insert editable text into the composer and focus it. They do not submit automatically.

The empty state should be quiet and utility-focused. It should not become a landing page, should not use large decorative cards, and should not compete visually with the composer. The composer remains the dominant affordance.

## State Rules

Show the new empty state only when all of these are true:

- The session is fresh rather than restored from persistence.
- The ACP session has no transcript messages.
- The session is not hydrating from storage.
- The session is not showing a setup, hydration, or connection failure.
- The session is sufficiently attached or attachable that the composer can accept input normally.

Keep `ACPConnectingPlaceholder` for loading states, especially:

- restoring a previous persisted session,
- hydrating session history,
- reattaching to an existing remote session,
- initial agent process startup before the app can safely present the normal composer state.

If the adapter requires setup, the existing setup/update banners remain responsible for that state. If session history exists, the normal transcript surface renders.

## Interaction

Clicking a starter chip:

1. Inserts a predefined prompt into the ACP composer draft.
2. Replaces an empty draft.
3. Appends after existing non-empty draft content, separated by a blank line.
4. Focuses the text input.
5. Persists the draft through the existing composer draft path.

Suggested inserted prompts:

- `Review the current changes in this worktree and suggest the next steps.`
- `Look for likely bugs or fragile spots in this worktree. Start by inspecting the current changes.`
- `Help me plan this feature. Ask clarifying questions first if the goal is ambiguous.`

These prompts can be adjusted during implementation to match available local helper APIs, but the chip labels should remain short.

## Animation

The transition from empty state to normal chat should happen when the first prompt is accepted into the session. The welcome content fades and moves slightly upward while the composer animates from the raised empty position to the existing bottom composer position.

Use the app's existing SwiftUI animation style:

- spring response around 0.3 seconds,
- damping high enough to feel controlled,
- opacity transition for the welcome content,
- layout animation for the composer position.

Do not delay message rendering solely for the animation. If the first user message appears quickly, the animation and transcript update should feel like one continuous transition.

## Implementation Shape

Prefer a local UI-level change in `ACPTabView`:

- Derive an `isNewEmptySession` boolean from existing session state.
- Add an empty-state overlay/view next to the existing `ACPMessageList` and `ACPConnectingPlaceholder` branches.
- Add a layout mode parameter to `ACPComposer`, or wrap it in a container that controls vertical placement without changing the composer internals.
- Add a small empty-state view component near the ACP UI files if that keeps `ACPTabView` readable.
- Reuse existing theme tokens: `bg-*`, `fg-*`, `line`, `accent`, and `accent-soft`.

Avoid adding persisted state for this visual mode unless implementation finds that freshness cannot be derived reliably. Avoid lifecycle changes that defer ACP attach until first send.

## Tests

Add focused Swift Testing coverage where practical:

- Fresh, non-restored empty session resolves to the new empty state.
- Restored or hydrating sessions continue to resolve to the existing connecting/loading state.
- Any existing transcript messages suppress the new empty state.
- Starter prompt insertion updates the composer draft without submitting.
- Non-empty draft behavior is deterministic and covered.

Manual verification should cover:

- creating a new ACP chat and seeing the centered empty state,
- clicking each starter chip and editing the inserted prompt,
- submitting the first prompt and seeing the composer animate down,
- reopening or restoring a previous session and seeing the existing loading/restore behavior instead of the new empty state.

## Out of Scope

- New ACP provider capabilities.
- Changes to adapter setup/update banners.
- New persistence fields unless the derived state proves insufficient.
- Replacing the existing composer chrome.
- Redesigning normal transcript rendering.
