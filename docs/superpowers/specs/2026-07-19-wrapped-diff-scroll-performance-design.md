---
title: "Wrapped diff scroll performance"
date: 2026-07-19
project: alas
phase: design
prior_art:
  - docs/superpowers/specs/2026-07-07-center-diff-scroll-performance-design.md
  - Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift
  - Alas/Sources/Center/Diff/DiffPaneView.swift
  - Alas/Sources/Center/DiffReview/DiffReviewSurface.swift
---

## TL;DR

Improve scrolling performance when diff line wrapping is enabled in both
single-file and multi-file diff surfaces, in both split and stacked layouts.
Keep the current renderer and behavior. Make the AppKit text renderer apply
width-sensitive TextKit configuration only when its effective configuration
changes, make unchanged SwiftUI updates true no-ops, and bound custom drawing
to rows intersecting the visible or dirty region.

## Context

All affected surfaces eventually render code through
`DiffPaneTextDocumentContainerView` and `DiffPaneTextScrollView`. Each code pane
uses an `NSTextView`, `NSLayoutManager`, and `NSTextContainer`. The vertical
scroll is owned by an outer SwiftUI `ScrollView`; the nested AppKit scroll view
exists for the code pane, its line-number ruler, and unwrapped horizontal
scrolling.

Wrapping increases the number of TextKit line fragments. The current AppKit
layout path repeatedly assigns wrapping and container-size properties even
when the wrap mode and effective code width have not changed. It also asks
unchanged `NSViewRepresentable` updates to lay out again. A subsequent layout
reads full-document row geometry for document height and, in split mode, row
height synchronization. Reapplying an identical container configuration can
therefore turn an otherwise redundant parent layout pass into wrapped-text
layout work.

The text view caches computed row geometry, but custom background drawing
still scans the complete row-rect array before rejecting rows outside the dirty
region. The ruler already has lower-bound helpers for visible rows; the text
background path should use the same bounded lookup principle.

These are shared-renderer costs, matching the reported slowdown across:

- single-file diff and commit panes
- multi-file review panes
- split layout
- stacked layout

## Goals

- Make wrapped scrolling smooth enough that it no longer exhibits the severe
  stalls seen in current diff panes.
- Prevent an unchanged AppKit update or layout pass from invalidating TextKit
  layout.
- Preserve exact wrapping and row heights at the current pane width.
- Preserve split-pane row alignment.
- Preserve text selection, line selection, line numbers, context expansion,
  comment highlights, LSP interactions, whitespace display, and horizontal
  scrolling when wrapping is disabled.
- Apply the improvement to every surface using the shared diff text renderer.
- Add deterministic regression coverage for the invalidation behavior rather
  than relying only on wall-clock timing.

## Non-Goals

- Do not replace TextKit 1 or migrate the renderer to TextKit 2.
- Do not introduce `NSCollectionView`, custom text drawing, or a new vertical
  virtualization system.
- Do not split hunks into additional text documents; that could change text
  selection across artificial chunk boundaries.
- Do not change diff parsing, syntax highlighting, context expansion, inline
  feedback placement, or review-stream selection behavior.
- Do not approximate wrapped heights or defer visible layout in a way that
  causes scroll-position jumps.
- Do not set a brittle time-based unit-test threshold for AppKit performance.

## Design

### Stable Text Layout Configuration

`DiffPaneTextScrollView` will own a compact value describing the TextKit
configuration currently applied to its text view and text container. The value
will include only inputs that affect line fragmentation:

- whether lines wrap
- effective code width after subtracting the text inset
- the unwrapped container-width policy

Font and document changes already flow through `update(document:...)`, replace
the attributed string, and invalidate layout independently. They do not need to
be duplicated in the width-configuration value.

The scroll view will derive the desired configuration after tiling establishes
the effective content width. It will compare that value with the last applied
configuration before changing any of these properties:

- `isHorizontallyResizable`
- `maxSize`
- `textContainer.widthTracksTextView`
- `textContainer.containerSize`
- horizontal-scroller visibility

If the value is unchanged, the configuration method returns without assigning
TextKit properties. A meaningful width or wrap-mode change applies the new
configuration once and invalidates width-dependent row geometry once.

The comparison will use the project's existing half-point layout tolerance so
subpixel frame noise does not repeatedly reflow wrapped text. The applied width
must still be the actual current effective width when a change exceeds that
tolerance. Compare against the last width actually applied to TextKit, not the
immediately preceding requested width, so cumulative sub-tolerance changes
eventually reconfigure once their total difference exceeds the tolerance.

### Layout Passes

`DiffPaneTextScrollView.layout()` will keep the existing order required by the
line ruler and text frame:

1. allow `NSScrollView` to tile its content and ruler
2. derive and conditionally apply the effective text configuration
3. measure document height from cached row geometry
4. update the text view frame only when its size meaningfully changes
5. reset the horizontal origin only after a document or wrap-mode update that
   requested it

The implementation should not explicitly tile the same scroll view multiple
times in one layout pass unless AppKit requires it for a demonstrated geometry
dependency. Any retained extra tiling call must not reapply text-container
configuration.

`DiffPaneTextDocumentContainerView.update` currently marks the container as
needing layout when its render signature is identical. The identical-signature
path will instead update only callbacks or transient interaction inputs that
must remain current and then return without requesting layout. Render inputs
that affect the document, theme, width behavior, or LSP context continue to
take the existing rebuild path.

Callback and active-highlight assignments occur before signature comparison
today and remain live. If an interaction input needs display without document
layout, its existing property observer should request display directly.

### Row Geometry

`DiffPaneCodeTextView` remains the source of truth for row rectangles and first
line-fragment rectangles. Its cached geometry remains valid until one of these
events:

- attributed text or line metadata changes
- line tones or synchronized paragraph heights change
- the effective text width changes beyond the layout tolerance
- the text view receives a meaningful frame-width change

Scrolling alone must not invalidate this cache. Container height changes with
an unchanged width must not invalidate it either.

The split renderer will continue to measure both sides and synchronize each
logical row to the greater height. Existing protections against the
split-height synchronization live-lock remain intact. This work must not
reintroduce unconditional paragraph-style writes.

### Visible Custom Drawing

`DiffPaneCodeTextView.drawLineBackgrounds(in:)` will locate the first and last
row rectangles intersecting the dirty rectangle using lower-bound or binary
search over the ordered cached geometry. It will iterate only that row range.
Add/delete fills, placeholder hatching, expandable-context controls, and the
active comment highlight retain their current appearance and hit geometry.

The line-number ruler will continue to render only visible rows. Shared helpers
may be extracted for row-range lookup if that removes duplication without
changing ownership. Drawing optimization must not create a second row-geometry
cache with different invalidation semantics.

The dirty rectangle supplied by AppKit remains authoritative for the text
view. The implementation does not need SwiftUI scroll-position state or a new
outer-scroll observer merely to calculate visible rows.

## Data Flow

1. SwiftUI creates or updates a shared diff document representable.
2. The container compares the new render signature with the last applied
   signature.
3. An unchanged signature updates interaction closures/state only and returns
   without scheduling layout.
4. A changed signature rebuilds the attributed document and marks the scroll
   view for layout as today.
5. During layout, the scroll view derives the effective code width after the
   ruler has been tiled.
6. The cached text-layout configuration suppresses identical TextKit property
   assignments.
7. Row geometry is computed once for the resulting document and width, then
   reused for height, split synchronization, drawing, ruler labels, and hit
   testing.
8. During scrolling, AppKit draws only the dirty row range while the cached
   geometry remains valid.

## Correctness And Failure Handling

No new asynchronous work or user-visible error state is introduced. If the
configuration cache is empty, the renderer applies the full configuration. If
the pane changes width, wrap mode, document, or font, the renderer follows the
normal layout path and recomputes exact geometry.

The optimization must fail toward doing necessary work: an uncertain
configuration comparison should reconfigure and remeasure rather than reuse
geometry at the wrong width. Debug counters used by tests must not affect
release behavior or persist diagnostics.

## Instrumentation

Add narrow debug/test-only counters or observable test accessors for:

- effective text-layout configuration applications
- row-geometry computations
- optionally, container or scroll-view layout passes if needed to prove the
  unchanged-update behavior

The counters are evidence for tests and local profiling. They are not product
analytics and must not emit logs during normal use.

## Testing

Use Swift Testing and real AppKit objects. Tests should cover:

- repeated wrapped layout at an unchanged width applies text-container
  configuration only once
- a meaningful width change applies a new configuration and recomputes row
  geometry
- a sub-tolerance width change does not reconfigure TextKit
- toggling wrap mode applies a new configuration and preserves horizontal
  scroller behavior
- an identical container update does not request another layout pass or
  recompute row geometry
- height-only frame changes do not invalidate width-dependent geometry
- wrapped stacked documents keep exact line and document heights
- wrapped split documents keep paired logical rows aligned
- custom background row-range lookup includes every intersecting boundary row
  and excludes offscreen rows
- existing wrapped continuation glyph, gutter, selection, expansion, comment
  highlight, and split synchronization regression tests continue to pass

The test suite should assert work counts or state transitions, not elapsed
milliseconds. A focused performance harness may record layout/configuration
counts for a large synthetic diff, but it should remain deterministic.

## Verification

Run the required project verification:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Manually compare wrapped and unwrapped scrolling in:

- a large single-file diff
- a large commit diff
- a multi-file review diff
- split and stacked layouts

Use Instruments or debug counters to confirm scrolling no longer causes
repeated TextKit configuration applications or row-geometry recomputation at a
stable width. Visual verification must confirm there are no row-alignment,
gutter, clipping, selection, or scroll-position regressions.

## Rollout

This is a single shared-renderer change with no migration or configuration
flag. If profiling after the change still shows material wrapped-text cost, the
next investigation should evaluate bounded hunk chunking or a viewport-driven
AppKit renderer as a separate design, because both carry larger interaction and
selection tradeoffs.
