# Split Diff Feedback Lanes Design

## Context

Inline feedback currently renders as a full-width row below its anchored diff
line. In split mode, that makes a comment on only the added side look detached
from the right pane, and a comment on only the deleted side look detached from
the left pane. The selection and review models already preserve old/new side
information for local drafts and provider threads, but the SwiftUI accessory
rows do not use it for horizontal placement.

This change makes all row- or hunk-attached inline feedback follow the diff
pane it belongs to while retaining the existing vertical insertion point.

## Goals

- Place deleted-side feedback in the left split pane and added-side feedback
  in the right split pane.
- Apply the same placement to pending composers, saved local drafts, actionable
  provider feedback cards, provider comment threads, and check annotations.
- Align feedback content with source code by insetting it past the line-number
  gutter.
- Keep stacked feedback full-width while applying the same code-aligned gutter
  inset.
- Preserve comment anchoring, publishing, editing, focus, highlighting,
  resolving, and reply behavior.

## Non-Goals

- Changing how review comments are persisted or published to providers.
- Moving feedback vertically or changing range-end insertion behavior.
- Redesigning comment cards, composer controls, or provider thread content.
- Changing file-level or outdated feedback that has no visible row attachment.
- Embedding SwiftUI feedback views inside the AppKit text renderer.

## Behavior

Vertical placement remains unchanged: feedback renders immediately after its
selected or provider-anchored row.

In split mode, horizontal placement follows this matrix:

| Feedback anchor | Lane |
|---|---|
| Deleted changed lines only | Left |
| Deleted changed lines plus unchanged lines | Left |
| Added changed lines only | Right |
| Added changed lines plus unchanged lines | Right |
| Both deleted and added changed lines | Right |
| Unchanged lines only | Pane where selection began |
| Saved draft or provider thread with old side | Left |
| Saved draft or provider thread with new side | Right |
| Actionable provider feedback with old/new side | Left/right respectively |
| Check annotation | Right |
| Unknown or incomplete side metadata | Right |

The selected lane occupies one split half. Its feedback content begins after
that pane's line-number gutter and uses the existing card padding toward the
center divider or outer edge. The opposite half stays empty. The center divider
continues through the feedback row.

In stacked mode, all lane-eligible feedback occupies the full row and begins
after the single line-number gutter. Switching between split and stacked modes
changes presentation only and does not rewrite anchors or persisted comments.

Narrow split panes retain the resolved lane and allow card content to wrap
vertically. They do not silently fall back to a full-width row.

## Architecture

Add two shared units to the diff UI layer:

- `DiffFeedbackLaneResolver` maps semantic feedback information to `.left`,
  `.right`, or `.full`.
- `DiffFeedbackLaneView` places arbitrary SwiftUI content using the resolved
  lane, current `DiffLayoutMode`, and shared gutter geometry.

The resolver remains a pure model with overloads or adapters for the existing
feedback types:

- pending `DiffReviewLineAnchor`
- saved `ReviewDraftComment`
- `DiffReviewInlineFeedback`
- `DiffInlineCommentThread`
- `DiffInlineAnnotation`
- other row- or hunk-attached inline feedback with an old/new anchor

For a pending range, the resolver inspects changed sides before context lines.
An old-only changed range resolves left, a new-only changed range resolves
right, and a range containing both changed sides resolves right. A context-only
range uses the pane side recorded by the selection anchor. This presentation
decision is separate from `canonicalPendingAnchor`, which continues to control
the provider-facing saved anchor.

The lane view is a reusable wrapper, not a new card. It receives content and
computes only its horizontal frame and inset. In split mode it uses the same
one-point divider and half-width calculation as
`DiffPaneTextDocumentContainerView`. In stacked mode it uses the full available
width.

## Shared Gutter Geometry

`DiffPaneLineNumberRulerView` currently calculates its thickness from a
42-point minimum, the maximum visible label width, and horizontal padding.
Extract that calculation into a small shared geometry helper that accepts the
line labels and uses the ruler's existing 10-point monospaced label font.

Both the AppKit ruler and `DiffFeedbackLaneView` use this helper. Feedback
therefore remains aligned with source text for ordinary and high line numbers,
without relying on a duplicated width constant. The geometry helper also
exposes a pure lane-frame calculation so its split and stacked output can be
tested without rendering a window.

The relevant display group or row segment supplies old/new line labels to the
lane wrapper. Left feedback uses old-side gutter metrics, right feedback uses
new-side gutter metrics, and stacked feedback uses the stacked projection's
gutter metrics.

## Integration Points

Apply the shared lane wrapper at every lane-eligible feedback insertion site:

- `DiffPaneView` for provider threads and check annotations in the shared diff
  renderer.
- `DiffReviewFileSection` for pending composers, saved local drafts, actionable
  provider feedback cards, provider threads, and annotations in the review
  surface. Hunk-attached actionable feedback keeps its current position above
  the matching hunk; only each card's horizontal lane changes.
- `DiffTabView` for pending composers and saved local drafts in standalone diff
  tabs.

The existing segmentation and block builders continue to decide vertical
placement. Render-context segment data gains only the lane or anchor data
needed for deterministic presentation. It must not duplicate comment
placement logic or introduce a second vertical segmentation pass.

File-level fallbacks remain full-width in their existing location because they
do not have a visible diff row or reliable pane geometry.

## Data Flow

1. Existing selection, draft, actionable feedback, provider thread, or
   annotation loading produces its current semantic anchor.
2. Existing row segmentation places the accessory after the matching row.
3. `DiffFeedbackLaneResolver` derives the presentation lane from that anchor.
4. The active layout mode and relevant row labels produce shared gutter and
   lane geometry.
5. `DiffFeedbackLaneView` renders the existing composer or card in the computed
   code-aligned frame.
6. Existing actions and persistence callbacks flow through unchanged.

Changing layout mode re-runs steps 3 through 5 from the same underlying model.

## Fallbacks And Compatibility

- Unknown split-side metadata resolves to the right lane so feedback remains
  visible and compact.
- Unknown stacked-side metadata has no special case because stacked feedback
  always uses the full row.
- Missing or non-visible row anchors continue through the existing file-level
  fallback instead of attempting lane placement.
- The feature changes no stored schema and requires no migration.
- GitHub and GitLab provider payload construction remains unchanged.

## Testing

Use Swift Testing for focused coverage:

- Lane resolver tests cover old-only, new-only, old-plus-context,
  new-plus-context, old-plus-new, context-only selection origin, saved draft
  sides, actionable feedback sides, provider thread sides, annotations, and
  unknown metadata.
- Geometry tests cover left, right, and full frames; the one-point split
  divider; code-gutter insets; narrow widths; and ruler expansion for wide line
  numbers.
- Render-context tests verify that composers and persisted feedback receive the
  same lane data without changing their row segment.
- Regression tests retain one pending composer, range-end insertion, mixed-side
  right fallback, context selection origin, focus behavior, and split/stacked
  layout switching.
- Existing provider thread, annotation, draft comment, and active-highlight
  tests continue to pass.

Final verification remains:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
