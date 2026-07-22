# GG Sidebar Stack Icon

Date: 2026-07-22
Status: Approved design

## Context

Worktree rows currently show GG stack progress as `▲ merged/total` in the
accent color. This makes supporting stack metadata more prominent than the
row's activity timestamp and line counts.

The stack marker should remain glanceable without reading as a status alert or
competing with the selected-row accent.

## Goals

- Replace the triangle with a tiny stack-specific icon.
- Preserve the `merged/total` progress count.
- Render the complete marker as quiet sidebar metadata.
- Preserve row layout, stack-summary loading, and tooltip behavior.

## Non-goals

- Changing when stack summaries load or refresh.
- Adding interaction to the marker.
- Changing GG progress semantics or terminology.
- Restyling other sidebar metadata or GG surfaces.

## Visual Design

The marker consists of a custom three-stroke glyph followed by the existing
monospaced `merged/total` text.

- The glyph draws three equal, short horizontal strokes in a fixed 9-by-9-point
  frame.
- The glyph and count use the existing `fg-faint` theme token.
- The count retains the row's current 10.5-point monospaced text style.
- The glyph and count use 3 points of spacing.
- The marker has no background, border, capsule, or hover treatment.

The custom glyph keeps the tiny geometry deterministic and avoids borrowing the
generic menu or drag-handle meaning of an SF Symbol such as
`line.3.horizontal`.

## Architecture

`WorktreeRowView` remains the owner of the stack marker. Its existing lookup in
`GGStackSummaryStore` and its position alongside activity and line-count
metadata do not change.

A small SwiftUI `Shape` colocated with the sidebar row draws the three strokes.
The shape is presentation-only and has no state or dependencies. The marker
combines the shape and progress text in a compact horizontal group.

The glyph is decorative for accessibility. The combined marker exposes the
existing human-readable stack summary, for example
`gg stack · 2 of 3 commits merged`, as both its help text and accessibility
label.

## State And Error Handling

The marker appears only when `GGStackSummaryStore` contains a summary for the
worktree path, matching current behavior. Missing summaries continue to render
nothing. Because the change introduces no loading, commands, or mutable state,
it has no new error state.

## Testing

- Keep the existing singular and plural tooltip assertions.
- Add an AppKit-hosted row-height regression that renders a worktree with a
  real stack summary and verifies the row height matches the no-summary case.
- Run the focused sidebar test suite and the required macOS build and test
  commands before completion.
