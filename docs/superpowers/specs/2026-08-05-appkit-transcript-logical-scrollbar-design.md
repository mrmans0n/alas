# AppKit Transcript Logical Scrollbar Design

## Goal

Make the AppKit ACP transcript scrollbar behave as though the whole known
transcript is present, while continuing to render and measure only a bounded
message window. Revealing or discarding existing-history pages must not resize
the scrollbar thumb.

## Behavior

The native vertical `NSScroller` represents logical message progress rather
than the pixel height of the currently rendered document. One message occupies
a fixed 96-point logical extent. The thumb proportion is derived from the
viewport height and the total known message count; its value is derived from
the global index of the top visible message. Consequently, swapping pages of
variable-height content cannot change the logical range.

The scroller is non-continuous. Its knob moves normally while the user drags,
but the transcript navigates only when tracking ends. A released position maps
to a global top-message index. The AppKit path selects a bounded 90-message
window with up to one 30-message page before the target, then aligns the target
message with the viewport top. Releasing at the bottom restores the live tail
window and tail-follow; every historical target pauses tail-follow.

Wheel and trackpad pagination also keep the render window bounded. Revealing a
30-message page at one edge discards the opposite page, while the existing
reconciler anchor preservation prevents visible movement.

## Tail-first Hydration

On reopen, the transcript initially materializes only its last 30 messages.
`ACPTranscript` will retain the number of known messages preceding its current
array as a global index offset. `offset + messages.count` therefore exposes the
full logical count before older message objects have been constructed.

If a scrollbar release targets that unmaterialized prefix, the AppKit
coordinator records the global target. The existing backfill continues; after
its prepend makes the target available, the coordinator selects and aligns the
requested window. A changed count clamps the target, and destroying the
coordinator discards it.

## Boundaries

This applies only to the feature-flagged AppKit transcript path. The legacy
SwiftUI list, persisted session schema, and wire formats remain unchanged.
Genuine newly appended messages extend the logical range normally. Logical
progress intentionally weights every message equally, regardless of rendered
height.

## Verification

Pure tests cover logical knob metrics and release-position mapping. Transcript
tests cover global/local index conversion and bounded target windows. AppKit
coordinator tests cover release-only jumps, queued hydration targets,
tail-follow transitions, bounded bidirectional pagination, and visual-anchor
preservation. Existing scroll-back, scrollbar-click, resize, hydration, and
tail-follow tests remain regression gates.
