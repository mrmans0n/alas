---
title: "Center diff scroll performance"
date: 2026-07-07
project: alas
phase: design
prior_art:
  - docs/superpowers/specs/2026-06-12-shared-diff-renderer-for-commit-and-review-drafts-design.md
  - docs/superpowers/specs/2026-06-15-diff-context-expansion-design.md
  - Alas/Sources/Center/DiffReview/DiffReviewSurface.swift
  - Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift
  - Alas/Sources/Center/Diff/DiffPaneView.swift
  - Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift
---

## TL;DR

Improve scrolling smoothness for large center-pane diff surfaces without
changing the visible diff UI. The first pass should keep the current
SwiftUI/AppKit renderer and remove redundant body-path work by caching
per-file render derivations used by review surfaces. Regular diff tabs should
receive the same treatment where they recompute draft/comment segmentation in
their render path.

## Context

Large diff panes currently stutter while scrolling, especially in review
surfaces that combine a file rail, multi-file stream, context expansion,
inline feedback, draft comments, provider review threads, annotations, and the
AppKit-backed text diff renderer.

The relevant code paths are:

- `DiffReviewSurface`: owns the vertical review stream and file rail selection.
- `DiffReviewFileSection`: renders one file card, derives expanded display
  groups, places feedback and draft comments, segments rows, and filters
  threads/annotations into row blocks.
- `DiffPaneView`: renders regular diff panes and embedded static-height diff
  groups.
- `DiffPaneTextDocumentView`: AppKit-backed text document for split/stacked
  diff rows.

The existing surface already uses `ScrollView`, `LazyVStack`, and the shared
diff display model. `DiffReviewRenderEligibility` currently returns every file
as render-eligible, so SwiftUI laziness is the only vertical virtualization
layer. This design does not introduce a new virtualization model; it targets
redundant recomputation first.

## Goals

- Improve scroll smoothness for large review diff surfaces.
- Preserve the current UI and behavior exactly: inline comments, draft
  comments, annotations, context expansion, line selection, rail sync, and
  hunk actions should continue to work.
- Avoid large renderer rewrites in the first pass.
- Keep the work testable through pure builder and cache-key tests.
- Add debug-only timing or counters where useful to verify that scroll-path
  recomputation decreases.

## Non-Goals

- Do not redesign diff anchoring or scrolling.
- Do not disable review affordances for large diffs.
- Do not introduce approximate rendering, placeholder rows, or progressive
  feature degradation.
- Do not replace the vertical review stream with a custom AppKit row-reuse
  container in this pass.
- Do not change ACP chat scrolling as part of this design.

## Architecture

Add an immutable per-file render context for `DiffReviewFileSection`. The
section should compute a compact key from the stable inputs that affect
placement and then render from a cached context when possible.

The render context should hold the values that are currently derived in view
properties or inside nested body builders:

- context-expanded display groups
- file-level inline feedback
- inline feedback grouped by display group
- file-level draft comments
- draft comment placement by row anchor
- per-group row segmentations
- per-segment inline comment and annotation blocks

Pure presentation inputs such as theme colors, layout mode, wrap-lines,
whitespace visibility, code font family, and code font size should still flow
through the view layer. They should not invalidate placement caches unless they
also alter row identity or segmentation semantics.

Regular diff tabs should get a narrower equivalent for draft comment placement
and row segmentation where those values are currently recomputed from body
state.

## Components

### `DiffReviewRenderContext`

Immutable data consumed by `DiffReviewFileSection`. It should be shaped around
how the file section renders today:

- `groups: [DiffDisplayGroup]`
- `fileLevelInlineFeedback: [DiffReviewInlineFeedback]`
- `inlineFeedbackByGroupID: [String: [DiffReviewInlineFeedback]]`
- `fileLevelDraftComments: [ReviewDraftComment]`
- `draftPlacement: ReviewDraftCommentPlacement.Result`
- per-group render data containing row segments and precomputed inline
  comment/annotation blocks

The context should not own actions, bindings, focus state, pending draft state,
copy feedback, LSP context, or theme.

### `DiffReviewRenderContextKey`

Hashable key derived from placement-affecting state:

- `file.id`
- base display group identity
- context expansion signature and loaded context snapshot identity
- inline feedback ids, anchors, statuses, and body previews where displayed
- draft comment ids, anchors, body revisions, and resolution/display state
- review thread ids, side/line anchors, resolution state, and visible comment
  revisions
- annotation ids, line anchors, severity/status, and displayed message

The key should avoid storing large text bodies when a smaller revision,
identifier, or displayed preview is sufficient. It should be conservative:
when in doubt, change the key and rebuild.

### `DiffReviewRenderContextBuilder`

Pure builder that performs the current derivations once for a matching key:

- `DiffContextExpandedDisplayBuilder.derive`
- `DiffReviewInlineFeedbackPlacement.position`
- `ReviewDraftCommentPlacement.position`
- `ReviewDraftCommentRowSegmentation.segments`
- `DiffInlineCommentLayout.blocks`
- per-segment thread and annotation filtering

The builder should preserve ordering and output equivalence with the existing
helpers.

### `DiffReviewRenderContextCache`

Small cache owned by `DiffReviewFileSection` or its parent. A simple bounded
dictionary is enough for the first pass. The cache should explicitly clear or
miss when `file.id` changes and should naturally rebuild when the key changes.

Because each visible file section is already a view boundary, per-section
ownership is acceptable. If profiling shows repeated construction during
parent invalidations, the cache can move up to `DiffReviewSurface`.

### Regular Diff Helper

Add a smaller helper or context for `DiffTabView` paths that only need draft
comment placement and row segmentation caching. This should reuse the same key
principles without forcing regular diffs into the full review context model.

## Data Flow

1. `DiffReviewSurface` passes the same inputs it passes today into
   `DiffReviewFileSection`.
2. `DiffReviewFileSection` computes `DiffReviewRenderContextKey` from the file,
   feedback, draft comments, review threads, annotations, and expansion state.
3. The cache returns an existing `DiffReviewRenderContext` or builds one with
   `DiffReviewRenderContextBuilder`.
4. Header, file-level stacks, group bodies, row blocks, and draft composer slots
   render from the context.
5. Local interactive state remains local to the section:
   - pending draft anchor and body
   - context expansion loading/error state
   - focused draft/comment ids
   - copy feedback overlay
   - LSP and open-file actions

Context expansion is still the state transition that changes display groups. A
successful expansion changes the key and rebuilds the context. A failed
expansion leaves the previous context in place and shows the existing
file-scoped error row.

## Error Handling

The render context builder is pure and deterministic. It should not introduce
new user-visible errors. If the cache misses, the section rebuilds
synchronously and renders the same output.

Debug instrumentation should be best-effort. Timing or counters must not crash
the app, affect release behavior, or create persistent logs unless they use an
existing diagnostics mechanism.

Context expansion keeps its existing async failure behavior. A failed snapshot
load should not poison or clear a valid render context.

## Testing

Add pure tests for the builder and key behavior:

- derived groups match `DiffContextExpandedDisplayBuilder.derive`
- file-level and group-level inline feedback placement matches current helpers
- file-level and row-level draft comment placement matches current helpers
- segment ordering matches `ReviewDraftCommentRowSegmentation.segments`
- inline thread and annotation block placement matches
  `DiffInlineCommentLayout.blocks`
- context expansion changes the key and rebuilds
- comment/thread/annotation content changes that affect display change the key
- layout mode, wrap lines, whitespace, theme, and font do not change the key

Keep existing `DiffReviewSurfaceTests`, `DiffPaneViewTests`, draft comment
tests, inline feedback tests, and context expansion tests passing. Add a view
smoke test proving a cached file section still creates the same visible cards
or accessibility markers for feedback/comments.

Manual verification should use a large multi-file review diff and a regular
diff tab. The useful evidence is fewer render-context builds or lower
body-path timing while scrolling, with no visible change to comments,
annotations, context expansion, line selection, or rail selection.
