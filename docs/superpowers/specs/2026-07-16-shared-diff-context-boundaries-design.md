# Shared Diff Context Boundaries Design

## Overview

Diff review panels currently expose context expansion as hunk-owned edges. The
first hunk can own an `above` edge, and every hunk can own a `below` edge. That
avoids duplicate controls, but it makes intermediate hunks appear to be missing
an "expand above" affordance. It also leaves nearby hunks visually separated
after expanded context makes their visible ranges contiguous.

The review diff should model hidden context between neighboring hunks as one
shared boundary. A shared boundary renders one bridge with directional
expansion controls and a discoverable full-gap action. When no hidden lines
remain between two hunks, their visual panes should fuse into one contiguous
container while preserving the original hunk structure for comments, anchors,
and review actions.

This applies to both split and stacked diff views.

## Goals

- Show an above-direction expansion affordance for every hunk that has hidden
  context before it.
- Render one shared inter-hunk bridge for each hidden gap between neighboring
  hunks.
- Provide three shared bridge actions: expand toward the upper hunk, expand all
  hidden lines, and expand toward the lower hunk.
- Fuse visual panes when two hunks become contiguous through expansion.
- Keep parsed diff hunks immutable so existing hunk identity, anchors, comments,
  and actions remain stable.
- Support the same behavior in split and stacked views.

## Non-Goals

- Do not merge or rewrite the parsed diff hunks themselves.
- Do not change staging, commenting, or hunk action semantics.
- Do not add a "nearby hunks only" threshold. Shared bridges appear for every
  hidden inter-hunk gap.
- Do not redesign the existing first-hunk top or last-hunk bottom single-edge
  controls beyond moving them onto the same internal boundary model.

## Current Behavior

`DiffContextExpandedDisplayBuilder` decides ownership with
`ownsBoundary(groupIndex:boundary:)`. Today, `.above` is only owned by the first
group, while `.below` is owned by every group. This means the hidden gap between
two hunks is represented as the previous hunk's `below` boundary. The next hunk
does not render an `above` control, which is visible in review panels as a
missing "Expand context above" button.

The display builder already has enough range information to understand previous
and next hunks, and context expansion state is already separate from the parsed
diff. The missing concept is an explicit display-layer boundary for the shared
hidden range between two neighboring hunks.

## Proposed Model

Introduce a display-layer boundary model that projects a file into ordered
render elements:

```text
external-top-boundary?
group
shared-boundary?
group
shared-boundary?
group
external-bottom-boundary?
```

Boundary types:

- `externalTop`: hidden file context before the first hunk.
- `externalBottom`: hidden file context after the last hunk.
- `shared`: hidden file context between two neighboring hunks.

External boundaries preserve the existing one-direction behavior:

- `externalTop` renders "expand context above" for the first hunk.
- `externalBottom` renders "expand context below" for the last hunk.

Shared boundaries are keyed by the gap identity rather than by either hunk's
individual edge. A shared boundary tracks the source line range hidden between
two neighboring groups and the amount currently revealed from each side.

The shared boundary state must support:

- chunk expansion from the top side of the gap;
- chunk expansion from the bottom side of the gap;
- full expansion of the remaining gap;
- clamping when top and bottom reveals meet or overlap;
- reporting that the boundary is fully revealed.

Parsed diff hunks remain unchanged. The display builder composes original
hunks, expanded context lines, and boundary rows into render output.

## Rendering And Interaction

### Split View

In split view, a shared boundary renders as a full-width bridge row between two
hunk bodies. The bridge spans both old and new panes and visually belongs to the
gap rather than to either hunk.

The bridge exposes three actions:

- Up control: reveal the next chunk from the top side of the shared gap.
- Center action: reveal the entire remaining gap immediately.
- Down control: reveal the next chunk from the bottom side of the shared gap.

The center label should read `Expand all N lines` when the exact hidden line
count is known. If the full-file snapshot is not loaded yet, it can fall back to
`Expand all context` until the provider resolves the source lines.

### Stacked View

In stacked view, the same shared boundary renders as one unified row. The
directional controls live in the line-number gutter area, and the center action
lives in the code/content lane. Controls are not duplicated per old/new side.

The visual treatment should make the row read as one bridge in the single
stacked code stream while preserving the same actions as split view.

### Modifier Behavior

The bridge keeps the existing chunk and modifier interaction model:

- Click `up`: expand one chunk toward the upper hunk.
- Click `down`: expand one chunk toward the lower hunk.
- Option-click `up` or `down`: expand all remaining lines from that direction.
- Click `Expand all N lines`: reveal the entire remaining shared gap.

## Pane Fusion

When a shared boundary is fully revealed, the two neighboring hunks should no
longer render as separate bordered panes. The display should coalesce their
visual containers into one outer pane because there is no hidden gap between
them.

Fusion is a presentation concern. It should not merge parsed hunks or remove
their original identities. Hunk headers may remain as internal landmarks if they
are still useful for orientation, but the outer border and spacing should read
as one contiguous diff block.

The same rule applies when hunks are already contiguous in the original diff:
there should be no empty bridge, and the panes should render as fused from the
start.

## Edge Cases

- If a file has only one hunk, it keeps the existing top and bottom expansion
  behavior through external boundaries.
- If an inter-hunk gap has zero hidden lines, no shared bridge renders.
- If expansion from both sides would overlap, reveal counts are clamped so no
  context line is duplicated.
- If snapshot loading fails, the diff should remain usable. The boundary should
  avoid showing an exact line count and should degrade the same way current
  context expansion does.
- If a snapshot is not loaded yet, labels and enabled states may be optimistic
  or generic, but actions must resolve against the loaded source range before
  inserting context lines.

## Testing Plan

Display-builder tests should cover:

- external top and bottom boundaries;
- shared boundaries between every neighboring hunk pair;
- chunk expansion from the top side of a shared gap;
- chunk expansion from the bottom side of a shared gap;
- full-gap expansion;
- overlap clamping when both sides expand into the same gap;
- no bridge emitted after a boundary is fully revealed;
- no bridge emitted for initially contiguous hunks.

View-level tests should cover:

- split view renders one shared bridge for an intermediate hidden gap;
- stacked view renders one shared bridge for the same hidden gap;
- intermediate hunks have an above-direction affordance through the shared
  bridge;
- the full-gap action is present when a shared gap exists;
- panes fuse after a shared gap is fully revealed.

## Open Decisions

No open product decisions remain from the brainstorming session. The approved
behavior is:

- shared bridges appear for every hidden inter-hunk gap;
- split and stacked views both support the feature;
- directional controls expand one chunk by default;
- Option-click directional controls expand all remaining lines from that side;
- the center bridge action expands the whole gap immediately.
