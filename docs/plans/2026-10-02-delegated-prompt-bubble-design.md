# Delegated prompt bubble

## Problem

A delegated prompt (a parent's or mission's prompt to a child, or a child's
report to its parent) renders as a flat full-width card. It doesn't read as a
prompt, long prompts take over the transcript, and markdown headings inside it
render at agent-prose sizes (`## Issue context` at base + 4pt).

## Design

`DelegatedPromptRow` (`Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift`)
becomes an incoming chat bubble: the user bubble mirrored to the left.

- **Shape.** Left-aligned. `UnevenRoundedRectangle` with radius 12 everywhere
  except bottom-leading, which is 4 (the mirror of `ACPUserBubbleChrome`).
  Padding (9 vertical, 13 horizontal) and shadow match the user bubble.
- **Color.** Neutral slate: a `bg-3` → `bg-2` vertical gradient, stroked with a
  0.5pt `bg-5` hairline. No accent, so it never reads as something the user
  typed.
- **Width.** At most `contentMaxWidth * 0.84`. The call site in
  `ACPTranscriptRowContent` passes `contentMaxWidth`.
- **Caption.** Above the bubble, outside it: the existing direction glyph
  (`arrow.turn.down.right` / `arrow.turn.down.left`) and the existing
  `ACPDelegatedPromptSource.transcriptLabel`, at 11pt in `fg-faint`. The label
  text doesn't change.
- **Headings.** `ACPChatTypography` gains a `flattensHeadings` flag. When it is
  set, `headingSize(level:)` returns `paragraphSize`, and the heading stays bold.
  Only `DelegatedPromptRow` sets it.

### Folding long prompts

- A pure function decides whether the row folds, using only the raw text: it
  folds when the text has more than 12 lines or more than 900 characters. It
  never measures the rendered height, because writing state from geometry
  callbacks in the transcript caused a live-lock before.
- While folded, the markdown is clipped to a fixed height of roughly 8 lines at
  the current typography, with a fade mask at the bottom. Below it is a
  "Show full prompt · N lines" button, where N is the raw line count. When the
  row is open, the button reads "Collapse".
- The expanded flag is `@State` in the row, the same way `ACPThoughtView` keeps
  its own. It resets to folded when the row is rebuilt.

## Testing

One parameterized Swift Testing case covers the fold decision (short, many
lines, long single line) and the line count. Styling isn't tested.

## Out of scope

- Parsing the "Issue context" block into structured chips.
- The sender agent's name for prompts from a parent: the source records only
  the parent's session id.
- The mirrored peer transcript (`NativePeerTranscriptScroller`).
