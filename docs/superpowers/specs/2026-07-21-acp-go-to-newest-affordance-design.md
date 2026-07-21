# ACP Go To Newest Affordance Design

## Context

The ACP chat pane already tracks whether the transcript should follow the tail through `ACPSession.followsTranscriptTail`. User-driven upward scrolling pauses tail-follow, stores a remembered anchor, and prevents streaming or layout reflow from pulling the viewport back to the newest message. Returning to the bottom resumes tail-follow and clears that remembered anchor.

Long transcripts currently have no direct affordance for returning to the newest message after the user intentionally scrolls away. The user must manually scroll back to the bottom.

## Goal

Add a compact, conventional control that appears when the user has intentionally scrolled away from the transcript tail and jumps back to the newest message.

## Non-Goals

- Do not add a separate unread/new-message counter.
- Do not infer visibility from raw distance-from-bottom alone.
- Do not change transcript pagination, remembered-anchor persistence, or streaming auto-scroll behavior beyond wiring the new control into the existing tail-follow path.

## User Experience

When `session.followsTranscriptTail` is `false`, show a lower-right floating button over the transcript scroll area, positioned just above the composer-safe tail space. The control should be compact and icon-first, using a down-arrow system image and an accessibility label such as "Go to newest message".

Clicking the button resumes tail-follow and scrolls to the newest message. The control disappears after tail-follow resumes. If the user manually scrolls back to the bottom, existing bottom detection should also resume tail-follow and hide the control.

## Architecture

Implement the affordance inside `ACPMessageList`, because that view already owns the `ScrollViewReader`, scroll bookkeeping, tail restoration helpers, and access to `session.followsTranscriptTail`.

The button should be an overlay on the scroll view or its surrounding geometry container so it can float independently of transcript rows. It should not be inserted into the lazy message stack, because it is chrome for navigation rather than transcript content.

The click handler should reuse the existing tail-follow transition:

- Set tail-follow to true through the local `setFollowsTranscriptTail(true)` path.
- Clear remembered scroll state through `onRememberScrollAnchor(nil, nil, true)`.
- Reset the transcript window to the tail.
- Scroll to the existing `__composer_spacer__` tail anchor with the same short animation used for non-streaming tail restores.

## State Rules

The visible state is derived from `!session.followsTranscriptTail`. This intentionally matches user intent instead of raw geometry:

- User-driven upward scroll: pauses tail-follow and shows the button.
- Layout reflow or streaming height changes: do not show the button unless tail-follow was already paused.
- Click button: resumes tail-follow, scrolls to tail, clears remembered anchor, hides the button.
- Manual return to bottom: existing bottom detection resumes tail-follow and hides the button.

## Error Handling

The action should be idempotent. If the transcript is already near the bottom, `scrollToTail` can skip redundant scrolling using existing distance checks. If the tail anchor is temporarily absent during a view update, the next layout or transcript change can run the normal restore path.

## Testing

Add focused Swift Testing coverage for pure policy where practical:

- The affordance should be visible only when tail-follow is paused.
- Resuming from the affordance should map to the same tail-follow state transition as reaching the bottom.
- Existing tail-scroll idempotency tests should continue to cover redundant scroll suppression.

Avoid broad UI snapshot tests unless the implementation introduces a separate view with meaningful pure layout policy.
