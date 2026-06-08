# ACP Queued Controls Design

## Context

Queued prompt controls in the ACP chat pane currently appear inside the queued bubble's header row. They are only visible while the bubble is hovered. Because the controls sit outside the practical hover path, they can disappear before the pointer reaches them, making send, retry, edit, and remove hard or impossible to click.

Normal ACP transcript messages already solve a related problem with a hover region that keeps the action affordance alive while the pointer moves from content to the control. Queued prompts need the same interaction reliability while preserving their visual identity as right-aligned, pending user prompts.

## Design

Pending queued prompts keep the existing right-aligned dashed text bubble and the existing `Queued` status label above it.

The action group moves to the left side of the text bubble. The group is vertically centered against the text bubble body, not against the full queued row and not against the status label. This keeps the controls visually attached to the content they modify.

The hover region covers the full queued row, including the text bubble and the action group. Moving the pointer from the bubble to the icons must keep the icons visible and hit-testable. The controls should remain mounted and switch visibility through opacity and hit testing, following the existing ACP gutter pattern.

Sending queued prompts keep the existing sending status and spinner behavior and do not expose actions.

## Components

`ACPQueuedBubble` remains responsible for rendering a single queued prompt and invoking the existing callbacks:

- `onForceSend`
- `onRetry`
- `onEdit`
- `onRemove`

Its layout changes from a header-embedded actions row to a content row where the action group is a sibling of the bubble column. The action group reserves its width so hover reveal does not shift the bubble.

If the queued prompt contains image thumbnails and text, the controls align to the text bubble. If the queued prompt has no text preview, the controls align to the visible queued content area.

## Behavior

For a pending queued item:

1. Hovering anywhere across the queued row reveals the actions.
2. Hovering the action group itself keeps the actions revealed.
3. Leaving both the row and the action group hides the actions.
4. Retry is only hit-testable and accessible when `lastError` is present.
5. Drag and drop reordering remains limited to pending queued items.

For a sending queued item:

1. Actions remain hidden and disabled.
2. The existing sending opacity, spinner, and border styling remain unchanged.

## Testing

Add or update focused SwiftUI-level coverage where practical for the pure layout or state behavior. Manual verification should cover:

- Hovering the queued row reveals the actions.
- Moving from the bubble to each icon keeps the actions clickable.
- Pending items can still be force-sent, retried after an error, edited, removed, and reordered.
- Sending items do not reveal actions.
- Narrow panes do not overlap the action group with the queued bubble text.
